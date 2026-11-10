// digup-app — the application shell: the page tree (header, gear panel, search,
// state panels, results grid, preview, footer, big look), the gear's open/close with
// aria-expanded kept true to the panel's state on every path, the document-level
// keyboard (Esc chain, arrow navigation, the Space guard that never hijacks native
// button/link activation — the reviewer's finding, pinned), the 15 s status poll,
// and the ONE layout switch: `document.body.dataset.page` (idle | busy | results |
// none) written at every render, the first included — the vanilla render() at
// startup rule ("the first paint is a state too"), plus the host mirror the shadow
// panels gate on. All cross-component wiring: the search route, the select/open/
// preview events, the settings commands → controllers. State lives in the store;
// sequencing lives in the controllers; this file composes them.
import { LitElement, html, css, nothing } from "lit";
import { storeController } from "../app/store.js";
import { activityCss, noteCss } from "../styles/controls.js";
import { emptyAnswer, WEAKER } from "../lib/format.js";

import "./digup-search.js";
import "./digup-suggest.js";
import "./digup-results.js";
import "./digup-preview.js";
import "./digup-big.js";
import "./digup-footer.js";
import "./digup-settings.js";

const IDLE_NOTE = "Say what you'd see, hear, or read in a file — the meaning, not only the "
                + "words. Results appear as you type.";
const BUSY_NOTE = "Matching words now — the meaning results follow when you stop typing.";
const CODE_HINT = "Searching your code — say what the code does, or type a name that's in it.";

const SUGGESTIONS = ["a dog running on the beach", "people gathered around a campfire",
                     "a cat sitting on a sofa", "wakeboarding on a lake"];

class DigupApp extends LitElement {
  static properties = { page: { state: true }, bigOpen: { state: true },
                        _gearAttention: { state: true }, _statusTick: { state: true } };

