// digup-embed — the embed widget (embed.html; docs/implementation/stage-12-integrations.md
// §11.4): a compact search page for hosts that embed it (a Nextcloud app page, an Immich
// workspace panel, a dashboard iframe). Same rules as the full UI (README §10.4,
// test_integrations pins): the engine's fields relayed verbatim (hits, z, strong, ms,
// meaning), keyword-first typing (words at once, meaning after the pause, embed_ahead
// warming the vector), previews only for tiles on screen. The read-scope token is the
// host's secret: it enters through ?token=, moves to sessionStorage, and the URL line
// is rewritten so the secret never lands in bookmarks, history, or the host app's logs.
// The host drives the theme by postMessage; the widget answers with `ready`.
import { LitElement, html, css } from "lit";
import { baseName } from "../lib/format.js";

const PAUSE = 160;                       // ms after the last keystroke until meaning results
const KIND_LABEL = { image: "photo", screenshot: "screenshot", video: "video", audio: "audio",
                     pdf: "pdf", doc: "document", code: "code" };
const PREVIEWABLE = new Set(["image", "screenshot", "video"]);

class DigupEmbed extends LitElement {
  static properties = {
    _limit: { state: true }, _kinds: { state: true }, _strong: { state: true },
    _reply: { state: true }, _activity: { state: true }, _status: { state: true },
  };

  static styles = css`
    /* The vanilla embed.css values, carried over verbatim into the shadow (the widget
       is the whole page, so the page's frame rules ride with it). */
    :host { display: block; }
    .embed-bar { display: flex; align-items: center; gap: 0.6rem; padding: 0.6rem 0.9rem 0.2rem; }
    #q { flex: 1 1 auto; min-width: 0; font-size: 1rem; padding: 0.45rem 0.7rem;
         border: 1px solid var(--edge); border-radius: 6px; background: var(--field); color: var(--text); }
    .embed-count { flex: 0 0 auto; display: flex; align-items: center; gap: 0.35rem;
      font-size: 0.85rem; color: var(--soft); }
    .embed-count select { padding: 0.2rem 0.35rem; border: 1px solid var(--edge); border-radius: 5px;
      background: var(--field); color: var(--text); }
    .embed-chips { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem;
      padding: 0.45rem 0.9rem 0.1rem; }
    .chip { font: inherit; font-size: 0.82rem; padding: 0.25rem 0.7rem; border: 1px solid var(--line);
      border-radius: 999px; background: var(--panel); color: var(--text); cursor: pointer; }
    .chip.on { border-color: var(--accent); color: var(--accent); }
    .chip-check { display: flex; align-items: center; gap: 0.4rem; cursor: pointer; }
    main { padding: 0 0.9rem 1rem; }
    #statusline { color: var(--soft); font-size: 0.82rem; min-height: 1.2em; margin: 0.2rem 0; }
    .activity { display: inline-flex; align-items: center; gap: 0.35rem; font-size: 0.8rem; color: var(--amber); }
    .activity .dot { width: 0.55rem; height: 0.55rem; border-radius: 999px; background: var(--amber);
      animation: pulse 1.6s ease-in-out infinite; }
    @keyframes pulse { 50% { opacity: 0.35; } }
    .embed-grid { list-style: none; margin: 0.6rem 0 0; padding: 0; display: grid;
      grid-template-columns: repeat(auto-fill, minmax(9.5rem, 1fr)); gap: 0.7rem; }
    .tile { display: flex; flex-direction: column; gap: 0.25rem; min-height: 6.5rem; padding: 0.45rem;
      border: 1px solid var(--line); border-radius: 8px; background: var(--panel); cursor: pointer;
      position: relative; }
    .tile.strong { border-color: var(--good); }
    .tile img { width: 100%; aspect-ratio: 4 / 3; object-fit: cover; border-radius: 5px; }
    .tile .kind { align-self: flex-start; font-size: 0.7rem; letter-spacing: 0.03em; text-transform: uppercase;
      color: var(--soft); padding: 0.05rem 0.45rem; border: 1px solid var(--line); border-radius: 999px;
      background: var(--bg); }
    .tile .name { font-size: 0.82rem; line-height: 1.25; overflow: hidden; display: -webkit-box;
      -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow-wrap: anywhere; }
    .tile .z, .tile .loc { font-size: 0.72rem; color: var(--soft); }
    .tile.strong .z { color: var(--good); }
  `;

