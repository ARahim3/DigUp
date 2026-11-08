// The DigUp server UI: fetch() to /api/v1, nothing else. No frameworks, no build step,
// no bundler — same paradigm as the desktop shell's `shell/ui`, and the same behavior:
// keyword-first typing (words at once with the last word as a prefix, meaning after the
// 120 ms pause, the query embedded while you type), strong/weaker grouping, kind filters,
// code mode, selection with the arrow keys, a preview pane, Space for the big look,
// opening files (video plays from its moment). The page is a centered search box, its
// kind chips, results bottom-left, preview right; the server's own controls (appearance,
// Index now, prune, Estimate, the engine's counts) live in the settings panel (the gear).
// Every number shown is the engine's (counts, seconds, scores, timestamps); the only
// server-added field is the `media_id` handle. DOM is built with createElement +
// text nodes, so file names and excerpts are escaped by the DOM, never as HTML.

const TYPING_PAUSE = 120;              // ms after the last keystroke until meaning results
const $ = (id) => document.getElementById(id);

const api = async (path, options = {}, retried = false) => {
  // Bearer token, when this deployment asks for one (DIGUP_SERVER_TOKEN /
  // DIGUP_SERVER_ADMIN_TOKEN, docs/API.md "Authentication"): kept in localStorage, sent on
  // every call. A 401 points at Settings → Access, where the key is typed and saved —
  // no load-time prompt (a blocking prompt in the page is hostile UX: it fires on every
  // new tab, cannot be reopened, and the deployment's real shape is one key pasted once,
  // then the app works; the key lives in localStorage, never in a URL). A 401 with a
  // stored key is the server's own words ("the bearer token is not this server's
  // token"), shown, not re-prompted — a wrong key cannot loop the page.
  const token = localStorage.getItem("digupBearer");
  const headers = {"content-type": "application/json",
                   ...(token ? {authorization: `Bearer ${token}`} : {}),
                   ...(options.headers || {})};
  const reply = await fetch(path, {...options, headers});
  if (reply.status === 401 && !token) {
    $("gear").classList.add("attention");   // the gear is where the key goes
    throw Object.assign(new Error(
      "This server asks for an access key — open Settings → Access and paste it."),
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
};

// `el(tag, class, …kids)`: children are strings (appended as escaped text nodes —
// never HTML) and/or ready-made nodes. The one helper, used everywhere; textContent
// on an element arg used to stringify it as "[object HTMLElement]" — it appends now.
const el = (tag, className, ...kids) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  for (const kid of kids) {
    if (kid === null || kid === undefined) continue;
    node.append(kid instanceof Node ? kid : String(kid));
  }
  return node;
};

const seconds = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
const clock = (s) => (s >= 3600 ? `${Math.floor(s / 3600)}:${String(Math.floor(s / 60 % 60)).padStart(2, "0")}`
                                + `:${String(Math.floor(s % 60)).padStart(2, "0")}` : seconds(s));
const baseName = (path) => path.split("/").pop();
const folderOf = (path) => path.slice(0, path.lastIndexOf("/")) || "/";
const extension = (path) => (path.split(".").pop() || "").toLowerCase();
const bytes = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)} MB` : `${Math.round(n / 1e3)} KB`);
const duration = (s) => (s >= 3600 ? `${Math.round(s / 3600)} h ${Math.round(s / 60 % 60)} min`
                       : s >= 60 ? `${Math.round(s / 60)} min ${Math.round(s % 60)} s` : `${Math.round(s)} s`);
const date = (epoch) => new Date(epoch * 1000).toLocaleDateString(undefined, {year: "numeric", month: "short", day: "numeric"});

// The formats browsers stream themselves (H.264/AAC mp4-mov, VP8/VP9 webm, plain audio).
// Everything else keeps the desktop's honest fallback: the picture and the words here,
// the file itself through "Open", which plays it in the user's own player.
const STREAMABLE_VIDEO = new Set(["mp4", "m4v", "mov", "webm"]);
const STREAMABLE_AUDIO = new Set(["mp3", "wav", "ogg", "oga", "flac", "m4a", "aac"]);

const KIND_TITLE = {screenshot: "Screenshots", image: "Images", pdf: "PDFs", doc: "Documents",
                    video: "Video", audio: "Audio", code: "Code"};
const WEAKER = "\u0000weaker";        // the selectable row that folds the weaker matches

const state = {
  generation: 0,
  finalGeneration: -1,    // whose meaning results are showing: late keyword replies must not replace them
  timer: null,
  phase: "empty",         // empty | words | meaning | wordsOnly | codeHint
  isCode: false,
  text: "",
  strong: [],
  weaker: [],
  groups: [],             // renderList draws this; the first paint needs it to exist
  hits: new Map(),        // media_id → hit, the rows and the preview pane speak through it
  selection: null,
  showWeaker: false,
  navigated: false,       // the arrows/click moved the selection since the last edit
  error: null,
  encoder: "stopped",
  indexing: null,         // the live job's counts, while it runs
};

// ── appearance: system / light / dark, kept in this browser (the desktop follows the OS;
// a server has no OS to follow, so the choice is the user's, per browser) ───────────────

function applyTheme(choice) {
  document.documentElement.dataset.theme = choice;
  localStorage.setItem("digup-theme", choice);
  $("theme").value = choice;
}
$("theme").onchange = (event) => applyTheme(event.target.value);
applyTheme(localStorage.getItem("digup-theme") || "system");

// ── access: the key this browser sends, typed and saved in Settings (2026-11-08 UX ask —
// replaces the load-time prompt). Other applications get their own tokens issued in the
// server's environment; the server never answers with those values, so this field is
// paste-from-the-deployment's-config, stored locally, sent as a bearer header only. ────
$("api-key").value = localStorage.getItem("digupBearer") || "";
$("api-key-save").onclick = () => {
  const v = $("api-key").value.trim();
  if (v) localStorage.setItem("digupBearer", v);
  else localStorage.removeItem("digupBearer");
  location.reload();      // every call re-reads the stored key on a fresh page
};
$("api-key-clear").onclick = () => {
  localStorage.removeItem("digupBearer");
  $("api-key").value = "";
  location.reload();
};

// ── settings: the server's own controls (appearance, index, estimate, the counts) live
// behind the gear, so the page itself stays a search box and its results ──────────────

// All five close paths share one function: the gear's aria-expanded must match the
// panel's hidden state everywhere (a screen reader must not report an open dialog
// whose panel is gone), and focus returns to the gear (closing must not drop the
// keyboard user to <body>).
function closeSettings() {
  const hadFocus = $("settings").contains(document.activeElement);
  $("settings").hidden = true;
  $("gear").setAttribute("aria-expanded", "false");
  if (hadFocus) $("gear").focus();
}

$("gear").onclick = () => {
  const box = $("settings");
  box.hidden = !box.hidden;
  $("gear").setAttribute("aria-expanded", String(!box.hidden));
  $("gear").classList.remove("attention");   // pointing done: the panel is open
  if (!box.hidden) box.querySelector("select, button, input")?.focus();   // keyboard users
};
$("settings-close").onclick = closeSettings;
document.addEventListener("click", (event) => {
  // closest(), not a bare equality: the gear's svg is the click target, not the button.
  if (!$("settings").hidden && !event.target.closest("#gear") && !$("settings").contains(event.target))
    closeSettings();
});

// ── the status: the searchable count by the title; the rest of the engine's numbers
// live in the settings panel, re-read every 15 s ──────────────────────────────────────
async function refreshStatus() {
  const line = $("statusline");
  try {
    const s = await api("/api/v1/status");
    state.encoder = s.encoder;
    line.replaceChildren();
    const parts = [
      `${s.searchable}/${s.files} files searchable`,
      s.pending ? `${s.pending} pending` : null,
    ].filter(Boolean);
    for (const text of parts) line.append(el("span", "badge", text), " ");
    $("statusfull").replaceChildren(...[
      `${s.vectors} vectors`,
      `encoder ${s.encoder}`,
      ...(s.kinds || []).map((k) => `${k.kind} ${k.files}`),
      `index ${s.index_size}`,   // the engine's own human string ("201 KB") — verbatim
      `llama.cpp ${s.build_tag}`,
    ].map((text) => el("span", "badge", text)));
    const roots = $("rootsline");
    roots.replaceChildren(el("span", null, "Looking in: "),
      ...(s.roots || []).flatMap((r, i) => [i ? el("span", null, " · ") : null, el("code", "root", r)])
        .filter(Boolean));
    $("activity").hidden = !(s.encoder === "starting" || state.indexing);
    if ($("activity").hidden === false) {
      $("activity").replaceChildren(el("span", "dot"),
        el("span", null, state.indexing ? "indexing…" : "meaning search warming up…"));
      $("activity").title = "The engine is working: results may miss files it has not read yet";
    }
    if (state.phase !== "empty") renderFooter();
  } catch (error) {
    line.textContent = `status unavailable: ${error.message}`;
  }
}

// ── searching: keyword-first, exactly as the desktop panel types ──────────────────────
function searchBody(text, meaning, prefixLast) {
  const body = {q: text, code: state.isCode, meaning, limit: Number($("limit").value)};
  if (prefixLast) body.prefix_last = true;
  if (!state.isCode) {
    const kinds = [...document.querySelectorAll("#find input[data-kind]")]
      .filter((box) => box.checked).map((box) => box.dataset.kind);
    body.kinds = (kinds.length === 0 || kinds.length === 6) ? null : kinds;   // none ticked = all
  }
  return body;
}

function queryChanged() {
  const typed = $("q").value.trim();
  const prefixCode = /^code:/i.test(typed);
  const code = prefixCode || $("code").checked;
  $("code").checked = code;                    // the prefix and the box are one state
  const text = prefixCode ? typed.slice(5).trim() : typed;
  state.isCode = code;
  state.text = text;
  const generation = ++state.generation;
  clearTimeout(state.timer);
  state.navigated = false;
  state.error = null;
  if (!typed || (code && !text)) { show({hits: [], strong: 0}, code && !text ? "codeHint" : "empty"); return; }
  // Words now. The last word is probably half-typed, so it matches as a prefix.
  api("/api/v1/search", {method: "POST", body: JSON.stringify(searchBody(text, false, true))})
    .then((reply) => { if (generation === state.generation && state.finalGeneration !== generation) show(reply, "words"); })
    .catch((error) => { if (generation === state.generation) failed(error); });
  // The meaning is embedded now, so its vector is ready when typing pauses (embed_ahead).
  api("/api/v1/embed_ahead", {method: "POST", body: JSON.stringify({q: text, code})}).catch(() => {});
  state.timer = setTimeout(() => {
    api("/api/v1/search", {method: "POST", body: JSON.stringify(searchBody(text, true, false))})
      .then((reply) => {
        if (generation !== state.generation) return;
        state.finalGeneration = generation;
        show(reply, reply.meaning ? "meaning" : "wordsOnly");
      })
      .catch((error) => { if (generation === state.generation) failed(error); });
  }, TYPING_PAUSE);
}

function failed(error) {
  state.error = String(error.message || error);
  renderFooter();
}

// ── the hits: strong results grouped by kind, the rest folded ("N weaker matches") ───
function show(reply, phase) {
  const hits = reply.hits || [];
  const strong = Math.min(reply.strong ?? hits.length, hits.length);
  state.phase = phase;
  state.strong = hits.slice(0, strong);
  state.weaker = hits.slice(strong);
  state.hits = new Map(hits.map((hit) => [hit.media_id, hit]));
  const groups = new Map();
  for (const hit of state.strong) {
    const title = KIND_TITLE[hit.kind] || "Files";
    if (!groups.has(title)) groups.set(title, []);
    groups.get(title).push(hit);
  }
  state.groups = [...groups].map(([title, rows]) => ({title, rows}));
  if (!state.navigated) state.showWeaker = false;
  const ids = rowIDs();
  if (!state.navigated || !ids.includes(state.selection)) state.selection = ids[0] ?? null;
  state.lastReply = reply;
  render();
}

const rowIDs = () => [
  ...state.groups.flatMap((group) => group.rows.map((hit) => hit.media_id)),
  ...(state.weaker.length ? [WEAKER] : []),
  ...(state.showWeaker ? state.weaker.map((hit) => hit.media_id) : []),
];

const selectedHit = () => state.hits.get(state.selection) ?? null;

function move(step) {
  const ids = rowIDs();
  if (!ids.length) return;
  const at = ids.indexOf(state.selection);
  state.selection = ids[Math.max(0, Math.min(ids.length - 1, (at < 0 ? -1 : at) + step))];
  state.navigated = true;
  render();
  if (!$("big").hidden) renderBig();
}

function toggleWeaker() {
  state.showWeaker = !state.showWeaker;
  state.selection = WEAKER;
  render();
}

// ── drawing ──────────────────────────────────────────────────────────────────────────
const IDLE_NOTE = "Say what you'd see, hear, or read in a file — the meaning, not only the "
                + "words. Results appear as you type.";
const BUSY_NOTE = "Matching words now — the meaning results follow when you stop typing.";
const CODE_HINT = "Searching your code — say what the code does, or type a name that's in it.";

// The layout's state, read off the state the renderers already use: no second store, no
// second notion of "what page am I on". Hits → the two columns; nothing typed (or the
// code-prefix hint) → the centered welcome; words in, meaning on its way → busy; meaning
// answered zero → none. `body[data-page]` is what style.css lays out the states with.
const pageMode = () => (state.strong.length + state.weaker.length ? "results"
  : (state.phase === "empty" || state.phase === "codeHint") ? "idle"
  : state.phase === "words" ? "busy" : "none");

// The engine's own sentence for an empty answer, verbatim. One string, both places that
// publish it: the counter line (results) and the centered panel (none).
const emptyAnswer = (reply) => (reply.meaning
  ? "the engine found no good matches for this and refused to guess — that is its answer"
  : "no keyword hits (meaning search is warming up)");

function setLayout() {
  const mode = pageMode();
  document.body.dataset.page = mode;
  $("idle-note").textContent = mode === "busy" ? BUSY_NOTE
    : (state.phase === "codeHint" ? CODE_HINT : IDLE_NOTE);
  if (mode === "none" && state.lastReply) {     // the engine's own words, verbatim, in the panel
    const reply = state.lastReply;
    $("no-results-why").textContent = emptyAnswer(reply)
      + (reply.warning ? ` (${reply.warning})` : "");
  }
}

function render() {
  setLayout();
  renderList();
  renderPreview();
  renderFooter();
}

function renderList() {
  const list = $("hits");
  list.replaceChildren();
  for (const group of state.groups) {
    const title = el("li", "group-title", group.title);
    title.setAttribute("role", "presentation");        // a label, not a listbox option
    list.append(title);
    for (const hit of group.rows) list.append(row(hit));
  }
  if (state.weaker.length) {
    const fold = el("li", "weaker" + (state.showWeaker ? " open" : "") + (state.selection === WEAKER ? " selected" : ""));
    fold.setAttribute("role", "option");               // selectable by ↑↓/↩/Space — say so
    fold.setAttribute("aria-expanded", String(state.showWeaker));
    fold.setAttribute("aria-selected", String(state.selection === WEAKER));
    fold.tabIndex = state.selection === WEAKER ? 0 : -1;
    const count = state.weaker.length;
    fold.append(el("span", "chevron", state.showWeaker ? "▾" : "▸"),
      el("span", null, state.showWeaker ? "Weaker matches" : `${count} weaker ${count === 1 ? "match" : "matches"}`));
    fold.onclick = toggleWeaker;
    list.append(fold);
    if (state.showWeaker) for (const hit of state.weaker) list.append(row(hit));
  }
  const says = $("engine-says");
  says.replaceChildren();
  const reply = state.lastReply || {hits: [], strong: 0, meaning: true, ms: {}};
  const ms = reply.ms || {};
  says.append(el("span", null,
    `${reply.hits.length} hits · ${reply.strong} strong`
    + (ms.embed !== undefined ? ` · embed ${(ms.embed / 1000).toFixed(2)} s` : "")
    + (ms.search !== undefined ? ` · search ${(ms.search / 1000).toFixed(2)} s` : "")));
  if (reply.warning) says.append(" · ", el("span", "warn", reply.warning));
  if (!reply.hits.length && state.phase !== "empty" && state.phase !== "codeHint") {
    says.append(" — ", el("em", null, emptyAnswer(reply)));
  }
  list.querySelector(".selected")?.scrollIntoView({block: "nearest"});
}

function row(hit) {
  const selected = state.selection === hit.media_id;
  const item = el("li", "row" + (selected ? " selected" : ""));
  item.setAttribute("role", "option");
  item.setAttribute("aria-selected", selected ? "true" : "false");
  item.tabIndex = selected ? 0 : -1;      // roving tabindex: an arrow-key list with 40–100
  item.append(thumbnail(hit));            // rows must not turn every search into a tab storm
  const text = el("div", "row-text");
  const title = el("div", "row-title");
  title.append(el("span", "name", baseName(hit.path)),
    el("span", `badge kind-${hit.kind}`, hit.kind));
  if (hit.loc !== undefined && hit.loc !== null) title.append(el("span", "badge", `at ${clock(hit.loc)}`));
  if (hit.z !== undefined) title.append(el("span", "badge", `z ${hit.z.toFixed(1)}`));
  const sub = el("div", "row-sub");
  if (hit.excerpt && hit.excerpt.includes("«")) sub.append(excerptSpans(hit.excerpt));  // words found
  else sub.textContent = folderOf(hit.path);
  text.append(title, sub);
  item.append(text);
  item.onclick = () => { state.selection = hit.media_id; state.navigated = true; render(); };
  item.ondblclick = () => openHit(hit);
  item.onkeydown = (event) => { if (event.key === "Enter") { event.preventDefault(); openHit(hit); } };
  return item;
}

// The words the keyword search matched, marked with «» by the engine: rendered as spans
// (textContent), never as HTML.
function excerptSpans(excerpt) {
  const box = el("span", "excerpt");
  for (const piece of excerpt.split(/(«[^»]*»)/)) {
    if (!piece) continue;
    if (piece.startsWith("«")) box.append(el("mark", null, piece.slice(1, -1)));
    else box.append(el("span", null, piece));
  }
  return box;
}

// Row thumbnails: the small picture the engine renders (72 px), lazy so only the visible
// rows cost a decode. Videos show their frame in the preview pane, at the moment — a
// frame extraction per row for a whole list is a cost the desktop pays too, and the
// server's engine is the same engine: honest to keep the list light.
function thumbnail(hit) {
  const icon = el("span", `badge kind-${hit.kind} kind-icon`, {screenshot: "▣", image: "▣", pdf: "❐",
    doc: "≡", video: "▶", audio: "♪", code: "</>"}[hit.kind] || "•");
  if (!["image", "screenshot", "pdf"].includes(hit.kind)) return icon;
  const image = el("img", "thumb");
  image.alt = "";
  image.loading = "lazy";
  image.src = `/api/v1/media/${hit.media_id}/preview?pixels=${Math.round(64 * (window.devicePixelRatio || 1))}`;
  image.onerror = () => image.replaceWith(icon);
  return image;
}

// ── the preview pane: what the desktop shows for the selection (panel.js `picture`) ──
// The pane is laid out only in the `results` state (style.css gates `#results` on
// `body[data-page]`), so the old "no hits yet" messages live in the centered idle/busy/
// none panels now — this function draws the selection, and nothing else.
function renderPreview() {
  const pane = $("preview");
  pane.replaceChildren();
  if (state.selection === WEAKER) {
    const count = state.weaker.length;
    pane.replaceChildren(el("div", "message",
      el("strong", null, state.showWeaker ? "Weaker matches" : `${count} weaker ${count === 1 ? "match" : "matches"}`),
      el("span", null, "They match much less well than the results above. Press ↩ to "
        + (state.showWeaker ? "fold them away." : "show them."))));
    return;
  }
  const hit = selectedHit();
  if (!hit) return;                       // defensive: no reply backs this selection
  pane.append(picture(hit), facts(hit));
}

