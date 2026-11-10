// digup-big — the big look (Space, as Quick Look; Esc puts it away): the selection
// over all of it, its video or sound stops with it (the vanilla closeBig cleared the
// box — Lit clears by not rendering, which unmounts the media too). The overlay's
// [hidden]-guard lesson rides in :host([hidden]) (display outranks the UA rule —
// the Stage-10 bug). Clicking the backdrop closes (the vanilla target===big rule);
// clicks inside the panel do not.
import { LitElement, html, css } from "lit";
import { baseName, folderOf } from "../lib/format.js";
import { pictureTemplate } from "../lib/media.js";

class DigupBig extends LitElement {
  static properties = { hit: {} };

  static styles = css`
    :host([hidden]) { display: none; }
    :host { position: fixed; inset: 0; background: color-mix(in srgb, #000 78%, transparent);
      display: flex; align-items: center; justify-content: center; z-index: var(--z-big); }
    .big-panel { background: var(--panel); border: 1px solid var(--edge); border-radius: 12px;
      max-width: min(1100px, 92vw); max-height: 90vh; overflow: auto; padding: 0.8rem; }
    .head { display: flex; align-items: baseline; gap: 0.6rem; margin-bottom: 0.5rem; }
    .head .name { font-weight: 600; }
    .head .place { color: var(--soft); font-size: 0.85rem; flex: 1; overflow-wrap: anywhere; }
    .view img, .view video { display: block; max-width: 100%; max-height: 74vh; object-fit: contain;
      border-radius: 8px; background: #000; }
    .view audio { width: 100%; }
    .view .passage { font: 0.9rem/1.55 var(--font-mono);
      white-space: pre-wrap; overflow-wrap: anywhere; max-height: 70vh; overflow: auto; }
    .close { padding: 0.1rem 0.6rem; font-size: 0.8rem; }
  `;

  constructor() {
    super();
    this._broken = new Set();
  }

  #broken = (hit) => this._broken.has(hit.media_id);
  #markBroken = (id) => { this._broken = new Set([...this._broken, id]); };

  render() {
    const hit = this.hit;
    if (!hit) return html``;
    return html`
      <div class="overlay" @click=${(e) => { if (e.target.classList.contains("overlay")) this.#close(); }}>
        <div class="big-panel">
          <div class="head">
            <span class="name">${baseName(hit.path)}</span>
            <span class="place">${folderOf(hit.path)}</span>
            <button class="close" type="button" @click=${this.#close}>Esc</button>
          </div>
          <div class="view">${pictureTemplate(hit, { broken: this.#broken, markBroken: this.#markBroken })}</div>
        </div>
      </div>`;
  }

  #close = () => this.dispatchEvent(new CustomEvent("digup:close",
    { bubbles: true, composed: true }));
}
if (!customElements.get("digup-big")) customElements.define("digup-big", DigupBig);
