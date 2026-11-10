// digup-results — the hits: strong results grouped by kind, the rest folded
// ("N weaker matches"), the engine's counter line (engine-says), the roving-tabindex
// listbox. Selection state arrives from the store (the controller owns it); rows talk
// back with digup:select / digup:open / digup:toggle-weaker. Thumbnails are the
// engine's small renders (72 px, lazy — rows must not turn every search into a tab
// storm), and a preview render that 404s becomes the kind icon (the vanilla onerror
// swap). File names and excerpts are text nodes via Lit templates — escaped by the
// DOM, never HTML.
import { LitElement, html, css } from "lit";
import { baseName, folderOf, clock, KIND_TITLE, WEAKER } from "../lib/format.js";
import { badgeCss } from "../styles/controls.js";

const KIND_ICON = {screenshot: "▣", image: "▣", pdf: "❐", doc: "≡", video: "▶",
                   audio: "♪", code: "</>"};

class DigupResults extends LitElement {
  static properties = { results: {}, _broken: { state: true } };

  static styles = [badgeCss, css`
    /* The hits list (the vanilla style.css rules, carried over verbatim — they live here
       now because the list renders in this shadow). Rows are separated by a top border,
     the group titles are the small uppercase labels, the thumbnail is a fixed square,
     and the selected row carries the accent wash. */
    ul#hits { list-style: none; padding: 0; margin: 0; }
    ul#hits > li.group-title { color: var(--soft); font-size: 0.75rem; text-transform: uppercase;
      letter-spacing: 0.04em; padding: 0.5rem 0.1rem 0.15rem; }
    ul#hits > li.row {
      display: flex; gap: 0.6rem; border-top: 1px solid var(--line); padding: 0.5rem 0.4rem;
      border-radius: 8px; cursor: pointer;
    }
    ul#hits > li.row.selected { background: color-mix(in srgb, var(--accent) 14%, var(--bg)); }
    ul#hits > li.row:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
    img.thumb { width: 2.4rem; height: 2.4rem; object-fit: cover; border: 1px solid var(--line);
      border-radius: 6px; flex: none; margin-top: 0.15rem; }
    .row-text { min-width: 0; }
    .row-title { display: flex; align-items: baseline; gap: 0.35rem; flex-wrap: wrap; }
    .row-title .name { font-weight: 550; overflow-wrap: anywhere; }
    .row-sub { color: var(--soft); font-size: 0.82rem; overflow-wrap: anywhere; }
    .row-sub mark { background: color-mix(in srgb, var(--accent) 25%, var(--bg)); color: inherit;
      border-radius: 3px; padding: 0 0.1rem; }
    li.weaker { padding: 0.5rem 0.4rem; color: var(--soft); font-size: 0.85rem; cursor: pointer;
      border-top: 1px solid var(--line); }
    li.weaker .chevron { margin-right: 0.35rem; }
    li.weaker.selected { color: var(--text); }
    .engine-says { color: var(--soft); font-size: 0.82rem; margin: 0.2rem 0 0.4rem; }
    .engine-says .warn { color: var(--warn); }
  `];

  constructor() {
    super();
    this.results = { groups: [], weaker: [], showWeaker: false, selection: null,
                     lastReply: null, hitsById: new Map() };
    this._broken = new Set();
  }