// A preview that is not there (the engine's render has no JPEG for this segment, the index
// moved, the file left the folders): say so plainly, and keep the file's own metadata and
// its Open/Download — `facts(hit)` is a sibling of the picture, so the pane is never blank.
const noPreview = (hit) => el("div", "message",
  el("strong", null, "No preview of this file"),
  el("span", null, `The engine has no rendered image for this ${hit.kind} segment. Its details, Open and Download are below.`));

function picture(hit) {
  const frame = el("div", "picture");
  const suffix = extension(hit.path);
  const fileURL = `/api/v1/media/${hit.media_id}/file`;
  const previewURL = (pixels) => `/api/v1/media/${hit.media_id}/preview?pixels=${pixels}`;
  switch (hit.kind) {
    case "image":
    case "screenshot": {
      const image = el("img");
      image.alt = "";
      image.src = previewURL(1024);
      image.onerror = () => frame.replaceChildren(noPreview(hit));
      frame.append(image);
      return frame;
    }
    case "pdf": {
      const image = el("img");
      image.alt = "";
      image.src = previewURL(1024);          // the page the hit was found on
      const moment = el("div", "moment", el("span", "at",
        hit.loc ? `page ${Math.round(hit.loc)}` : "first page"));
      image.onerror = () => frame.replaceChildren(noPreview(hit), moment);
      frame.append(image, moment);
      return frame;
    }
    case "video": {
      const at = hit.loc ?? 0;
      const moment = el("div", "moment", el("span", "at", `▶ at ${clock(at)}`));
      if (STREAMABLE_VIDEO.has(suffix)) {
        const video = el("video");
        video.src = `${fileURL}#t=${at}`;    // Range requests on /file make seeking work
        video.controls = true;
        video.poster = previewURL(1024);     // the engine's frame at the moment, first
        video.preload = "metadata";
        video.onerror = () => frame.replaceChildren(noPreview(hit), moment);
        frame.append(video, moment);
      } else {
        const image = el("img");
        image.alt = "";
        image.src = previewURL(1024);
        const note = el("p", "note",
          `This browser can't stream .${suffix} — ↩ Open plays it in your own player.`);
        image.onerror = () => frame.replaceChildren(noPreview(hit), moment, note);
        frame.append(image, moment, note);
      }
      return frame;
    }
    case "audio": {
      const box = el("div", "audio-picture");
      if (STREAMABLE_AUDIO.has(suffix)) {
        const player = el("audio");
        player.src = `${fileURL}#t=${hit.loc ?? 0}`;
        player.controls = true;
        player.preload = "metadata";
        player.onerror = () => player.replaceWith(
          el("p", "note", `This browser can't stream .${suffix} — ↩ Open plays it in your own player.`));
        box.append(player);
      } else {
        box.append(el("p", "note", `This browser can't stream .${suffix} — ↩ Open plays it in your own player.`));
      }
      box.append(textPassage(hit));
      return box;
    }
    default: {
      const passage = el("div", "passage" + (hit.kind === "code" ? " code" : ""));
      passage.textContent = (hit.excerpt ?? "").replace(/[«»]/g, "") || baseName(hit.path);
      api(`/api/v1/media/${hit.media_id}/text`).then((reply) => {
        if (reply.text) passage.textContent = reply.text.slice(0, 4000);
      }).catch(() => {});
      return passage;
    }
  }
}

