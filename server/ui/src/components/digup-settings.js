// digup-settings — the gear panel: the server's own controls, anchored under the gear.
// Four stacked sections (the 2026-11-08 layout brief): APPEARANCE · INDEXING ·
// INDEX STATUS · API ACCESS — each with a small icon and a 15–16 px semibold heading,
// 20 px section rhythm on 1 px dividers, 10–12 px radii, muted secondary descriptions,
// restrained blue accents, and ONE distinct card (the index status). The modal's frame —
// its width, its anchor under the gear, the overlay order, the open/close paths — is
// unchanged; only the internal layout is this brief.
//
// All five close paths (gear, ✕, click-outside, Esc, target change) report through
// digup:close so the gear's aria-expanded matches the panel's hidden state everywhere.
// Sections read the store's slices; the controls act through the events below — the
// controllers own what they do. The panel NEVER scrolls (round-7 layout brief):
// overflow-x: clip — a scroller made a clipping box that cut controls at the panel's
// edges, its scrollbar stole ~10 px from the control column, and the panel could
// overflow the viewport. Only the forecast box scrolls, inside its own bounds.
// Every row is the 2 rem row token (round-3); narrow windows fold the grid (§ media).
import { LitElement, html, css } from "lit";
import { storeController } from "../app/store.js";
import { duration } from "../lib/format.js";
import { controlCss, badgeCss, keyRowCss, jobStateCss, spinCss } from "../styles/controls.js";

/* Section icons: 15 px, 1.8 stroke, currentColor, aria-hidden (the heading carries the
   name). They ride the accent — the panel's one decorative color. */