  #toggleWeaker = () => this.dispatchEvent(new CustomEvent("digup:toggle-weaker",
    { bubbles: true, composed: true }));

  #rowIDs() {
    const r = this.results;
    return [
      ...r.groups.flatMap((g) => g.rows.map((hit) => hit.media_id)),
      ...(r.weaker.length ? [WEAKER] : []),
      ...(r.showWeaker ? r.weaker.map((hit) => hit.media_id) : []),
    ];
  }

  updated() {
    // Keep the selection in view (vanilla scrollIntoView; jsdom has none — guard it).
    this.renderRoot.querySelector(".selected")
      ?.scrollIntoView?.({ block: "nearest" });
  }

  render() {
    const r = this.results;
    const reply = r.lastReply || {hits: [], strong: 0, meaning: true, ms: {}};
    const ms = reply.ms || {};
    return html`
      <p id="engine-says" class="engine-says">
        <span>${reply.hits.length} hits · ${reply.strong} strong</span>
        ${ms.embed !== undefined ? html`<span> · embed ${(ms.embed / 1000).toFixed(2)} s</span>` : null}
        ${ms.search !== undefined ? html`<span> · search ${(ms.search / 1000).toFixed(2)} s</span>` : null}
        ${reply.warning ? html`<span> · </span><span class="warn">${reply.warning}</span>` : null}
        ${!reply.hits.length && r.phase !== "empty" && r.phase !== "codeHint"
          ? html`<span> — </span><em>${this.#emptyAnswer(reply)}</em>` : null}
      </p>
      <ul id="hits" role="listbox" aria-label="Results">
        ${r.groups.map((group) => html`
          <li class="group-title" .role=${"presentation"}>${group.title}</li>
          ${group.rows.map((hit) => this.#row(hit))}`)}
        ${r.weaker.length ? html`
          <li class="weaker ${r.showWeaker ? "open" : ""} ${r.selection === WEAKER ? "selected" : ""}"
              role="option" aria-expanded=${String(r.showWeaker)}
              aria-selected=${String(r.selection === WEAKER)}
              tabindex=${r.selection === WEAKER ? 0 : -1}
              @click=${this.#toggleWeaker}
              @keydown=${(e) => { if (e.key === "Enter") this.#toggleWeaker(); }}>
            <span class="chevron">${r.showWeaker ? "▾" : "▸"}</span>
            <span>${r.showWeaker ? "Weaker matches"
              : `${r.weaker.length} weaker ${r.weaker.length === 1 ? "match" : "matches"}`}</span>
          </li>
          ${r.showWeaker ? r.weaker.map((hit) => this.#row(hit)) : null}` : null}
      </ul>`;
  }

  #emptyAnswer(reply) {
    return reply.meaning
      ? "the engine found no good matches for this and refused to guess — that is its answer"
      : "no keyword hits (meaning search is warming up)";
  }

  #row(hit) {
    const selected = this.results.selection === hit.media_id;
    return html`
      <li class="row ${selected ? "selected" : ""}" role="option"
          aria-selected=${selected ? "true" : "false"}
          tabindex=${selected ? 0 : -1}
          @click=${() => this.dispatchEvent(new CustomEvent("digup:select",
            { bubbles: true, composed: true, detail: { mediaId: hit.media_id } }))}
          @dblclick=${() => this.dispatchEvent(new CustomEvent("digup:open",
            { bubbles: true, composed: true, detail: { mediaId: hit.media_id } }))}
          @keydown=${(e) => {
            if (e.key === "Enter") { e.preventDefault();
              this.dispatchEvent(new CustomEvent("digup:open",
                { bubbles: true, composed: true, detail: { mediaId: hit.media_id } })); } }}>
        ${this.#thumbnail(hit)}
        <div class="row-text">
          <div class="row-title">
            <span class="name">${baseName(hit.path)}</span>
            <span class="badge kind-${hit.kind}">${hit.kind}</span>
            ${hit.loc !== undefined && hit.loc !== null
              ? html`<span class="badge">at ${clock(hit.loc)}</span>` : null}
            ${hit.z !== undefined ? html`<span class="badge">z ${hit.z.toFixed(1)}</span>` : null}
          </div>
          <div class="row-sub">
            ${hit.excerpt && hit.excerpt.includes("«")
              ? this.#excerptSpans(hit.excerpt)          // words found
              : folderOf(hit.path)}
          </div>
        </div>
      </li>`;
  }

  // The words the keyword search matched, marked with «» by the engine: rendered as
  // spans (text nodes), never as HTML.
  #excerptSpans(excerpt) {
    return html`<span class="excerpt">
      ${excerpt.split(/(«[^»]*»)/).filter(Boolean).map((piece) => piece.startsWith("«")
        ? html`<mark>${piece.slice(1, -1)}</mark>`
        : html`<span>${piece}</span>`)}</span>`;
  }

  // Row thumbnails: the small picture the engine renders (72 px), lazy so only the visible
  // rows cost a decode. Videos show their frame in the preview pane, at the moment — a
  // frame extraction per row for a whole list is a cost the desktop pays too, and the
  // server's engine is the same engine: honest to keep the list light.
  #thumbnail(hit) {
    const icon = html`<span class="badge kind-${hit.kind} kind-icon">${KIND_ICON[hit.kind] || "•"}</span>`;
    if (!["image", "screenshot", "pdf"].includes(hit.kind)) return icon;
    if (this._broken.has(hit.media_id)) return icon;
    return html`<img class="thumb" alt="" loading="lazy"
      src=${`/api/v1/media/${hit.media_id}/preview?pixels=${Math.round(64 * (window.devicePixelRatio || 1))}`}
      @error=${() => { this._broken = new Set([...this._broken, hit.media_id]); }}>`;
  }
}
if (!customElements.get("digup-results")) customElements.define("digup-results", DigupResults);
