// digup-preview — the preview pane: what the desktop shows for the selection (panel.js
// `picture`), via the shared media templates (lib/media.js). The pane is laid out only
// in the `results` state (digup-app gates the section on data-page), so the "no hits
// yet" messages live in the centered idle/busy/none panels — this component draws the
// selection, and nothing else. The WEAKER sentinel row gets the fold message (↩ shows
// or folds them), as the vanilla pane had it.
import { LitElement, html, css } from "lit";
import { WEAKER } from "../lib/format.js";
import { pictureTemplate, factsTemplate } from "../lib/media.js";
import { controlCss } from "../styles/controls.js";

class DigupPreview extends LitElement {
  static properties = { hit: {}, weakerCount: {}, showWeaker: {} };

  // controlCss: Open / Download are `a.button-like` (lib/media.js) — the shared button
  // primitive, so they render as BUTTONS, not as underlined links (2026-11-08 UI brief).
  static styles = [controlCss, css`
    :host { display: block; }
    .message { display: flex; flex-direction: column; gap: 0.35rem; color: var(--soft);
      padding: 2rem 0.5rem; text-align: center; }
    .message strong { color: var(--text); }
    .picture img, .picture video { display: block; width: 100%; max-height: 60vh;
      object-fit: contain; border-radius: 8px; background: #000; }
    /* audio hits live in an audio-picture box (the pane gives it that class) —
       the old picture selector never matched them, so the control rendered at its ~300 px
       default in the pane. */
    .picture audio, .audio-picture audio { width: 100%; margin-top: 0.5rem; }
    .moment { color: var(--soft); font-size: 0.85rem; margin-top: 0.25rem; }
    .passage, .passage code { font: 0.85rem/1.5 var(--font-mono);
      white-space: pre-wrap; overflow-wrap: anywhere; max-height: 46vh; overflow: auto;
      border: 1px solid var(--edge); border-radius: 8px; padding: 0.6rem 0.8rem; background: var(--bg); }
    pre.excerpt { margin: 0.5rem 0 0; padding: 0.6rem 0.8rem; max-height: 20rem; overflow: auto;
      border: 1px solid var(--edge); border-radius: 8px; font: 0.85rem/1.4 var(--font-mono);
      white-space: pre-wrap; overflow-wrap: anywhere; background: var(--bg); }
    .audio-picture pre.excerpt { margin-top: 0.5rem; }
    .facts .title { font-weight: 600; overflow-wrap: anywhere; }
    .facts .line { color: var(--soft); font-size: 0.85rem; overflow-wrap: anywhere; }
    .facts .reason { margin-top: 0.45rem; font-size: 0.88rem; }
    .facts .buttons { display: flex; gap: 0.5rem; margin-top: 0.6rem; }
    .note { color: var(--soft); font-size: 0.82rem; margin-top: 0.4rem; }
  `];

  constructor() {
    super();
    this._broken = new Set();
    this.hit = null;
  }

  #broken = (hit) => this._broken.has(hit.media_id);
  #markBroken = (id) => { this._broken = new Set([...this._broken, id]); };

  updated(changed) { if (changed.has("hit")) this._broken = new Set(); }

  render() {
    const hit = this.hit;
    if (hit === WEAKER) {
      const count = this.weakerCount ?? 0;
      return html`<div class="message">
        <strong>${this.showWeaker ? "Weaker matches"
          : `${count} weaker ${count === 1 ? "match" : "matches"}`}</strong>
        <span>They match much less well than the results above. Press ↩ to
             ${this.showWeaker ? "fold them away." : "show them."}</span></div>`;
    }
    if (!hit) return html``;            // defensive: no reply backs this selection
    return html`${pictureTemplate(hit, { broken: this.#broken, markBroken: this.#markBroken })}
      ${factsTemplate(hit)}`;
  }
}
if (!customElements.get("digup-preview")) customElements.define("digup-preview", DigupPreview);