// Transcripts and text (the desktop pulls the passage that matched; same op /text).
function textPassage(hit) {
  const box = el("pre", "excerpt");
  box.textContent = "reading…";
  api(`/api/v1/media/${hit.media_id}/text`).then((reply) => {
    box.textContent = (reply.text || "").slice(0, 4000) || "no text for this segment";
  }).catch((error) => { box.textContent = `text unavailable: ${error.message}`; });
  return box;
}

function facts(hit) {
  const box = el("div", "facts");
  box.append(el("div", "title", baseName(hit.path)),
    el("div", "line", folderOf(hit.path)));
  const details = [hit.kind,
    hit.size ? bytes(hit.size) : null,
    hit.modified ? date(hit.modified) : null,
    hit.z !== undefined ? `z ${hit.z.toFixed(2)}` : null,
    hit.cosine !== undefined ? `cosine ${hit.cosine.toFixed(3)}` : null,
    hit.keyword_rank !== undefined && hit.keyword_rank !== null ? `keyword #${hit.keyword_rank}` : null,
    hit.segment !== undefined ? `segment ${hit.segment}` : null].filter(Boolean);
  box.append(el("div", "line", details.join(" · ")));
  const reason = el("div", "reason");
  reason.append(el("span", null, reasonOf(hit)));
  box.append(reason);
  const buttons = el("div", "buttons");
  const open = el("a", "button-like", "Open");
  open.href = `/api/v1/media/${hit.media_id}/file`;   // server-issued handle, inline media
  open.target = "_blank";
  open.rel = "noopener";
  const save = el("a", "button-like", "Download");
  save.href = `/api/v1/media/${hit.media_id}/file`;
  save.download = baseName(hit.path);
  buttons.append(open, save);
  box.append(buttons);
  return box;
}

