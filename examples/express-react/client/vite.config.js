import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // Local dev: forward /api to the Express server, the same way Fawwk does in production.
  server: { proxy: { "/api": { target: "http://localhost:4000", rewrite: (p) => p.replace(/^\/api/, "") } } },
});
