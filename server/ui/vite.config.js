// The DigUp server UI build (server/ui/AGENTS.md §Build). One rule above all: the built
// page must be served EXACTLY like the vanilla UI was — same URLs (`/`, `/embed.html`),
// same asset names the contract suite pins (`app.js`, `style.css`, `embed.js`, `embed.css`),
// same-origin only, no external URLs (README §10.4, test_media_ui pins). Node exists at
// BUILD time only (the Dockerfile's frontend-builder stage); the runtime image ships the
// static dist and FastAPI serves it. No server, no router library, no framework runtime.
import { defineConfig } from "vitest/config";

export default defineConfig({
  root: ".",                       // server/ui: index.html and embed.html ARE the entries
  base: "./",                      // relative asset URLs: the mount prefix never matters
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "es2021",              // modern browsers only — the server targets them
    cssCodeSplit: true,            // index graph → style.css, embed graph → embed.css
    rollupOptions: {
      input: { index: "index.html", embed: "embed.html" },
      output: {
        // Stable names, the pinned contract: the entry chunks answer at /app.js and
        // /embed.js; Vite names CSS assets after their html entry (index.css / embed.css)
        // — map them to the pinned style.css / embed.css. Shared code lands in hashed
        // chunks (imported from app.js in the html, so no pin depends on their names).
        entryFileNames: ({ name }) => (name === "embed" ? "embed.js" : "app.js"),
        chunkFileNames: "chunks/[name]-[hash].js",
        assetFileNames: (a) => {
          if (a.name === "index.css") return "style.css";
          if (a.name === "embed.css") return "embed.css";
          return "assets/[name][extname]";
        },
        manualChunks: (id) => (id.includes("node_modules") ? "vendor" : undefined),
      },
    },
  },
  server: {
    // Dev only: `npm run dev` (Vite on :5173) proxies the API to a running server
    // (`deploy/` compose → 127.0.0.1:8787). Production needs no server: FastAPI serves dist.
    // The default binds loopback (the server's own §7 discipline: nothing listens on a
    // LAN address unless the operator says so). LAN dev access is env-forced:
    //   DIGUP_UI_DEV_HOST=0.0.0.0 DIGUP_UI_DEV_ALLOWED_HOSTS=<lan-name>,<lan-ip>
    // The proxy runs server-side, so the LAN browser talks only to the dev server, and
    // `changeOrigin` hands the API its own loopback Host (the API's Host allowlist stays
    // the API's, untouched by this dev shape).
    host: process.env.DIGUP_UI_DEV_HOST || "127.0.0.1",
    allowedHosts: (process.env.DIGUP_UI_DEV_ALLOWED_HOSTS || "").split(",").filter(Boolean),
    // ENOSPC on a box whose inotify limit is reached (measured 2026-11-08: 65 536 watches,
    // other work owns them): DIGUP_UI_DEV_POLL=1 switches the dev watcher to polling,
    // scoped to the source tree. Hot reload stays live; only the mechanism changes.
    watch: process.env.DIGUP_UI_DEV_POLL
      ? { usePolling: true, interval: 300, ignored: ["**/node_modules/**", "**/dist/**", "**/data/**"] }
      : undefined,
    proxy: { "/api": { target: "http://127.0.0.1:8787", changeOrigin: true } },
  },
  test: {
    environment: "jsdom",          // unit tests: components in jsdom, fake timers, no real engine
  },
});