function reasonOf(hit) {
  if (hit.keyword_rank !== undefined && hit.keyword_rank !== null && hit.z === undefined)
    return `keyword search: the words matched (#${hit.keyword_rank} of the keyword matches)`;
  if (hit.keyword_rank !== undefined && hit.keyword_rank !== null)
    return `meaning ${hit.z.toFixed(2)}σ · the words matched too (keyword #${hit.keyword_rank})`;
  if (hit.z !== undefined) return `meaning match: ${(hit.z).toFixed(2)}σ past the best-mix baseline`;
  return "keyword search: the words matched in it";
}

function renderFooter() {
  const strong = state.strong.length, weaker = state.weaker.length;
  let summary;
  if (state.error) summary = `The server's helper: ${state.error}`;
  else if (state.phase === "words") summary = "Matching words…";
  else if (state.phase === "wordsOnly") summary = "Words only: meaning search isn't available";
  else if (state.phase === "codeHint") summary = "Searching your code";
  else if (state.phase === "empty") summary = "";
  else summary = `${strong} ${strong === 1 ? "result" : "results"}` + (weaker ? ` · ${weaker} weaker` : "");
  if (state.indexing) {
    const j = state.indexing;
    summary = (summary ? summary + " · " : "")
      + `indexing ${j.state}${j.files_done ? ` ${j.files_done}` : ""}${j.files ? `/${j.files}` : ""}`
      + (j.searchable !== undefined && j.searchable !== null ? ` · searchable ${j.searchable}` : "");
  }
  $("summary").textContent = summary;
}