  constructor() {
    super();
    this._limit = 40;
    this._kinds = "";
    this._strong = false;
    this._reply = null;
    this._activity = false;
    this._status = "connecting…";
    this._previews = new Map();          // media_id → objectURL (previews are a grace, not a promise)
    this._tileRefs = new Map();          // media_id → rendered tile element (IntersectionObserver targets)
    this._text = "";
    this._timer = null;
    this._gen = 0;
    this._meaningGen = 0;
  }

  /* embed.js wires {api (createEmbedApi client), params (URLSearchParams)}. embed.html
     DECLARES this element, so its first update runs unwired: render stays empty and the
     boot waits for the api (the same rule as the shell, 2026-11-08). */
  set api(client) { this._api = client; this.requestUpdate(); }
  set params(params) { this._params = params; }

  firstUpdated() { this.#boot(); }

  #boot() {
    if (this._booted || !this._api) return;
    this._booted = true;
    // Theme: system by default; the host app (Nextcloud / Immich) drives it by postMessage.
    const setTheme = (value) => {
      if (value === "light" || value === "dark") document.documentElement.dataset.theme = value;
    };
    if (this._params?.get("theme")) setTheme(this._params.get("theme"));
    this._hostMsg = (event) => {
      const data = event.data;
      if (data && data.source === "digup-host" && data.theme) setTheme(data.theme);
    };
    window.addEventListener("message", this._hostMsg);
    window.parent.postMessage({ source: "digup-embed", event: "ready" }, "*");

    if (this._params?.get("limit")) this._limit = Number(this._params.get("limit"));

    // Previews only for tiles on screen (the vanilla IntersectionObserver with a 300 px
    // margin). jsdom has none — then previews load straight away (the unit-test path).
    if (typeof IntersectionObserver !== "undefined") {
      this._observer = new IntersectionObserver((seen) => {
        for (const entry of seen) {
          if (!entry.isIntersecting) continue;
          this._observer.unobserve(entry.target);
          this.#loadPreview(entry.target.dataset.media);
        }
      }, { rootMargin: "300px" });
    }

    // start: health (open, no token needed), then the host's ?q= if any
    this._api.api("/api/v1/health").then((body) => {
      const live = body.live || {};
      this._status = `ready · ${live.searchable ?? "?"} searchable files`;
      if (this._params?.get("q")) { this.#run(this._params.get("q")); }
      this.requestUpdate();
    }).catch((error) => { this._status = error.message; this.requestUpdate(); });
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._hostMsg) window.removeEventListener("message", this._hostMsg);
    this._observer?.disconnect();
  }

