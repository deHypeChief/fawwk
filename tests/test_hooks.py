"""Tests for lib/hooks.py, the webhook receiver. Run: python3 -I tests/test_hooks.py lib/hooks.py

Starts the real handler on a free port with its folders pointed at a temp dir.
"""

import hashlib
import hmac
import http.client
import importlib.util
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("hooks", sys.argv[1])
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)

SECRET = b"sekret"
SHA = "a" * 40


class HooksTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        for name in ("SECRETS", "PAGES", "CODES", "INBOX"):
            d = os.path.join(cls.tmp, name.lower())
            os.makedirs(d)
            setattr(hooks, name, d)
        with open(os.path.join(hooks.SECRETS, "app1"), "wb") as f:
            f.write(SECRET + b"\n")
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), hooks.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        for f in os.listdir(hooks.INBOX):
            os.remove(os.path.join(hooks.INBOX, f))

    def post(self, body, event="push", sig=None, delivery=None):
        data = json.dumps(body).encode()
        if sig is None:
            sig = "sha256=" + hmac.new(SECRET, data, hashlib.sha256).hexdigest()
        headers = {"X-GitHub-Event": event, "X-Hub-Signature-256": sig, "Content-Type": "application/json"}
        if delivery:
            headers["X-GitHub-Delivery"] = delivery
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("POST", "/hooks/github", data, headers)
        r = c.getresponse()
        return r.status, r.read().decode()

    def push(self, **kw):
        body = {"ref": "refs/heads/main", "after": SHA, "repository": {"full_name": "Me/App"}}
        body.update(kw)
        return body

    def jobs(self):
        return [f for f in os.listdir(hooks.INBOX) if f.endswith(".json")]

    def test_signed_push_is_queued(self):
        self.assertEqual(self.post(self.push(), delivery="d-1")[0], 202)
        jobs = self.jobs()
        self.assertEqual(len(jobs), 1)
        with open(os.path.join(hooks.INBOX, jobs[0])) as f:
            job = json.load(f)
        self.assertEqual((job["repo"], job["branch"], job["sha"]), ("Me/App", "main", SHA))

    def test_bad_signature_rejected(self):
        self.assertEqual(self.post(self.push(), sig="sha256=00")[0], 401)
        self.assertEqual(self.post(self.push(), sig="")[0], 401)
        self.assertEqual(self.jobs(), [])

    def test_redelivery_queued_once(self):
        self.assertEqual(self.post(self.push(), delivery="dup-1")[0], 202)
        self.assertEqual(self.post(self.push(), delivery="dup-1"), (200, "Already queued\n"))
        self.assertEqual(len(self.jobs()), 1)

    def test_ignored_events(self):
        self.assertEqual(self.post({"zen": "hi"}, event="ping")[0], 200)
        self.assertEqual(self.post(self.push(), event="issues")[0], 202)
        self.assertEqual(self.post(self.push(ref="refs/tags/v1"))[0], 202)
        self.assertEqual(self.post(self.push(deleted=True))[0], 202)
        self.assertEqual(self.jobs(), [])

    def test_callback_needs_known_state(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("GET", "/github/callback?code=abc&state=" + "b" * 32)
        self.assertEqual(c.getresponse().status, 400)
        state = "c" * 32
        open(os.path.join(hooks.PAGES, state + ".html"), "w").close()
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("GET", "/github/callback?code=abc&state=" + state)
        self.assertEqual(c.getresponse().status, 200)
        with open(os.path.join(hooks.CODES, state)) as f:
            self.assertEqual(f.read(), "abc")

    def test_stalled_client_times_out(self):
        self.assertTrue(0 < hooks.Handler.timeout <= 60)
        s = socket.create_connection(("127.0.0.1", self.port))
        s.sendall(b"POST /hooks/github HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n")
        s.settimeout(hooks.Handler.timeout + 5)
        t0 = time.time()
        self.assertEqual(s.recv(1), b"")  # the server hangs up instead of waiting forever
        self.assertLess(time.time() - t0, hooks.Handler.timeout + 5)
        s.close()


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1], verbosity=1)