// ── opening a result (the desktop's Open: the file itself; video plays from its moment)
function openHit(hit) {
  if (!hit) return;
  window.open(`/api/v1/media/${hit.media_id}/file`, "_blank", "noopener");
}

// ── the big look (Space, as Quick Look; Esc puts it away) ─────────────────────────────
function toggleBig() {
  if (!$("big").hidden) return closeBig();
  $("big").hidden = false;
  renderBig();
}
function closeBig() {
  $("big").hidden = true;
  $("big").replaceChildren();               // its video or sound stops with it
}
function renderBig() {
  const hit = selectedHit();
  if (!hit) return closeBig();
  const head = el("div", "head");
  head.append(el("span", "name", baseName(hit.path)),
    el("span", "place", folderOf(hit.path)),
    el("button", "close", "Esc"));
  head.querySelector(".close").onclick = closeBig;
  const box = el("div", "view");
  box.append(picture(hit));
  $("big").replaceChildren(el("div", "big-panel", head, box));
  $("big").onclick = (event) => { if (event.target === $("big")) closeBig(); };
}

// ── keys and events (the footer says them; they work from the search field and the list)
$("q").addEventListener("input", queryChanged);
$("q").addEventListener("keydown", (event) => {
  // In the field: ↑↓ pick results, ↩ opens the pick, Space types a space (as the desktop
  // panel: Space previews only after you've navigated).
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    move(event.key === "ArrowDown" ? 1 : -1);
  } else if (event.key === "Enter") {
    event.preventDefault();
    if (state.selection === WEAKER) toggleWeaker();
    else openHit(selectedHit());
  } else if (event.key === " " && state.navigated && state.selection) {
    event.preventDefault();
    if (state.selection === WEAKER) toggleWeaker();     // same as ↩ on that row, same as
    else toggleBig();                                   // the document handler's Space
  }
});
document.addEventListener("keydown", (event) => {
  const inField = ["INPUT", "SELECT", "TEXTAREA"].includes(event.target.tagName);
  switch (event.key) {
    case "Escape":
      if (!$("big").hidden) { event.preventDefault(); closeBig(); }
      else if (!$("settings").hidden) { event.preventDefault(); closeSettings(); }
      else if (!$("estimate").hidden) { event.preventDefault(); $("estimate").hidden = true; }
      else if ($("q").value) { $("q").value = ""; queryChanged(); $("q").focus(); }
      break;
    case "ArrowDown":
    case "ArrowUp":
      if (event.target === $("q") || inField) break;      // the field has its own handler
      event.preventDefault();
      move(event.key === "ArrowDown" ? 1 : -1);
      break;
    case " ":
      // Native button/link activation happens on keyup: preventing default here (the
      // Quick-Look preview) silently killed Space-activation of the gear, ✕, Index now,
      // Estimate, "all", the Esc close, and Open/Download — Space is a keyboard user's
      // standard activation key, so buttons and links keep it; only bare page areas type-preview.
      if (event.target.closest("button, a, [role='button'], input, select, textarea")) return;
      if (event.target === $("q")) break;                 // typing a space (the field handler above)
      if (!state.navigated && event.target.tagName === "INPUT") return;
      if (!state.selection && event.target.tagName !== "INPUT") return;
      event.preventDefault();
      if (state.selection === WEAKER) toggleWeaker();
      else toggleBig();
      break;
  }
});

