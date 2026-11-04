"""Fawwk webhook receiver. Runs in its own container (fawwk-hooks) behind Caddy at panel.<domain>.

It never runs deploys itself: it only checks requests and drops small job files that the host
picks up (systemd path unit → `fawwk hooks-run`). So the internet-facing part has no access to
Docker, app secrets or the shell.

Routes:
  GET  /github/setup/<state>   page that sends the GitHub App manifest to GitHub (one-click app creation)
  GET  /github/callback        GitHub redirects here with ?code=&state= after the app is created
  GET  /github/installed       GitHub redirects here after the app is installed on repos
  POST /hooks/github           push webhooks, verified with the app's webhook secret

Mounts: /secrets (ro: one file per GitHub App with its webhook secret), /pages (ro: setup pages),
        /codes (rw: manifest codes for the CLI), /inbox (rw: push jobs for the host).
"""

import hashlib
import hmac
import json
import os
import re
import threading
import time
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

SECRETS, PAGES, CODES, INBOX = "/secrets", "/pages", "/codes", "/inbox"
MAX_BODY = 10 * 1024 * 1024
STATE_RE = re.compile(r"^[a-f0-9]{32}$")
DELIVERY_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")

# GitHub retries and "Redeliver" resend the same X-GitHub-Delivery id; remember recent ones so a
# delivery is queued once. In memory only: after a restart, the host still skips commits it has.
SEEN_MAX = 1000
_seen = OrderedDict()
_seen_lock = threading.Lock()


def first_delivery(delivery_id):
    if not DELIVERY_RE.match(delivery_id):
        return True
    with _seen_lock:
        if delivery_id in _seen:
            return False
        _seen[delivery_id] = True
        while len(_seen) > SEEN_MAX:
            _seen.popitem(last=False)
    return True

PAGE = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fawwk</title><style>body{{font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;color:#222}}
h1{{font-size:1.4rem}}.ok{{color:#1a7f5a}}</style></head><body><h1 class="ok">{title}</h1><p>{body}</p></body></html>"""


def write_atomic(directory, name, data):
    tmp = os.path.join(directory, "." + name + ".tmp")
    with open(tmp, "w") as f:
        f.write(data)
    os.chmod(tmp, 0o600)
    os.replace(tmp, os.path.join(directory, name))


def secrets():
    out = []
    try:
        for name in os.listdir(SECRETS):
            with open(os.path.join(SECRETS, name)) as f:
                s = f.read().strip()
            if s:
                out.append(s.encode())
    except OSError:
        pass
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "fawwk-hooks"
    timeout = 15  # seconds a client may stall; frees the thread of a slow or dead connection

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)

    def reply(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def page(self, code, title, body):
        self.reply(code, PAGE.format(title=title, body=body), "text/html; charset=utf-8")

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)

        if url.path.startswith("/github/setup/"):
            state = url.path.rsplit("/", 1)[-1]
            path = os.path.join(PAGES, state + ".html")
            if STATE_RE.match(state) and os.path.isfile(path):
                with open(path) as f:
                    return self.reply(200, f.read(), "text/html; charset=utf-8")
            return self.page(404, "Link expired", "Run <code>fawwk github connect</code> again for a new link.")

        if url.path == "/github/callback":
            code, state = q.get("code", [""])[0], q.get("state", [""])[0]
            # Only accept codes for a setup the CLI actually started.
            if STATE_RE.match(state) and os.path.isfile(os.path.join(PAGES, state + ".html")) \
                    and re.match(r"^[A-Za-z0-9_-]{1,100}$", code):
                write_atomic(CODES, state, code)
                return self.page(200, "GitHub App created",
                                 "Go back to your terminal: Fawwk is finishing the setup.")
            return self.page(400, "Something's off", "This link isn't valid. Run <code>fawwk github connect</code> again.")

        if url.path == "/github/installed":
            return self.page(200, "Installed", "Go back to your terminal. Fawwk can now reach the repos you picked.")

        self.reply(404, "Not found\n")

    def do_POST(self):
        if urlparse(self.path).path != "/hooks/github":
            return self.reply(404, "Not found\n")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            return self.reply(413, "Too large\n")
        body = self.rfile.read(length)

        sig = self.headers.get("X-Hub-Signature-256", "")
        if not sig.startswith("sha256=") or not any(
                hmac.compare_digest(sig[7:], hmac.new(s, body, hashlib.sha256).hexdigest()) for s in secrets()):
            return self.reply(401, "Bad signature\n")

        event = self.headers.get("X-GitHub-Event", "")
        if event == "ping":
            return self.reply(200, "pong\n")
        if event != "push":
            return self.reply(202, "Ignored\n")

        try:
            p = json.loads(body)
            ref, repo, sha = p.get("ref", ""), p["repository"]["full_name"], p.get("after", "")
        except (ValueError, KeyError, TypeError):
            return self.reply(400, "Bad payload\n")
        if not ref.startswith("refs/heads/") or p.get("deleted") or not re.match(r"^[0-9a-f]{40}$", sha):
            return self.reply(202, "Ignored\n")

        delivery = self.headers.get("X-GitHub-Delivery", "")
        if not first_delivery(delivery):
            return self.reply(200, "Already queued\n")
        job = {"repo": repo, "branch": ref[len("refs/heads/"):], "sha": sha,
               "delivery": delivery, "at": int(time.time())}
        name = "%d-%s.json" % (time.time_ns(), sha[:12])
        write_atomic(INBOX, name, json.dumps(job))
        self.reply(202, "Queued\n")


if __name__ == "__main__":
    for d in (CODES, INBOX):
        os.makedirs(d, exist_ok=True)
    print("fawwk-hooks listening on :8000", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
