import express from "express";

const app = express();
const port = process.env.PORT || 4000;

// Fawwk routes example.com/api to this app and strips the prefix,
// so /api/hello arrives here as /hello.
app.get("/health", (req, res) => res.json({ ok: true }));
app.get("/hello", (req, res) => res.json({ message: process.env.GREETING || "Hello from Express" }));

// Listen on 0.0.0.0 so the proxy can reach the container.
app.listen(port, "0.0.0.0", () => console.log(`API listening on ${port}`));