  static styles = [activityCss, noteCss, css`
    :host { display: block; }   /* deterministic width for the header's bleed (below) */
    /* header: row 1 — title at the LEFT SCREEN EDGE, gear at the RIGHT SCREEN EDGE (the
       round-5 layout brief: the bar bleeds past the 72 rem content column, padding-inline
       keeps the 1.25 rem inset); row 2 — the searchable count centered on the same axis
       as everything else. The settings panel hangs off the header's right edge, directly
       under the gear (the gear IS the anchor). */
    header.bar { position: relative; display: grid; gap: 0.3rem;
      margin-inline: calc(50% - 50vw); padding-inline: 1.25rem; }
    .bar-top { display: flex; align-items: baseline; justify-content: space-between; gap: 0.8rem; }
    h1 { font-size: 1.3rem; margin: 0; }
    .bar-center { display: flex; align-items: baseline; justify-content: center; gap: 0.6rem; flex-wrap: wrap; }
    #gear { flex: none; width: 2.1rem; height: 2.1rem; display: grid; place-items: center;
      border: 1px solid var(--edge); border-radius: var(--radius-pill); padding: 0;
      background: var(--field); color: var(--text); cursor: pointer; }
    #gear svg { display: block; width: 15px; height: 15px; }
    #gear:hover { border-color: var(--accent); }
    /* a 401 with no stored key points at the gear: a soft pulse until the panel opens */
    #gear.attention { animation: gear-pulse 1.6s ease-in-out 3; }
    @keyframes gear-pulse { 50% { box-shadow: 0 0 0 3px var(--accent); } }

    /* ── the page's states: data-page on body (global layout) mirrored on :host
        (this shadow), both written by render(): the ONE switch the vanilla UI had
        (body[data-page], set by app.js render(), read by style.css):
          idle    nothing typed → centered welcome + suggestions; no list, no preview, no counter
          busy    words matching, meaning on its way → same centered block, its note says so
          results the two columns, list ~40 % / preview ~60 %
          none    meaning answered zero hits → centered message carrying the engine's own sentence
        The preview pane reserves NO space for a state with nothing to show. */
    #idle, #no-results { display: none; }
    :host([data-page="idle"]) #idle, :host([data-page="busy"]) #idle,
    :host([data-page="none"]) #no-results { display: block; }
    #results { display: none; }
    :host([data-page="results"]) #results { display: grid; }
    :host([data-page="busy"]) #suggest { display: none; }   /* suggestions are an idle affordance */
    :host([data-code]) #suggest { display: none; }          /* …and they are not code-search hints */

    #idle, #no-results { max-width: 34rem; margin: 3rem auto 3.5rem; padding: 0 1rem; text-align: center; }
    #idle h2, #no-results h2 { font-size: 1.18rem; font-weight: 600; margin: 0 0 0.4rem; }
    #idle p, #no-results p { color: var(--soft); margin: 0 auto; max-width: 30rem; }
    #no-results .hint { margin-top: 0.7rem; font-size: 0.85rem; }
    #no-results code { font: 0.85rem var(--font-mono); }
    #suggest { display: flex; }

    /* A state change is a layout change, so the panel that arrives fades in: display cannot be
       transitioned, and an animation starts when an element gains it. Guarded for motion. */
    @media (prefers-reduced-motion: no-preference) {
      #idle, #no-results, #results { animation: rise 0.18s ease-out; }
    }
    @keyframes rise { from { opacity: 0; transform: translateY(4px); } }

    /* Results list + preview pane, like the desktop panel: the list carries the ranking, the
       pane shows the selection the way panel.js shows it. 2fr/3fr is the 40/60 the preview
       wants; minmax(0, …) keeps a long file name from widening a track past its share. */
    #results { grid-template-columns: minmax(0, 2fr) minmax(0, 3fr); gap: 1rem;
      align-items: start; margin: 0.4rem 0 1rem; }
    #preview { border: 1px solid var(--edge); border-radius: 10px; padding: 0.8rem; min-height: 12rem;
      background: var(--panel); position: sticky; top: 0.6rem; }
    /* Narrow screens: one column, and the sticky pane becomes an ordinary block below the list
       (a sticky panel on a single-column page sticks over the list it is meant to follow). */
    @media (max-width: 900px) {
      #results { grid-template-columns: minmax(0, 1fr); }
      #preview { position: static; }
      #idle, #no-results { margin-top: 1.8rem; }
    }

    footer#footer {
      position: fixed; inset: auto 0 0 0;
      background: color-mix(in srgb, var(--bg) 88%, transparent); border-top: 1px solid var(--edge);
      backdrop-filter: blur(6px);
    }
    /* the footer strip bleeds to the screen edges (round-5 layout brief): the summary
       rides the left edge, the keyboard instructions ride the RIGHT edge. */
    #footer .foot-in { display: flex; gap: 1rem; justify-content: space-between; flex-wrap: wrap;
      max-width: none; margin: 0; padding: 0.35rem 1.25rem; font-size: 0.8rem; color: var(--soft); }
    #keys { white-space: nowrap; }
    @media (max-width: 720px) {
      #keys { white-space: normal; }   /* the 48-char hint at 0.8rem overflows a 320 px viewport */
    }
  `];

  constructor() {
    super();
    this.page = "idle";
    this.bigOpen = false;
    this._gearAttention = false;
    this._sel = null;
  }

  /* ── composition: main.js wires {store, api, theme, controllers}. The html DECLARES
     this element, so its FIRST update runs before the wiring lands: render stays empty
     and the boot waits for store + api (2026-11-08 — an unwired shell must paint
     nothing, not a bare page). Wiring is a state change, so the setters requestUpdate. ── */
  set store(store) {
    if (store === this._store) return;
    this._store = store;
    this._sel = storeController(this, store, (s) => s);
    if (this.renderRoot) {
      const settings = this.renderRoot.querySelector("digup-settings");
      if (settings) settings.store = store;
    }
    this.requestUpdate();
  }
  get store() { return this._store; }

  set controllers(c) { this._ctl = c; this.requestUpdate(); }
  get controllers() { return this._ctl; }

  set api(api) { this._api = api; this.requestUpdate(); }
  get api() { return this._api; }

  set theme(theme) { this._theme = theme; }
  get theme() { return this._theme; }

  _s() { return this._sel ? this._sel.value() : {}; }

