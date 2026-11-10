// media.js — the picture/facts/passage templates the preview pane and the big look
// SHARE (the desktop shows the selection the way panel.js shows it; the server shows
// it the same way, in one place). The vanilla app.js picture()/facts()/textPassage()
// rules carried over verbatim, the honest fallbacks included: a preview the engine has
// not rendered is a message plus the file's metadata, never an empty pane.
import { html, LitElement } from "lit";
import { baseName, folderOf, extension, bytes, clock, date, STREAMABLE_VIDEO,
         STREAMABLE_AUDIO, reasonOf } from "../lib/format.js";

const mediaUrls = (hit) => ({
  fileURL: `/api/v1/media/${hit.media_id}/file`,
  previewURL: (pixels) => `/api/v1/media/${hit.media_id}/preview?pixels=${pixels}`,
});

// A preview that is not there (the engine's render has no JPEG for this segment, the index
// moved, the file left the folders): say so plainly, and keep the file's own metadata and
// its Open/Download — `facts` is a sibling of the picture, so the pane is never blank.
const noPreview = (hit) => html`<div class="message">
  <strong>No preview of this file</strong>
  <span>The engine has no rendered image for this ${hit.kind} segment. Its details, Open
       and Download are below.</span></div>`;

const cantStream = (suffix) => html`<p class="note">This browser can't stream .${suffix}
  — ↩ Open plays it in your own player.</p>`;

/** The picture block for a hit. `broken(hit)` reads this render's error state,
 *  `markBroken(hit)` records an element error (preview render gone, index moved). */
export function pictureTemplate(hit, { broken, markBroken }) {
  const suffix = extension(hit.path);
  const { fileURL, previewURL } = mediaUrls(hit);
  const onerror = () => markBroken(hit.media_id);
  switch (hit.kind) {
    case "image":
    case "screenshot": {
      if (broken(hit)) return noPreview(hit);
      return html`<div class="picture">
        <img alt="" src=${previewURL(1024)} @error=${onerror}></div>`;
    }
    case "pdf": {
      const moment = html`<div class="moment"><span class="at">${hit.loc
        ? `page ${Math.round(hit.loc)}` : "first page"}</span></div>`;
      if (broken(hit)) return html`${noPreview(hit)}${moment}`;
      return html`<div class="picture">
        <img alt="" src=${previewURL(1024)} @error=${onerror}>${moment}</div>`;   // the page the hit was found on
    }
    case "video": {
      const at = hit.loc ?? 0;
      const moment = html`<div class="moment"><span class="at">▶ at ${clock(at)}</span></div>`;
      if (STREAMABLE_VIDEO.has(suffix)) {
        return html`<div class="picture">
          <video controls preload="metadata" poster=${previewURL(1024)}
                 src=${`${fileURL}#t=${at}`} @error=${onerror}></video>${moment}</div>`;
      }
      if (broken(hit)) return html`${noPreview(hit)}${moment}${cantStream(suffix)}`;
      return html`<div class="picture">
        <img alt="" src=${previewURL(1024)} @error=${onerror}>${moment}${cantStream(suffix)}</div>`;
    }
    case "audio": {
      return html`<div class="audio-picture">
        ${STREAMABLE_AUDIO.has(suffix)
          ? html`<audio controls preload="metadata" src=${`${fileURL}#t=${hit.loc ?? 0}`}
                         @error=${() => markBroken(`audio:${hit.media_id}`)}></audio>`
          : cantStream(suffix)}
        <digup-passage .hit=${hit}></digup-passage></div>`;
    }
    default: {
      return html`<div class="passage${hit.kind === "code" ? " code" : ""}">
        <digup-passage .hit=${hit} .excerptFallback=${(hit.excerpt ?? "").replace(/[«»]/g, "")
          || baseName(hit.path)}></digup-passage></div>`;
    }
  }
}

export function factsTemplate(hit) {
  const details = [hit.kind,
    hit.size ? bytes(hit.size) : null,
    hit.modified ? date(hit.modified) : null,
    hit.z !== undefined ? `z ${hit.z.toFixed(2)}` : null,
    hit.cosine !== undefined ? `cosine ${hit.cosine.toFixed(3)}` : null,
    hit.keyword_rank !== undefined && hit.keyword_rank !== null ? `keyword #${hit.keyword_rank}` : null,
    hit.segment !== undefined ? `segment ${hit.segment}` : null].filter(Boolean);
  const { fileURL } = mediaUrls(hit);
  return html`<div class="facts">
    <div class="title">${baseName(hit.path)}</div>
    <div class="line">${folderOf(hit.path)}</div>
    <div class="line">${details.join(" · ")}</div>
    <div class="reason"><span>${reasonOf(hit)}</span></div>
    <div class="buttons">
      <!-- server-issued handle, inline media: "Open" is the desktop's Open, over HTTP -->
      <a class="button-like" href=${fileURL} target="_blank" rel="noopener">Open</a>
      <a class="button-like" href=${fileURL} download=${baseName(hit.path)}>Download</a>
    </div>
  </div>`;
}

// Transcripts and text (the desktop pulls the passage that matched; same op /text).
// The fetch is token-guarded: a fast selection change must not land an old segment's
// text in the new passage (the vanilla per-render element made this safe; a token makes
// the shared component safe the same way). The call goes through the app's api client
// (the bearer shape stays in services/api.js — main.js calls setPassageApi once).
let _api = null;
export function setPassageApi(apiFn) { _api = apiFn; }

class DigupPassage extends LitElement {
  static properties = { hit: {}, excerptFallback: {}, _text: { state: true } };

  constructor() {
    super();
    this._token = 0;
    this._text = null;
  }

  updated(changed) {
    if (!changed.has("hit")) return;
    const token = ++this._token;
    this._text = null;
    if (!this.hit || !this.hit.media_id) return;
    this._text = "reading…";
    const call = _api ?? ((path) => fetch(path, { headers: { "content-type": "application/json" } })
      .then((reply) => reply.ok ? reply.json() : Promise.reject(new Error(`HTTP ${reply.status}`))));
    call(`/api/v1/media/${this.hit.media_id}/text`)
      .then((reply) => {
        if (token !== this._token || !this.shadowRoot) return;
        this._text = (reply.text || "").slice(0, 4000) || "no text for this segment";
      })
      .catch((error) => {
        if (token !== this._token || !this.shadowRoot) return;
        this._text = `text unavailable: ${error.message}`;
      });
  }

  render() {
    if (this.hit && this._text === null) {           // doc/code passage: excerpt rides first
      return html`<pre class="excerpt">${this.excerptFallback || ""}</pre>`;
    }
    return html`<pre class="excerpt">${this._text ?? (this.excerptFallback || "")}</pre>`;
  }
}
if (!customElements.get("digup-passage")) customElements.define("digup-passage", DigupPassage);
