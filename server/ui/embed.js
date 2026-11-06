// DigUp embed widget — the script behind embed.html (docs/implementation/
// stage-12-integrations.md §11.4). Dependency-free, same-origin, same rules as app.js
// (README §10.4): the engine's fields relayed verbatim (hits, z, strong, ms, meaning),
// keyword-first typing (words at once, meaning after the pause, embed_ahead warming the
// vector), previews only for tiles on screen. The read-scope token is the host's secret:
// it enters through ?token=, moves to sessionStorage, and the URL line is rewritten so
// the secret never lands in bookmarks, history, or the host app's logs.
"use strict";

const $ = (id) => document.getElementById(id);
const PAUSE = 160;                    // ms after the last keystroke until meaning results
const TOKEN_KEY = "digupEmbedToken";
const params = new URLSearchParams(location.search);

let token = params.get("token") || sessionStorage.getItem(TOKEN_KEY) || "";
let prompted = false;
if (params.get("token")) {
  sessionStorage.setItem(TOKEN_KEY, token);
  params.delete("token");             // strip the secret from the visible URL line
  const q = params.toString();
  history.replaceState(null, "", location.pathname + (q ? "?" + q : ""));
}
if (params.get("limit")) $("limit").value = params.get("limit");

// ── theme: system by default; the host app (Nextcloud / Immich) drives it by postMessage ──
function setTheme(value) {
  if (value === "light" || value === "dark") document.documentElement.dataset.theme = value;
}
if (params.get("theme")) setTheme(params.get("theme"));
window.addEventListener("message", (event) => {
  const data = event.data;
  if (data && data.source === "digup-host" && data.theme) setTheme(data.theme);
});
window.parent.postMessage({ source: "digup-embed", event: "ready" }, "*");