  /* The layout's state, read off the state the renderers already use: no second store,
     no second notion of "what page am I on". Hits → the two columns; nothing typed (or
     the code-prefix hint) → the centered welcome; words in, meaning on its way → busy;
     meaning answered zero → none. */
  #pageMode() {
    const s = this._s();
    const r = s.results || { strong: [], weaker: [] };
    return (r.strong.length + r.weaker.length ? "results"
      : (r.phase === "empty" || r.phase === "codeHint") ? "idle"
      : r.phase === "words" ? "busy" : "none");
  }

  firstUpdated() {
    // The keyboard + click routes belong to the page, not to a wired slice: attach them
    // here (they read the store lazily, through _s()). Everything that TALKS — the focus,
    // the 15 s status poll, the first refresh — waits for the wiring, in #boot().
    document.addEventListener("keydown", this.#docKey);
    document.addEventListener("click", this.#docClick);
    this.#boot();
  }

  #boot() {
    // The vanilla startup lines `render(); refreshStatus(); setInterval(refreshStatus,
    // 15000); $("q").focus()`, run ONCE, on the first update where the entry has wired
    // store + api (the html declares this element, so the very first update is unwired).
    if (this._booted || !this._store || !this._api) return;
    this._booted = true;
    // Focus rides on the search child's first render (its updateComplete microtask) —
    // a guard alone would silently skip the first paint's focus.
    const search = this.renderRoot.querySelector("digup-search");
    if (search) search.updateComplete.then(() => search.focusQuery());
    this._poll = setInterval(() => this.refreshStatus(), 15000);
    this.refreshStatus();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    clearInterval(this._poll);
    document.removeEventListener("keydown", this.#docKey);
    document.removeEventListener("click", this.#docClick);
  }

  updated() {
    if (this._store) this.#syncPage();      // the layout's ONE switch, at every paint
    this.#boot();                           // fires on the update where the wiring lands
    const s = this._s();
    const settings = this.renderRoot.querySelector("digup-settings");
    if (settings) settings.store = this._store;
    if (settings && !settings.hasAttribute("hidden")) settings.theme = this._theme?.current() ?? "system";
    // A store change repaints the shell's children through bindings; the host mirror
    // for the shadow panels rides with data-page.
  }

  #syncPage() {
    const mode = this.#pageMode();
    document.body.dataset.page = mode;
    this.dataset.page = mode;
    const s = this._s();
    this.toggleAttribute("data-code", Boolean(s.isCode));
  }

  render() {
    // Unwired: paint NOTHING (the html declares this element, so the first update can
    // precede main.js's wiring — a bare page there is the "double DigUp" symptom).
    if (!this._store || !this._api) return null;
    const s = this._s();
    const r = s.results || { strong: [], weaker: [], groups: [], showWeaker: false,
                             selection: null, hitsById: new Map() };
    const mode = this.#pageMode();
    const indexing = s.indexing;
    const showActivity = s.encoder === "starting" || Boolean(indexing);
    const hit = r.hitsById.get(r.selection) ?? null;
    return html`
      <header class="bar">
        <div class="bar-top">
          <h1>DigUp</h1>
          <button id="gear" type="button" aria-label="Settings"
                  aria-expanded=${String(this._settingsOpen === true)} aria-controls="settings"
                  class=${this._gearAttention ? "attention" : ""}
                  title="Settings — appearance, index controls, estimate, the engine's counts"
                  @click=${this.#gearClick}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
                 stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <circle cx="12" cy="12" r="3"></circle>
              <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path>
            </svg>
          </button>
        </div>
        <div class="bar-center">
          ${showActivity ? html`
            <span class="activity" title=${indexing
              ? `indexing: ${indexing.files_done ?? 0} of ${indexing.files ?? "?"} files`
              : "The engine is working: results may miss files it has not read yet"}>
              <span class="dot"></span>
              <span>${indexing ? "indexing…" : "meaning search warming up…"}</span>
            </span>` : null}
        </div>
        <digup-settings id="settings" ?hidden=${this._settingsOpen !== true}
                        .store=${this._store}
                        @digup:close=${() => this.closeSettings()}
                        @digup:theme=${(e) => { this._theme?.apply(e.detail.choice); this.requestUpdate(); }}
                        @digup:index=${(e) => this._ctl?.jobs?.indexNow(e.detail.prune)}
                        @digup:estimate=${() => { this._ctl?.estimate?.setToggle(true); this._ctl?.estimate?.runEstimate(); }}
                        @digup:regenerate=${() => this._ctl?.keys?.regenerate()}>
        </digup-settings>
      </header>

      <main>
        <digup-search .isCode=${Boolean(s.isCode)} .navigated=${Boolean(s.navigated)}
                      .hasSelection=${Boolean(r.selection)}
                      @digup:query-change=${(e) => this._ctl?.search?.queryChanged(e.detail.text, e.detail)}
                      @digup:nav=${(e) => this._ctl?.search?.move(e.detail.step)}
                      @digup:activate=${() => {
                        if (this._s().results?.selection === WEAKER) this._ctl?.search?.toggleWeaker();
                        else this.#openHit(this._ctl?.search?.selectedHit());
                      }}
                      @digup:preview=${() => this.#previewRequest()}>
        </digup-search>

        <section id="idle">
          <h2>Describe it. Dig it up.</h2>
          <p id="idle-note">${mode === "busy" ? BUSY_NOTE
            : (r.phase === "codeHint" ? CODE_HINT : IDLE_NOTE)}</p>
          <div id="suggest" role="group" aria-label="Search suggestions">
            <digup-suggest .phrases=${SUGGESTIONS}
                           @digup:set-query=${(e) => this.renderRoot.querySelector("digup-search")?.setValue(e.detail.phrase)}></digup-suggest>
          </div>
        </section>

        <section id="no-results" role="status">
          <h2>No results found</h2>
          <p id="no-results-why">${this.#noResultsWhy(r)}</p>
          <p class="hint">Widening the kind filters, or turning off <code>code</code>, asks the
             engine to look in more of your files.</p>
        </section>

        <section id="results">
          <digup-results .results=${r}
                         @digup:select=${(e) => this._ctl?.search?.select(e.detail.mediaId)}
                         @digup:open=${(e) => this.#openHit(this._s().results?.hitsById?.get(e.detail.mediaId))}
                         @digup:toggle-weaker=${() => this._ctl?.search?.toggleWeaker()}>
          </digup-results>
          <digup-preview id="preview" .hit=${r.selection === WEAKER ? WEAKER : hit}
                         .weakerCount=${r.weaker.length} .showWeaker=${r.showWeaker}></digup-preview>
        </section>
      </main>

      <footer id="footer">
        <div class="foot-in">
          <digup-footer .results=${r} .indexing=${indexing} .error=${s.error}></digup-footer>
          <span id="keys">↑↓ pick · ↩ open · Space preview · Esc clear · type to search</span>
        </div>
      </footer>

      <digup-big ?hidden=${!this.bigOpen} .hit=${this.bigOpen ? hit : null}
                 @digup:close=${() => { this.bigOpen = false; }}></digup-big>`;
  }

  #noResultsWhy(r) {
    if (!r.lastReply) return "Try describing what you'd see or hear in it — a scene, an object, "
                           + "a moment, words you remember from it.";
    const reply = r.lastReply;
    return emptyAnswer(reply) + (reply.warning ? ` (${reply.warning})` : "");
  }

  /* ── opening a result (the desktop's Open: the file itself; video plays from its moment) ── */
  #openHit(hit) {
    if (!hit) return;
    window.open(`/api/v1/media/${hit.media_id}/file`, "_blank", "noopener");
  }

  /* Space previews (the big look) — the vanilla rule: after navigation, on a
     selection; on the WEAKER row Space/↩ fold and unfold. */
  #previewRequest() {
    const s = this._s();
    if (s.results?.selection === WEAKER) { this._ctl?.search?.toggleWeaker(); return; }
    this.bigOpen = !this.bigOpen;
  }

  /* ── gear / settings: all five close paths share one function — the gear's
      aria-expanded must match the panel's hidden state everywhere (a screen reader
      must not report an open dialog whose panel is gone), and focus returns to the
      gear (closing must not drop the keyboard user to <body>). ── */
  #gearClick = () => {
    const open = this._settingsOpen !== true;
    this._settingsOpen = open;
    this._gearAttention = false;                        // pointing done: the panel is open
    this.requestUpdate();
    const settings = this.renderRoot.querySelector("digup-settings");
    if (open) {
      settings.focusFirst();
      this._ctl?.keys?.resetRetried();                  // a fresh open may try the stale-key recovery once
      this._ctl?.keys?.loadAccess();                    // keys + indexes, admin scope
    }
  };

  closeSettings() {
    const settings = this.renderRoot.querySelector("digup-settings");
    const hadFocus = settings && (settings.contains(document.activeElement)
      || settings.shadowRoot.contains(document.activeElement));
    this._settingsOpen = false;
    this.requestUpdate();
    if (hadFocus) this.renderRoot.getElementById("gear").focus();
  }

  #docClick = (event) => {
    if (this._settingsOpen !== true) return;
    // closest(), not a bare equality: the gear's svg is the click target, not the button.
    const path = event.composedPath();
    if (path.includes(this.renderRoot.getElementById("gear"))
        || path.includes(this.renderRoot.querySelector("digup-settings"))) return;
    this.closeSettings();
  };

  /* Keys and events (the footer says them; they work from the search field and the list). */
  #docKey = (event) => {
    const first = event.composedPath()[0] || event.target;
    const inField = ["INPUT", "SELECT", "TEXTAREA"].includes(first.tagName)
                    || (first.host && ["INPUT", "SELECT", "TEXTAREA"].includes(first.host.tagName));
    switch (event.key) {
      case "Escape":
        if (this.bigOpen) { event.preventDefault(); this.bigOpen = false; }
        else if (this._settingsOpen === true) { event.preventDefault(); this.closeSettings(); }
        else if (this._s().estimate?.rows || this._s().estimate?.spinning) {
          event.preventDefault(); this._ctl?.estimate?.cancel();
        }
        else if (this.renderRoot.querySelector("digup-search")?.shadowRoot.getElementById("q")?.value) {
          this.renderRoot.querySelector("digup-search").clearAndRefocus();
        }
        break;
      case "ArrowDown":
      case "ArrowUp":
        if (first.tagName === "DIGUP-SEARCH" || inField) break;   // the field has its own handler
        event.preventDefault();
        this._ctl?.search?.move(event.key === "ArrowDown" ? 1 : -1);
        break;
      case " ":
        // Native button/link activation happens on keyup: preventing default here (the
        // Quick-Look preview) silently killed Space-activation of the gear, ✕, Index now,
        // Estimate, "all", the Esc close, and Open/Download — Space is a keyboard user's
        // standard activation key, so buttons and links keep it; only bare page areas type-preview.
        // In shadow DOM the activation target lives in the composed path: run the guard
        // from the deepest node up, keeping the pinned selector verbatim.
        for (const node of event.composedPath()) {
          if (node instanceof Element && node.closest
              && node.closest("button, a, [role='button'], input, select, textarea")) return;
        }
        if (first.tagName === "DIGUP-SEARCH") break;             // typing a space (the field handler above)
        const s = this._s();
        if (!s.navigated && inField) return;
        if (!s.results?.selection && !inField) return;
        event.preventDefault();
        this.#previewRequest();
        break;
    }
  };

  /* The 15 s status poll (the engine's numbers live in the settings panel; the main
     page keeps only the activity dot — a page that nags "paste your key" on every
     poll is noise: the gear points at the key, and the counts are the panel's). */
  async refreshStatus() {
    try {
      const st = await this._api("/api/v1/status");
      this._store.set({
        encoder: st.encoder,
        status: { files: st.files, searchable: st.searchable,
                  vectors: st.vectors, encoder: st.encoder, kinds: st.kinds || [],
                  index_size: st.index_size, build_tag: st.build_tag },
      });
    } catch {
      // No counts to show: a no-key browser sees the gear point at the key (api()
      // raised with the pointer); a mid-reload refusal is a state, the next poll
      // re-reads. The main page stays clean.
    }
  }

  // The api's 401-with-no-key pointer (main.js wires createApiClient.onNoToken here).
  noteMissingKey() { this._gearAttention = true; this.requestUpdate(); }
}
if (!customElements.get("digup-app")) customElements.define("digup-app", DigupApp);
