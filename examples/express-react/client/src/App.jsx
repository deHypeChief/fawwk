import { useEffect, useState } from "react";

// Same origin by default (example.com/api). Set VITE_API_URL to use a separate API domain.
const API = import.meta.env.VITE_API_URL || "/api";

export default function App() {
  const [message, setMessage] = useState("Loading…");

  useEffect(() => {
    fetch(`${API}/hello`)
      .then((r) => r.json())
      .then((d) => setMessage(d.message))
      .catch(() => setMessage("Couldn't reach the API"));
  }, []);

  return (
    <main style={{ fontFamily: "system-ui", padding: "3rem" }}>
      <h1>Example web</h1>
      <p>{message}</p>
    </main>
  );
}