// Kind boxes, code, limit: change → search again with the same text (the desktop re-searches
// when its window's filters change).
for (const box of document.querySelectorAll("#find input[data-kind]")) box.onchange = () => { if (state.text) queryChanged(); };
$("kinds-all").onclick = () => {
  for (const box of document.querySelectorAll("#find input[data-kind]")) box.checked = true;
  if (state.text) queryChanged();
};
$("code").onchange = () => { if ($("q").value.trim()) queryChanged(); else state.isCode = $("code").checked; };
$("limit").onchange = () => { if (state.text) queryChanged(); };

// ── idle suggestions: a click puts the phrase in the field and searches it — the exact
// path a typed query takes (queryChanged is the one search route; nothing here duplicates
// it). These are examples of *how to describe* a file, not promises about a library: they
// describe scenes, which is what the engine's meaning search answers.
const SUGGESTIONS = ["a dog running on the beach", "people gathered around a campfire",
                     "a cat sitting on a sofa", "wakeboarding on a lake"];
$("suggest").replaceChildren(...SUGGESTIONS.map((phrase) => {   // spread: replaceChildren is
  const chip = el("button", "suggest", phrase);                  // variadic — an array would
  chip.type = "button";                                          // arrive as a text node
  chip.onclick = () => { $("q").value = phrase; queryChanged(); $("q").focus(); };
  return chip;
}));

