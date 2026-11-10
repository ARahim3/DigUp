// api.js — THE only place the frontend talks HTTP (server/ui/AGENTS.md §API). The
// vanilla app.js/embed.js rules, carried over verbatim; test_media_ui and
// test_integrations pin the header shape, the 401 shapes, the detail-list rendering,
// and the endpoint literals. Components never fetch; controllers call these.
//
// Bearer token, when this deployment asks for one. The shapes (docs/API.md
// "Authentication"): a TOKENLESS server asks for nothing (the main page searches);
// a MINTED-KEY server (apps registered) answers the main index's reads openly and
// guards index/estimate/keys with the minted admin key — the gear's API key rows are
// those keys, and Regenerate hands this browser its new admin key (localStorage, sent
// on every call, never in a URL); a server whose keys the OPERATOR set in the
// environment guards every call — its keys are the deployment's config, shown by
// nothing, so the gear says exactly that. A 401 with a stored key is the server's own
// words ("the bearer token is not this server's token"), shown, not re-prompted — a
// wrong key cannot loop the page.

const TOKEN_KEY = "digupBearer";          // the full UI keeps its key in localStorage

/** The full UI's client. getToken/onNoToken are injectable for tests; production uses
 *  localStorage and the gear-pointing callback (a 401 with no stored key names the
 *  server's shape in the panel, it never loops a prompt). */
export function createApiClient({
  getToken = () => localStorage.getItem(TOKEN_KEY),
  onNoToken = () => {},
  storage = {
    get: (k) => localStorage.getItem(k),
    set: (k, v) => localStorage.setItem(k, v),
    remove: (k) => localStorage.removeItem(k),
  },
} = {}) {
  async function api(path, options = {}, retried = false) {
    const token = getToken();
    const headers = {"content-type": "application/json",
                     ...(token ? {authorization: `Bearer ${token}`} : {}),
                     ...(options.headers || {})};
    const reply = await fetch(path, {...options, headers});
    if (reply.status === 401 && !token) {
      onNoToken();                        // the gear names the server's shape
      throw Object.assign(new Error(
        "This server guards this call with a key the operator set in its environment — "
        + "a minted-key server lists its keys under Settings → API key, and a tokenless "
        + "server asks for nothing."),
        {status: 401});
    }
    const body = await reply.json().catch(() => ({}));
    if (!reply.ok) {
      // FastAPI validation answers a LIST of dicts in `detail` (`new Error(list)` is
      // "[object Object]" on the footer): render each {loc, msg}, quote any string, fall
      // back to statusText for a non-JSON body (502 from a proxy, an HTML error page).
      const d = body.detail;
      const message = Array.isArray(d)
        ? d.map((x) => (x.loc || []).filter((p) => p !== "body").join(".") + " " + x.msg).join("; ")
        : (d || reply.statusText || `HTTP ${reply.status}`);
      throw Object.assign(new Error(message), {status: reply.status});
    }
    return body;
  }
  return {api, TOKEN_KEY, storage};
}

/** The embed widget's client (embed.html, stage-12): the host's read token arrives via
 *  ?token=, moves to sessionStorage, and the URL line is rewritten so the secret never
 *  lands in bookmarks, history, or the host app's logs. A 401 with a stored token
 *  clears it and asks ONCE — the same rule as the full UI. */
export function createEmbedApi({
  sessionStorageRef = sessionStorage,
  prompt = (msg) => window.prompt(msg),
  tokenKey = "digupEmbedToken",
} = {}) {
  let prompted = false;
  let token = sessionStorageRef.getItem(tokenKey) || "";

  function adoptUrlToken(value) {          // ?token= → storage → strip the URL line
    if (!value) return token;
    token = value;
    sessionStorageRef.setItem(tokenKey, token);
    return token;
  }

  async function api(path, options = {}) {
    const headers = { "content-type": "application/json", ...(options.headers || {}) };
    if (token) headers.authorization = "Bearer " + token;
    const answer = await fetch(path, { ...options, headers });
    if (answer.status === 401) {
      if (token && !prompted) {            // the stored token is stale: clear it and ask once
        prompted = true;
        sessionStorageRef.removeItem(tokenKey);
        const asked = prompt("This DigUp server asks for its read token:");
        token = (asked || "").trim();
        if (token) sessionStorageRef.setItem(tokenKey, token);
        return api(path, options);
      }
      throw new Error("the bearer token was refused");
    }
    if (!answer.ok) throw new Error("the server answered " + answer.status);
    return answer.json();
  }

  async function blobOf(path) {
    const headers = {};
    if (token) headers.authorization = "Bearer " + token;
    const answer = await fetch(path, { headers });
    if (!answer.ok) throw new Error("the server answered " + answer.status);
    return answer;
  }

  return {api, blobOf, adoptUrlToken, get token() { return token; },
          set token(v) { token = v; }, tokenKey};
}