  async #runSearch(meaning, myGen) {
    try {
      const reply = await this._api.api("/api/v1/search",
        { method: "POST", body: JSON.stringify({ q: this._text, meaning, limit: this._limit }) });
      if (meaning) this._meaningGen = myGen;
      if (myGen < this._meaningGen) return;   // a late keyword reply must not replace meaning
      this._reply = reply;
      this.requestUpdate();
    } catch (error) {
      this._status = error.message;
      this.requestUpdate();
    }
  }

  #run(text) {
    this._text = text;
    if (!text.trim()) {
      this._reply = null;
      this._status = "say what you'd see, hear, or read — the meaning, not only the words";
      this.requestUpdate();
      return;
    }
    this._activity = true;
    this._api.api("/api/v1/embed_ahead",
      { method: "POST", body: JSON.stringify({ q: text.trim() }) }).catch(() => {});
    const myGen = ++this._gen;
    this.#runSearch(false, myGen);            // words right away: the keyword path
    clearTimeout(this._timer);
    this._timer = setTimeout(() => {
      this._gen++;
      this.#runSearch(true, this._gen);
    }, PAUSE + 320);
    this.requestUpdate();
  }

  async #loadPreview(id) {
    if (!id || this._previews.has(id)) return;
    const kind = this._reply?.hits.find((h) => h.media_id === id)?.kind;
    if (!PREVIEWABLE.has(kind)) return;
    try {
      const answer = await this._api.blobOf(`/api/v1/media/${id}/preview?pixels=256`);
      this._previews = new Map(this._previews).set(id, URL.createObjectURL(await answer.blob()));
      this.requestUpdate();
    } catch { /* the tile keeps the kind label: previews are a grace, not a promise */ }
  }

  updated() {
    this.#boot();                             // fires on the update where embed.js wires the api
    // (Re)arm the observer on the tiles that are renderable and unpreviewed.
    if (this._observer) {
      for (const [id, el] of this._tileRefs) {
        if (!this._previews.has(id) && PREVIEWABLE.has(el.dataset.kind)) {
          this._observer.observe(el);
        }
      }
    } else if (this._reply) {
      // No IntersectionObserver (jsdom): load previews straight away.
      for (const hit of this._reply.hits) {
        if (PREVIEWABLE.has(hit.kind) && !this._previews.has(hit.media_id)) {
          this.#loadPreview(hit.media_id);
        }
      }
    }
  }

  async #openHit(hit) {
    if (!hit.media_id) return;
    try {
      const answer = await this._api.blobOf(`/api/v1/media/${hit.media_id}/file`);
      const url = URL.createObjectURL(await answer.blob());
      window.open(url, "_blank");
      setTimeout(() => URL.revokeObjectURL(url), 10 * 60 * 1000);
    } catch (error) { this._status = error.message; this.requestUpdate(); }
  }

  render() {
    if (!this._api) return null;              // unwired: paint nothing (see #boot)
    const reply = this._reply;
    let hits = [];
    if (reply) {
      const strongN = Math.min(reply.strong ?? reply.hits.length, reply.hits.length);
      hits = reply.hits.map((hit, at) => ({ hit, strong: at < strongN }));
      if (this._kinds) {
        const wanted = this._kinds.split(",");
        hits = hits.filter((h) => wanted.includes(h.hit.kind));
      }
      if (this._strong) hits = hits.filter((h) => h.strong);
    }
    const ms = (reply && reply.ms) || {};
    const bits = [];
    if (reply) {
      bits.push(`${reply.hits.length} hits · ${Math.min(reply.strong ?? reply.hits.length, reply.hits.length)} strong`);
      if (reply.meaning) bits.push(`embed ${ms.embed ?? 0} ms · search ${ms.search ?? 0} ms`);
      if (!reply.meaning) bits.push("words only — pause typing for meaning");
      if (reply.warning) bits.push(reply.warning);
    }
    return html`
      <header class="bar embed-bar">
        <input id="q" type="search" autofocus autocomplete="off" spellcheck="false" .value=${this._text}
               placeholder="Search your media…" aria-label="Search" aria-describedby="statusline"
               @input=${(e) => this.#run(e.target.value)}>
        <label class="embed-count" title="Results per search — the engine's own cap is 100">
          <select id="limit" aria-label="Number of results" .value=${String(this._limit)}
                  @change=${(e) => { this._limit = Number(e.target.value); this.#run(this._text); }}>
            <option value="20">20</option>
            <option value="40" selected>40</option>
            <option value="100">100</option>
          </select>
          results
        </label>
        ${this._activity ? html`<span class="activity"><span class="dot"></span></span>` : null}
      </header>
      <nav class="embed-chips" aria-label="Filters">
        <button class="chip ${!this._kinds ? "on" : ""}" data-kind="" type="button"
                @click=${() => { this._kinds = ""; this.requestUpdate(); }}>All</button>
        ${[["image,screenshot", "Photos"], ["video", "Videos"], ["pdf,doc,audio", "Docs"]].map(([k, label]) => html`
          <button class="chip ${this._kinds === k ? "on" : ""}" data-kind=${k} type="button"
                  @click=${() => { this._kinds = k; this.requestUpdate(); }}>${label}</button>`)}
        <label class="chip chip-check" title="Only hits that clear the engine's 2.0σ strength gate">
          <input id="strong" type="checkbox" .checked=${this._strong}
                 @change=${(e) => { this._strong = e.target.checked; this.requestUpdate(); }}> strong only
        </label>
      </nav>
      <main>
        <p id="statusline" role="status">${reply ? bits.join(" · ") : this._status}</p>
        <ul id="results" class="embed-grid">
          ${hits.map(({ hit, strong }) => html`
            <li class="tile ${strong ? "strong" : ""}" data-media=${hit.media_id || ""} data-kind=${hit.kind}
                .ref=${(el) => { if (el) this._tileRefs.set(hit.media_id, el); }}
                @click=${() => this.#openHit(hit)}>
              ${this._previews.has(hit.media_id)
                ? html`<img alt="" .src=${this._previews.get(hit.media_id)}>` : null}
              <span class="kind">${KIND_LABEL[hit.kind] || hit.kind}</span>
              <span class="name" title=${hit.path}>${baseName(hit.path)}</span>
              ${hit.z !== undefined ? html`<span class="z">z ${hit.z.toFixed(2)}</span>` : null}
              ${hit.loc !== undefined && hit.loc !== null
                ? html`<span class="loc">at ${Math.round(hit.loc)}s</span>` : null}
            </li>`)}
        </ul>
      </main>`;
  }
}
if (!customElements.get("digup-embed")) customElements.define("digup-embed", DigupEmbed);
