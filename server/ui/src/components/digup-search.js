// digup-search — the search box row (input + limit + code), the kind chips, and the
// ONE search route: every change emits `digup:query-change` with the full filter set
// (text, code, kinds, limit) and the search-controller runs it. The code prefix and
// the box are one state (the controller writes store.isCode; updated() reflects it
// into the box, as app.js did `$("code").checked = code`). In-field keys mirror the
// desktop panel: ↑↓ pick results (digup:nav), ↩ opens the pick (digup:activate),
// Space previews only after navigation (digup:preview). Markup and strings ride the
// vanilla index.html verbatim — test_media_ui greps them from the bundle.
import { LitElement, html, css } from "lit";
import { controlCss } from "../styles/controls.js";

const KINDS = [["screenshot", "Screenshots"], ["image", "Images"], ["pdf", "PDFs"],
               ["doc", "Documents"], ["video", "Video"], ["audio", "Audio"]];

class DigupSearch extends LitElement {
  static properties = {
    isCode: {},
    navigated: {},
    hasSelection: {},
    _code: { state: true },
    _limit: { state: true },
    _kinds: { state: true },
  };

  static styles = [controlCss, css`
    :host { display: block; }
    /* the search row (round-5 layout brief): the input's center IS the page's center, on
       the SAME axis as the chips under it. On wide screens the limit select + code box
       leave the flow (absolute, riding the input's right edge) so the 1fr/1fr columns
       balance exactly; below 1000 px they drop back into the flow as a centered row. */
    #searchbox { display: grid; grid-template-columns: 1fr auto 1fr; gap: 0.5rem;
      align-items: center; margin: 0.9rem auto 0.3rem; max-width: 60rem; position: relative; }
    #q { grid-column: 2; width: min(34rem, calc(100vw - 11rem)); padding: 0.55rem 0.7rem; }
    #search-side { grid-column: 1 / -1; display: flex; align-items: center; justify-content: center;
      gap: 0.5rem; min-width: 0; flex-wrap: wrap; }
    @media (min-width: 1000px) {
      #search-side { grid-column: 3; position: absolute; right: 0; top: 50%;
        transform: translateY(-50%); }
    }
    #q:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
    #code-label { display: inline-flex; align-items: center; gap: 0.35rem; font-size: 0.85rem;
      color: var(--soft); white-space: nowrap; }
    /* the kind chips: themed per kind, filled when ticked, evenly spaced under the search. */
    #find { display: flex; gap: 0.5rem; margin: 0.5rem 0 0.2rem; justify-content: center; flex-wrap: wrap; }
    #find .kind { --kc: var(--soft); display: inline-flex; align-items: center; gap: 0.4rem;
      border: 1px solid var(--edge); border-radius: var(--radius-pill); padding: 0.3rem 0.75rem;
      font-size: 0.85rem; color: var(--soft); background: var(--panel); cursor: pointer; }
    #find .kind:has(input:checked) { color: var(--kc); border-color: var(--kc);
      background: color-mix(in srgb, var(--kc) 10%, var(--panel)); }   /* 10 %, not 14: the ticked
      chip is kind-color text on a kind-tinted panel, and the measured pair (dark audio #c58af9 on
      its own tint) is 4.54:1 at 10 % — under 4.5 (AA) at 14 %. Others measure 5.4 and up. */
    #find .kind[data-kind="screenshot"], #find .kind[data-kind="image"] { --kc: var(--kind-image); }
    #find .kind[data-kind="video"] { --kc: var(--kind-video); }
    #find .kind[data-kind="audio"] { --kc: var(--kind-audio); }
    #find .kind[data-kind="pdf"], #find .kind[data-kind="doc"] { --kc: var(--kind-doc); }
    #kinds-all { padding: 0.1rem 0.6rem; font-size: 0.78rem; border-radius: var(--radius-pill); }
    /* the all button is a TOGGLE (round-7 brief): pressed state while all six are on */
    #kinds-all[aria-pressed="true"] { color: var(--accent); border-color: var(--accent); }
    @media (max-width: 720px) {
      #searchbox { grid-template-columns: 1fr; }
      #q, #search-side { grid-column: 1; }
      #q { width: 100%; }
      #search-side { justify-content: center; position: static; }
    }
  `];