// ── Estimate: the engine's own forecast for the server's folders (POST /estimate).
// The button lives in settings; the forecast appears in the page, one honest line.
// Generation token (like searches have): a second click during a slow crawl must not
// let the FIRST crawl's late reply write results into a panel that was closed and
// reopened in between.
let estimateToken = 0;
$("estimate-btn").onclick = async () => {
  const panel = $("estimate");
  closeSettings();
  if (!panel.hidden) { panel.hidden = true; estimateToken++; return; }
  const token = ++estimateToken;
  panel.hidden = false;
  panel.replaceChildren(el("p", "note", "estimating — the engine is walking the folders…"));
  try {
    const {folders} = await api("/api/v1/estimate", {method: "POST", body: JSON.stringify({})});
    if (token !== estimateToken) return;               // a newer click owns the panel now
    panel.replaceChildren(el("p", "note",
      "The engine's own forecast for the folders it indexes. “measured here” = timed on this "
      + "machine by past indexing; “reference times” = the M4 Pro reference, too short for most PCs."));
    for (const f of folders) {
      const row = el("div", "estimate-folder");
      row.append(el("div", "estimate-head",
        el("code", null, f.folder),
        el("span", "badge", `≈ ${duration(f.seconds)}`),
        f.readable ? null : el("span", "badge warn", "can't read it"),
        f.calibrated ? el("span", "badge", "measured here") : el("span", "badge", "reference times")));
      if (!f.readable) { panel.append(row); continue; }
      const kinds = Object.entries(f.files || {}).map(([k, n]) => `${k} ${n}`);
      const extras = [
        f.pdf_pages_total ? `${f.pdf_pages_total} PDF pages (${f.pdf_pages} first pass)` : null,
        f.audio_seconds ? `${duration(f.audio_seconds)} of audio` : null,
        f.video_seconds ? `${duration(f.video_seconds)} of video` : null,
        f.bytes ? bytes(f.bytes) : null,
        f.long_files ? `${f.long_files} long files, ${duration(f.later_seconds)} later` : null,
        f.skipped ? `${f.skipped} skipped` : null,
        `looked in ${(f.ms / 1000).toFixed(2)} s`].filter(Boolean);
      row.append(el("div", "estimate-line", kinds.concat(extras).join(" · ")));
      const subs = (f.subfolders || []).slice(0, 5);
      for (const s of subs) row.append(el("div", "estimate-sub",
        el("code", null, s.folder), ` — ≈ ${duration(s.seconds)}`));
      panel.append(row);
    }
  } catch (error) {
    if (token === estimateToken)
      panel.replaceChildren(el("p", "warn", `estimate failed: ${error.message}`));
  }
};