const icon = (paths) => html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
  stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"
  focusable="false">${paths}</svg>`;
const PALETTE_ICON = icon(html`
  <path d="M12 3a9 9 0 1 0 0 18c1.4 0 2.2-1 2.2-2.1 0-1.4-1.1-1.9-1.1-2.9 0-1 .8-1.5 1.9-1.5H17a4 4 0 0 0 4-4C21 6.9 17 3 12 3z"></path>
  <circle cx="7.5" cy="10.5" r="1.1"></circle><circle cx="12" cy="7.5" r="1.1"></circle>
  <circle cx="16.5" cy="10.5" r="1.1"></circle>`);
const DATABASE_ICON = icon(html`
  <ellipse cx="12" cy="5.5" rx="7" ry="2.8"></ellipse>
  <path d="M5 5.5v6c0 1.6 3.1 2.8 7 2.8s7-1.2 7-2.8v-6"></path>
  <path d="M5 11.5v6c0 1.6 3.1 2.8 7 2.8s7-1.2 7-2.8v-6"></path>`);
const ACTIVITY_ICON = icon(html`<path d="M3 12h4l2.5-7 4 14 2.5-7h5"></path>`);
const KEY_ICON = icon(html`
  <circle cx="8" cy="15.5" r="4"></circle>
  <path d="M11 12.8 20.5 3.3M17.5 6.3l2.4 2.4"></path>`);

class DigupSettings extends LitElement {
  static properties = { theme: {} };

  static styles = [controlCss, badgeCss, keyRowCss, jobStateCss, spinCss, css`
    /* :host is the panel hanging off the header's right edge, directly under the gear
       (the gear IS the anchor — header.bar is position:relative). The frame is the
       measured one: same width, same anchor, same shadow, overflow-x: clip. */
    :host([hidden]) { display: none; }
    :host { position: absolute; right: 1.25rem; top: calc(100% + 0.45rem); z-index: var(--z-panel);
      /* right: 1.25rem — the header bar's padding-inline: the panel's edge lines up with
         the gear, whose header content edge sits that far in from the bled bar (round-5). */
      width: min(27rem, calc(100vw - 2rem));
      display: flex; flex-direction: column; gap: 0; padding: 0.9rem 0.95rem 1rem;
      background: var(--panel); border: 1px solid var(--edge); border-radius: var(--radius-lg);
      box-shadow: 0 8px 28px rgb(0 0 0 / 22%);
      max-height: calc(100vh - 3rem); overflow-x: clip; }
    .set-head { display: flex; justify-content: space-between; align-items: center;
      font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--soft); }
    #settings-close { padding: 0.1rem 0.55rem; font-size: 0.8rem; line-height: 1.2; }

    /* Section rhythm (the layout brief): 22 px around each 1 px divider (space-md above,
       space-md below — the brief's 18–22 px), the heading on its own row. Only INDEX
       STATUS is a card — the sections are separated by dividers, not by boxes. */
    .set-sec { display: grid; grid-template-columns: minmax(0, 1fr); gap: var(--space-sm);
      padding-top: var(--space-md); margin-top: var(--space-md);
      border-top: 1px solid var(--line); }
    .set-sec:first-of-type { border-top: 0; padding-top: var(--space-sm); margin-top: var(--space-sm); }
    .set-sec > * { min-width: 0; }
    .set-title { display: flex; align-items: center; gap: 0.45rem; font-size: 0.95rem;
      font-weight: 600; letter-spacing: 0.01em; color: var(--text); }
    .set-title svg { width: 15px; height: 15px; flex: none; color: var(--accent); }
    .set-line { display: flex; align-items: center; gap: var(--space-md); flex-wrap: wrap; }
    select, button, .set-line, .appkey-line { min-height: var(--row-height); box-sizing: border-box; }
    .set-line label { display: inline-flex; align-items: center; gap: 0.4rem;
      min-height: var(--row-height); color: var(--soft); font-size: var(--text-sm); }
    /* The Appearance select IS a control of its section: full width, its edges matching
       the rows under it (the native popup opens in the top layer, never clipped). */
    select#theme { width: 100%; max-width: 100%; }

    /* The INDEXING heading carries the live state (round-6 brief): the spinning circle
       while the engine works, ✓ when it finished, the brief update at the heading's
       right edge. The job's own words ride the jobStateCss pill tones. */
    .set-head-row { display: flex; align-items: center; gap: 0.5rem;
      justify-content: space-between; flex-wrap: wrap; }
    .set-state { display: inline-flex; align-items: center; gap: 0.45rem; min-width: 0; }
    .set-state #job { font-size: var(--text-sm); overflow-wrap: anywhere; }
    .state-done { color: var(--good); font-weight: 600; }
    .state-err { color: var(--warn); font-weight: 600; }

    /* INDEX STATUS — the one card: the two counts side by side, the capability badges
       wrapping naturally below. Semantic tones: healthy green, inactive muted, problem
       red. (The roots line left the card, round-5 brief: the counts carry the state.) */
    .status-card { display: grid; gap: var(--space-sm); padding: 0.7rem 0.8rem;
      border: 1px solid var(--edge); border-radius: var(--radius-lg); background: var(--bg); }
    .stats { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: var(--space-sm); }
    .stat { display: grid; gap: 0.15rem; padding: 0.4rem 0.6rem;
      border: 1px solid var(--line); border-radius: var(--radius-lg); background: var(--panel); }
    .stat-label { color: var(--soft); font-size: var(--text-xs); }
    .stat-value { font-size: 1.05rem; font-weight: 600; color: var(--text);
      overflow-wrap: anywhere; }
    .set-facts { display: flex; gap: 0.35rem; flex-wrap: wrap; align-items: center;
      min-height: var(--row-height); box-sizing: border-box; }
    .set-facts .badge { margin-right: 0; }
    .badge.ok { color: var(--good); border-color: color-mix(in srgb, var(--good) 55%, var(--edge)); }
    .badge.amber { color: var(--amber); border-color: color-mix(in srgb, var(--amber) 55%, var(--edge)); }
    .badge.err { color: var(--warn); border-color: color-mix(in srgb, var(--warn) 55%, var(--edge)); }
    .badge.off { color: var(--soft); }

    /* The panel's boxes ride the 12 px radius (the layout brief's 10–12 px, one value
       everywhere): the key rows + key field get it scoped HERE — the shared keyRowCss
       keeps the embed widget's measured rows untouched. The field nests at 8 px
       (outer radius minus the row's padding). */
    .appkey-line { border-radius: var(--radius-lg); }
    .appkey-field { border-radius: var(--radius-md); }

    @media (max-width: 720px) {
      /* Narrow windows (round-7 layout brief, kept by the round-6 redesign): the panel
         owns the width, the two counts stack, the heading state wraps under the title,
         nothing is squeezed and the panel never scrolls. */
      :host { width: calc(100vw - 2rem); }
      .stats { grid-template-columns: minmax(0, 1fr); }
    }
  `];

  constructor() {
    super();
    this.theme = "system";
    this._sel = null;
  }

  // The store slice the panel reads (keys, status facts, roots, job line, estimate
  // rows) — one subscription through storeController once `store` is set.
  set store(store) {
    if (store === this._store) return;
    this._store = store;
    this._sel = storeController(this, store, (s) => [s.keys, s.status, s.job, s.estimate]);
  }
  get store() { return this._store; }

  render() {
    const [keysIn, status, job, estimateRow] =
      this._sel ? this._sel.value() : [null, null, null, null];
    const keys = keysIn || { admin: null, apps: [], envFlagged: false, minted: false };
    const e = estimateRow || { spinning: false, rows: null, error: null };
    const jobRun = job && (job.state === "queued" || job.state === "running");
    const estRun = Boolean(e.spinning) && !jobRun;
    let state = null;
    if (jobRun) state = { spin: true, text: job.text, cls: `job-state job-${job.state}` };
    else if (estRun) state = { spin: true, text: "estimating…", cls: "" };
    else if (job) state = job.state === "done"
      ? { done: true, text: job.text, cls: "job-state job-done" }
      : { err: true, text: job.text, cls: `job-state job-${job.state}` };
    else if (e.rows) state = { done: true, cls: "",
      text: `estimate ≈ ${duration(e.rows.reduce((n, f) => n + (f.seconds || 0), 0))}`
          + ` · ${e.rows.length} folder${e.rows.length === 1 ? "" : "s"}` };
    else if (e.error) state = { err: true, cls: "", text: "estimate failed", title: e.error };
    return html`
      <div class="set-head">
        <span>Settings</span>
        <button id="settings-close" type="button" aria-label="Close settings"
                @click=${this.#close}>✕</button>
      </div>

      <section class="set-sec" aria-labelledby="set-appearance">
        <span class="set-title" id="set-appearance">${PALETTE_ICON} Appearance</span>
        <select id="theme" title="Appearance — kept in this browser" .value=${this.theme}
                @change=${(ev) => this.dispatchEvent(new CustomEvent("digup:theme",
                  { bubbles: true, composed: true, detail: { choice: ev.target.value } }))}>
          <option value="system">System</option>
          <option value="light">Light</option>
          <option value="dark">Dark</option>
        </select>
      </section>

      <section class="set-sec" aria-labelledby="set-indexing">
        <!-- Round-6 brief: no estimates toggle, no forecast section — the Estimate button
             rides the Index now row, and the heading carries the live state: spinning
             circle while the engine works (index job or estimate), ✓ when it finished,
             the brief update at the heading's right (the job's own words verbatim). -->
        <div class="set-head-row">
          <span class="set-title" id="set-indexing">${DATABASE_ICON} Indexing</span>
          ${state ? html`<span class="set-state">
            ${state.spin ? html`<span id="estimate-spin" class="estimate-spin" aria-label="working"></span>` : null}
            ${state.done ? html`<span class="state-done" aria-hidden="true">✓</span>` : null}
            ${state.err ? html`<span class="state-err" aria-hidden="true"
                                    title=${state.title || state.text}>!</span>` : null}
            <span id="job" class="${state.cls}">${state.text}</span></span>` : null}
        </div>
        <div class="set-line">
          <button id="estimate-btn" title="What the folders would cost to index — the engine's own forecast"
                  @click=${() => this.dispatchEvent(new CustomEvent("digup:estimate",
                    { bubbles: true, composed: true }))}>Estimate</button>
          <button id="index-btn" title="Run one index sync now (one writer at a time)"
                  @click=${() => this.dispatchEvent(new CustomEvent("digup:index",
                    { bubbles: true, composed: true, detail: { prune: this.renderRoot.getElementById("prune")?.checked } }))}>Index now</button>
          <label id="prune-label" title="Also retire index rows for files no longer in the folders — the procedure after remounting media">
            <input id="prune" type="checkbox"> prune missing
          </label>
        </div>
      </section>

      <section class="set-sec" aria-labelledby="set-status">
        <span class="set-title" id="set-status">${ACTIVITY_ICON} Index status</span>
        <div class="status-card">
          <div class="stats">
            <div class="stat">
              <span class="stat-label">Total files</span>
              <span class="stat-value">${status && status.files != null ? status.files : "—"}</span>
            </div>
            <div class="stat">
              <span class="stat-label">Searchable files</span>
              <span class="stat-value">${status && status.searchable != null ? status.searchable : "—"}</span>
            </div>
          </div>
          <span class="set-facts">
            ${status ? html`
              <span class="badge ${status.vectors > 0 ? "ok" : "off"}">${status.vectors} vectors</span>
              <span class="badge ${status.encoder === "ready" ? "ok"
                     : status.encoder === "starting" ? "amber"
                     : status.encoder === "unavailable" ? "err" : "off"}">encoder ${status.encoder}</span>
              ${(status.kinds || []).map((k) => html`<span class="badge">${k.kind} ${k.files}</span>`)}
              <span class="badge">index ${status.index_size}</span>
              <span class="badge">llama.cpp ${status.build_tag}</span>` : null}
          </span>
        </div>
      </section>

      <section class="set-sec" id="api-key-sec" aria-labelledby="set-apikey"
               ?hidden=${!this.#hasKeyRows(keys)}>
        <span class="set-title" id="set-apikey">${KEY_ICON} API access</span>
        <!-- One key per row: the key in a field (click selects all), the clipboard and
             the refresh as square icon buttons at its right (round-3 brief; names in
             aria-label + title). -->
        <div id="appkeys">
          ${keys.admin ? html`
            <div class="appkey-line">
              <input class="appkey-field" readonly spellcheck="false" .value=${keys.admin}
                     aria-label="This server's admin API key" title="Click to select the whole key"
                     @click=${(ev) => ev.target.select()}>
              <button type="button" class="key-icon" aria-label="Copy this API key to the clipboard"
                      title="Copy this API key to the clipboard"
                      @click=${(ev) => this.#copy(keys.admin, ev.currentTarget)}>⧉</button>
              <button id="keys-regenerate" type="button" class="key-icon"
                      aria-label="Regenerate: new keys now, the old ones stop working"
                      title="Regenerate: new keys now, the old ones stop working"
                      @click=${() => this.dispatchEvent(new CustomEvent("digup:regenerate",
                        { bubbles: true, composed: true }))}>↻</button>
            </div>` : null}
          ${keys.apps.map((a) => html`
            <div class="appkey-line">
              <span class="appkey-name">${a.name}</span>
              <input class="appkey-field" readonly spellcheck="false" .value=${a.token}
                     aria-label=${`API key for ${a.name}`} title="Click to select the whole key"
                     @click=${(ev) => ev.target.select()}>
              <button type="button" class="key-icon" aria-label="Copy this API key to the clipboard"
                      title="Copy this API key to the clipboard"
                      @click=${(ev) => this.#copy(a.token, ev.currentTarget)}>⧉</button>
            </div>`)}
          ${!keys.admin && keys.envFlagged ? html`
            <div class="appkey-line">
              <span class="appkey-name">Set in the server's environment</span>
            </div>` : null}
        </div>
      </section>`;
  }

  /* Copy (round-5 brief): the panel is reachable over http on the LAN — an insecure
     context, where navigator.clipboard does not exist at all. The async clipboard is
     used when present, a hidden textarea + execCommand("copy") when not; the button
     answers with ✓ (it worked) or — (it did not) for a moment, then Lit restores ⧉. */
  async #copy(text, btn) {
    let ok = false;
    try { await navigator.clipboard.writeText(text); ok = true; }
    catch {
      const ta = document.createElement("textarea");
      ta.value = text; ta.setAttribute("readonly", "");
      ta.style.cssText = "position:fixed;top:-3rem;opacity:0;";
      document.body.append(ta);
      ta.select(); ta.setSelectionRange(0, text.length);
      try { ok = document.execCommand("copy"); } catch { ok = false; }
      ta.remove();
    }
    btn.textContent = ok ? "✓" : "—";
    setTimeout(() => { if (btn.isConnected) btn.textContent = "⧉"; }, 1500);
  }

  #hasKeyRows(keys) {
    // A section with nothing in it collapses: the tokenless server mints no keys
    // (they appear when an application registers) — no title-only fragment (2026-11-08
    // styling ask, round 3). Regenerate exists only where keys are minted; an
    // env-keyed server answers 400 — its keys live in its own config.
    return Boolean(keys.admin) || keys.apps.length > 0 || (!keys.admin && keys.envFlagged);
  }

  #close = () => this.dispatchEvent(new CustomEvent("digup:close",
    { bubbles: true, composed: true }));

  // Keyboard users: the panel focuses its first control when it opens (the vanilla
  // gear-open rule), and the Esc chain's "close the forecast" path lives here.
  focusFirst() {
    const first = this.renderRoot.querySelector("select, button, input");
    first?.focus();
  }
}
if (!customElements.get("digup-settings")) customElements.define("digup-settings", DigupSettings);
