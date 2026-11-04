# Example: Express API + React frontend

A small two-service app showing how to deploy a backend and a frontend with Fawwk. Each service has
its own Dockerfile, so each one becomes its own Fawwk app.

```
examples/express-react/
├── server/   Express API   → example.com/api   (port 4000)
└── client/   React (Vite)  → example.com       (port 80, served by nginx)
```

The same steps work when the two services live in separate repos: leave the folder as `.`.

## Deploy

```bash
sudo fawwk create api --repo you/your-repo --dir examples/express-react/server \
  --domain example.com/api --port 4000 --health /health
```

```bash
sudo fawwk create web --repo you/your-repo --dir examples/express-react/client \
  --domain example.com --port 80
```

Or run `sudo fawwk create` with no flags and answer the questions. Then open `https://example.com`: the
page calls `/api/hello`, which Fawwk forwards to the API as `/hello`.

## What makes it work

| | Where | Why |
| --- | --- | --- |
| Listen on `PORT` and `0.0.0.0` | `server/index.js` | Fawwk sets `PORT` and reaches the container over its network |
| Routes without `/api` | `server/index.js` | `example.com/api` strips the prefix by default (`--no-strip` keeps it) |
| `/health` route | `server/index.js` | lets Fawwk check a new version before switching traffic to it |
| Calls `/api/...` on the same domain | `client/src/App.jsx` | one origin, so no CORS setup |
| `ARG VITE_API_URL` | `client/Dockerfile` | Docker only passes env vars into the build when they're declared as `ARG` |
| `try_files ... /index.html` | `client/nginx.conf` | client-side routes still load on refresh |
| `EXPOSE` | both Dockerfiles | Fawwk suggests that port during `create` |

## Variations

- **API on its own subdomain:** use `--domain api.example.com` for the API, set
  `VITE_API_URL=https://api.example.com` on the web app (`fawwk env web set ...`, then `fawwk deploy web`),
  and enable CORS for `https://example.com` in Express.
- **Private repo:** choose a deploy key when asked. Each Fawwk app gets its own key; add both to the repo's
  deploy keys.

## Run it locally

```bash
cd server && npm install && npm start
```

```bash
cd client && npm install && npm run dev
```

The Vite dev server forwards `/api` to `localhost:4000`, the same way Fawwk does in production.