// ── Index now: one job at a time; states and counts exactly as the engine reported ───
async function pollJob(id) {
  const at = $("job");
  const showJob = (job) => {
    state.indexing = ["queued", "running"].includes(job.state) ? job : null;
    if (!state.indexing) state.jobPoll = null;      // finished: a later 409 may poll afresh
    $("activity").hidden = !(state.encoder === "starting" || state.indexing);
    if (state.indexing) {
      $("activity").replaceChildren(el("span", "dot"), el("span", null, "indexing…"));
      $("activity").title = `indexing: ${state.indexing.files_done ?? 0} of ${state.indexing.files ?? "?"} files`;
    }
    const counts = [job.state,
      job.searchable !== null && job.searchable !== undefined ? `searchable ${job.searchable}/${job.files}` : null,
      job.pending ? `pending ${job.pending}` : null,
      job.vectors ? `vectors ${job.vectors}` : null,
      job.files_done ? `indexed ${job.files_done}` : null,
      job.seconds !== undefined ? `${job.seconds} s` : null,
      job.why].filter(Boolean);
    at.replaceChildren(el("span", `job-state job-${job.state}`, counts.join(" · ")));
    if (state.phase !== "empty") renderFooter();
  };
  for (;;) {
    let job;
    try {
      // A failed poll (server restarting, engine mid-respawn 503, network) used to reject
      // the loop's promise unhandled: the thread of polling DIED, the job line froze at
      // its last state, and "indexing…" stayed in the footer forever — no retry, no
      // honest error. Say what happened, clear the indexing state, stop.
      job = (await api(`/api/v1/jobs/${id}`)).job;
    } catch (error) {
      at.replaceChildren(el("span", "job-state job-interrupted", `job poll failed: ${error.message}`));
      state.indexing = null;
      state.jobPoll = null;
      $("activity").hidden = !(state.encoder === "starting");
      if (state.phase !== "empty") renderFooter();
      return;
    }
    showJob(job);
    if (["done", "interrupted", "busy"].includes(job.state)) { refreshStatus(); return; }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
}
$("index-btn").onclick = async () => {
  const at = $("job");
  const prune = $("prune").checked;       // engine --prune: retire rows of files no longer in the folders
  try {
    const {job} = await api("/api/v1/index", {method: "POST", body: JSON.stringify({prune})});
    at.replaceChildren(el("span", "job-state", `job ${job.id} queued`));
    state.jobPoll = job.id;
    pollJob(job.id);
  } catch (error) {
    if (error.status === 409) {
      const live = error.message.match(/job ([0-9a-f]+)/);   // answered busy: poll the live one
      if (live && live[1] !== state.jobPoll) {               // repeated clicks used to stack
        state.jobPoll = live[1];                             // a second polling loop on the
        pollJob(live[1]);                                    // same live id — one loop per job
      }
      at.replaceChildren(el("span", "job-state job-running", "busy — a job is already running"));
    } else {
      at.replaceChildren(el("span", "job-state job-interrupted", `index request failed: ${error.message}`));
    }
  }
};

render();               // the first paint is a state too: idle, with the centered welcome
refreshStatus();
setInterval(refreshStatus, 15000);
$("q").focus();
