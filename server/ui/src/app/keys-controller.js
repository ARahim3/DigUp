// keys-controller.js — the gear's API key section: the server's minted keys, each row
// a Copy button, and Regenerate (the vanilla loadAccess/regenerateKeys carried over
// verbatim). A minted-key server issues its own keys at boot (nothing to type): the
// main page searches WITHOUT a key; these rows are what the APPLICATIONS take — Copy
// puts a key on the clipboard for pasting into an app's settings (a Nextcloud bridge,
// a dashboard tile), Regenerate mints fresh values (confirm first — the old keys die
// immediately and every application that has one pasted loses access until the new key
// is pasted there; this browser keeps the admin key in localStorage, so it updates
// itself). Deployments whose keys come from the environment are never shown and never
// rotated. The index list rides the same call (GET /targets).
export function createKeysController({ store, api, storage,
                                       TOKEN_KEY = "digupBearer",
                                       confirm = (m) => window.confirm(m) }) {
  const seq = { retried: false };

  async function regenerate() {
    if (!confirm("Regenerate the server's keys? The keys shown here stop working "
        + "immediately — every application that has one pasted loses access until you "
        + "paste its new key into that application. This browser keeps working: its key "
        + "updates itself.")) {
      return;
    }
    try {
      const t = await api("/api/v1/tokens", {method: "POST"});
      if (t.admin) storage.setItem(TOKEN_KEY, t.admin);
      loadAccess();
    } catch (error) {
      window.alert(error.message || String(error));
    }
  }

  async function loadAccess() {
    try {
      const t = await api("/api/v1/tokens");        // keyless in a minted deployment:
      // The gear's own controls (Index now, Estimate, Regenerate) are admin-scope by
      // the minted shape's design — so this browser takes the key it was just SHOWN,
      // exactly as Regenerate hands it the new key today. No typing, no paste, no
      // popup: the standalone box's own operator uses its own box's key, and a stored
      // key that the server no longer recognizes (rotated, re-minted, from another
      // deployment) is REPLACED by the value shown now — the gear self-heals. The main
      // page's key-free reads are untouched. A server configured by environment shows
      // no value (admin null) → nothing is adopted → guarded deployments stay guarded.
      if (t.admin && storage.getItem(TOKEN_KEY) !== t.admin) {
        storage.setItem(TOKEN_KEY, t.admin);
      }
      store.set({ keys: {
        admin: t.admin || null,
        apps: (t.apps || []).filter((a) => a.token),
        envFlagged: Boolean(t.admin_configured || t.read_configured),
        minted: Boolean(t.admin),
      } });
    } catch {
      // A stored key that the server refuses. In the MINTED shape the main index's reads
      // are open, so a keyless `status` answers 200 — the stored key is stale (rotated,
      // or from a server that was re-minted): drop it and re-read, the gear then shows
      // the key that exists NOW. In the guarded (environment-keys) shape a keyless
      // `status` answers 401, so the stored key is kept: it is the deployment's config,
      // not something the UI may discard. One retry only — never a loop.
      if (!seq.retried && storage.getItem(TOKEN_KEY)) {
        seq.retried = true;
        try {
          const probe = await fetch("/api/v1/status", {headers: {"content-type": "application/json"}});
          if (probe.status === 200) {
            storage.removeItem(TOKEN_KEY);
            return loadAccess();
          }
        } catch { /* the server is not answering at all: show the rows as empty */ }
      }
      // A read key / no key: the rows are not for this scope — the panel shows nothing.
      store.set({ keys: { admin: null, apps: [], envFlagged: false, minted: false } });
    }
    try {
      const tg = await api("/api/v1/targets");
      store.set({ targets: (tg.targets || []).map((t) => ({
        name: t.name, main: Boolean(t.main), files: t.files,
        searchable: t.searchable, roots: t.roots })) });
    } catch {
      store.set({ targets: [] });
    }
  }

  function resetRetried() { seq.retried = false; }   // a fresh gear open may try the stale-key recovery once

  return { loadAccess, regenerate, resetRetried };
}