  constructor() {
    super();
    this._code = false;
    this._limit = 40;
    this._kinds = new Set(KINDS.map(([k]) => k));   // all ticked = null = all kinds
    this._text = "";
  }

  #emit() {
    this.dispatchEvent(new CustomEvent("digup:query-change", {
      bubbles: true, composed: true,
      detail: { text: this._text, code: this._code,
                kinds: KINDS.filter(([k]) => this._kinds.has(k)).map(([k]) => k),
                limit: this._limit },
    }));
  }

  /** Suggestion chips take the ONE search route: put the phrase in the field and
   *  run it as a typed query does (the vanilla chip click, verbatim). */
  setValue(phrase) {
    this._text = phrase;
    const input = this.renderRoot.getElementById("q");
    input.value = phrase;
    input.focus();
    this.#emit();
  }

  clearAndRefocus() {                              // Esc clears the query (vanilla parity)
    this._text = "";
    this.renderRoot.getElementById("q").value = "";
    this.renderRoot.getElementById("q").focus();
    this.#emit();
  }

  focusQuery() { this.renderRoot.getElementById("q")?.focus(); }

  updated(changed) {
    if (changed.has("isCode")) this._code = this.isCode;   // prefix and box are one state
  }

  render() {
    return html`
      <section id="searchbox">
        <input id="q" type="search" autocomplete="off" autocorrect="off" spellcheck="false" autofocus
               maxlength="512" .value=${this._text}
               placeholder="Describe it: “wakeboarding at sunset”, “payment error screenshot” — “code: …” searches code"
               @input=${(e) => { this._text = e.target.value; this.#emit(); }}
               @keydown=${this.#fieldKey}>
        <div id="search-side">
          <select id="limit" title="How many hits to ask for" .value=${String(this._limit)}
                  @change=${(e) => { this._limit = Number(e.target.value); this.#emit(); }}>
            <option value="10">10</option>
            <option value="20">20</option>
            <option value="40" selected>40</option>
            <option value="100">100</option>
          </select>
          <label id="code-label" title="Search code by what it does (the “code:” prefix does the same)">
            <input id="code" type="checkbox" .checked=${this._code}
                   @change=${(e) => { this._code = e.target.checked; this.#emit(); }}> code
          </label>
        </div>
      </section>

      <div id="find" role="group" aria-label="Find by kind">
        ${KINDS.map(([kind, label]) => html`
          <label class="kind" data-kind=${kind}>
            <input type="checkbox" data-kind=${kind} .checked=${this._kinds.has(kind)}
                   @change=${(e) => { e.target.checked ? this._kinds.add(kind) : this._kinds.delete(kind);
                                      this._kinds = new Set(this._kinds); this.#emit(); }}> ${label}</label>`)}
        <button id="kinds-all" type="button" aria-pressed=${String(this._kinds.size === KINDS.length)}
                title=${this._kinds.size === KINDS.length
                  ? "All kinds on — click to clear them all" : "Turn all kinds on"}
                @click=${() => { this._kinds = this._kinds.size === KINDS.length
                  ? new Set() : new Set(KINDS.map(([k]) => k)); this.#emit(); }}>all</button>
      </div>`;
  }

  #fieldKey = (event) => {
    // In the field: ↑↓ pick results, ↩ opens the pick, Space types a space (as the desktop
    // panel: Space previews only after you've navigated, and only with a selection).
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      this.dispatchEvent(new CustomEvent("digup:nav", { bubbles: true, composed: true,
        detail: { step: event.key === "ArrowDown" ? 1 : -1 } }));
    } else if (event.key === "Enter") {
      event.preventDefault();
      this.dispatchEvent(new CustomEvent("digup:activate", { bubbles: true, composed: true }));
    } else if (event.key === " " && this.navigated && this.hasSelection) {
      event.preventDefault();
      this.dispatchEvent(new CustomEvent("digup:preview", { bubbles: true, composed: true }));
    }
  };
}
if (!customElements.get("digup-search")) customElements.define("digup-search", DigupSearch);