// ── the API, with the widget's bearer token ──────────────────────────────────────────────
async function api(path, options = {}) {
  const headers = { "content-type": "application/json", ...(options.headers || {}) };
  if (token) headers.authorization = "Bearer " + token;
  const answer = await fetch(path, { ...options, headers });
  if (answer.status === 401) {
    if (token && !prompted) {        // the stored token is stale: clear it and ask once
      prompted = true;
      sessionStorage.removeItem(TOKEN_KEY);
      const asked = window.prompt("This DigUp server asks for its read token:");
      token = (asked || "").trim();
      if (token) sessionStorage.setItem(TOKEN_KEY, token);
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

// ── typing: words at once, meaning after the pause, embed_ahead warming the vector ───────
let timer = null, gen = 0, meaningGen = 0, lastReply = null;

function searchBody(meaning) {
  return { q: $("q").value, meaning, limit: Number($("limit").value) };
}

function runSearch(meaning, myGen) {
  api("/api/v1/search", { method: "POST", body: JSON.stringify(searchBody(meaning)) })
    .then((reply) => {
      if (meaning) meaningGen = myGen;
      if (myGen < meaningGen) return;   // a late keyword reply must not replace meaning
      lastReply = reply;
      render(reply, meaning);
    })
    .catch((error) => { $("statusline").textContent = error.message; });
}

$("q").addEventListener("input", () => {
  const text = $("q").value.trim();
  if (!text) { $("results").replaceChildren(); $("statusline").textContent = "say what you'd see, hear, or read — the meaning, not only the words"; return; }
  $("activity").hidden = false;
  api("/api/v1/embed_ahead", { method: "POST", body: JSON.stringify({ q: text }) }).catch(() => {});
  const myGen = ++gen;
  runSearch(false, myGen);             // words right away: the keyword path
  clearTimeout(timer);
  timer = setTimeout(() => runSearch(true, ++gen), PAUSE + 320);
});

$("limit").addEventListener("change", () => $("q").dispatchEvent(new Event("input")));
document.querySelectorAll(".chip[data-kind]").forEach((chip) =>
  chip.addEventListener("click", () => {
    document.querySelectorAll(".chip[data-kind]").forEach((c) => c.classList.toggle("on", c === chip));
    if (lastReply) render(lastReply, lastReply.meaning);
  }));
$("strong").addEventListener("change", () => { if (lastReply) render(lastReply, lastReply.meaning); });

// ── rendering: the engine's numbers, the host's previews ─────────────────────────────────
const KIND_LABEL = { image: "photo", screenshot: "screenshot", video: "video", audio: "audio",
                     pdf: "pdf", doc: "document", code: "code" };
const PREVIEWABLE = new Set(["image", "screenshot", "video"]);
const observer = new IntersectionObserver((seen) => {
  for (const entry of seen) {
    if (!entry.isIntersecting) continue;
    observer.unobserve(entry.target);
    loadPreview(entry.target);
  }
}, { rootMargin: "300px" });

async function loadPreview(tile) {
  const id = tile.dataset.media;
  if (!PREVIEWABLE.has(tile.dataset.kind) || !id) return;
  try {
    const answer = await blobOf(`/api/v1/media/${id}/preview?pixels=256`);
    const img = document.createElement("img");
    img.alt = "";
    img.src = URL.createObjectURL(await answer.blob());
    tile.prepend(img);
  } catch { /* the tile keeps the kind label: previews are a grace, not a promise */ }
}

function render(reply, meaning) {
  $("activity").hidden = true;
  const kinds = (document.querySelector(".chip.on[data-kind]") || {}).dataset?.kind || "";
  const wanted = kinds ? kinds.split(",") : null;
  const strongN = Math.min(reply.strong ?? reply.hits.length, reply.hits.length);
  let hits = reply.hits.map((hit, at) => ({ hit, strong: at < strongN }));
  if (wanted) hits = hits.filter((h) => wanted.includes(h.hit.kind));
  if ($("strong").checked) hits = hits.filter((h) => h.strong);

  const tiles = hits.map(({ hit, strong }) => {
    const tile = document.createElement("li");
    tile.className = "tile" + (strong ? " strong" : "");
    tile.dataset.media = hit.media_id || "";
    tile.dataset.kind = hit.kind;
    const label = document.createElement("span");
    label.className = "kind";
    label.textContent = KIND_LABEL[hit.kind] || hit.kind;
    tile.append(label);
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = hit.path.split("/").pop();
    name.title = hit.path;
    const z = document.createElement("span");
    z.className = "z";
    z.textContent = hit.z !== undefined ? "z " + hit.z.toFixed(2) : "";
    tile.append(name, z);
    if (hit.loc !== undefined && hit.loc !== null) {
      const at = document.createElement("span");
      at.className = "loc";
      at.textContent = "at " + Math.round(hit.loc) + "s";
      tile.append(at);
    }
    tile.addEventListener("click", () => openHit(hit));
    if (PREVIEWABLE.has(hit.kind) && hit.media_id) observer.observe(tile);
    return tile;
  });
  $("results").replaceChildren(...tiles);

  const ms = reply.ms || {};
  const bits = [`${reply.hits.length} hits · ${strongN} strong`];
  if (meaning && reply.meaning) bits.push(`embed ${ms.embed ?? 0} ms · search ${ms.search ?? 0} ms`);
  if (!reply.meaning) bits.push("words only — pause typing for meaning");
  if (reply.warning) bits.push(reply.warning);
  $("statusline").textContent = bits.join(" · ");
}

async function openHit(hit) {
  if (!hit.media_id) return;
  try {
    const answer = await blobOf(`/api/v1/media/${hit.media_id}/file`);
    const url = URL.createObjectURL(await answer.blob());
    window.open(url, "_blank");
    setTimeout(() => URL.revokeObjectURL(url), 10 * 60 * 1000);
  } catch (error) { $("statusline").textContent = error.message; }
}

// ── start: health (open, no token needed), then the host's ?q= if any ───────────────────
api("/api/v1/health").then((body) => {
  const live = body.live || {};
  $("statusline").textContent = `ready · ${live.searchable ?? "?"} searchable files`;
  if (params.get("q")) { $("q").value = params.get("q"); $("q").dispatchEvent(new Event("input")); }
}).catch((error) => { $("statusline").textContent = error.message; });
