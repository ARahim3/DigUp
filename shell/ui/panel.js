// The search panel of DigUp's Windows and Linux shell (tried out on the Mac first). Every keystroke shows keyword
// results at once (the last word as a prefix); once typing pauses for 120 ms the meaning results replace them (the
// query was embedded while you typed). Results far weaker than the best are folded under "N weaker matches". The
// helper (`digup search-service`) does the work; the Mac app's panel (Sources/DigUpApp/SearchPanel.swift) is the
// reference for how it behaves. results.js has what a result says.
"use strict";

const TYPING_PAUSE = 120;          // ms after the last keystroke until the meaning results show
const ROWS_PER_GROUP = 6;
const FIELD_HEIGHT = 56;
const PANEL_HEIGHT = 480;
const BIG_HEIGHT = 640;   // the panel at its tallest, for the big preview
const WEAKER = "\u0000weaker";     // the selectable row that folds and unfolds the weaker matches
// Wayland: the window fills the screen and this page places the panel (the shell's wayland.rs).
const fillsScreen = new URLSearchParams(location.search).has("fills");
// A group's name in the window's kind filters.
const FILTER_OF = { Screenshots: "screenshots", Images: "images", Documents: "documents", Video: "video",
                    Audio: "audio" };

const $ = (id) => document.getElementById(id);
const $panel = $("panel"), $query = $("query"), $body = $("body"), $list = $("list"), $preview = $("preview");
const $footer = $("footer"), $summary = $("summary"), $keys = $("keys"), $activity = $("activity");

const state = {
  generation: 0,
  finalGeneration: -1,   // the generation whose meaning results are showing: late keyword results don't replace them
  timer: null,
  phase: "empty",        // empty | words | meaning | wordsOnly | codeHint
  hasCode: true,         // code search has folders (the state's hasCode)
  text: "",              // what was searched (without "code:")
  isCode: false,
  strong: [],
  weaker: [],
  groups: [],
  showWeaker: false,
  selection: null,       // a result's path, or WEAKER
  navigated: false,      // the arrow keys moved the selection since the last edit
  encoder: "stopped",
  height: FIELD_HEIGHT,
  error: null,
  indexing: null,        // {done, total} while the index helper works through new files
  caveat: null,          // why results may be incomplete right now (the shell's status.rs)
};
let debugPending = false;

// MARK: Searching

function queryChanged() {
  closeBig();
  const generation = ++state.generation;
  clearTimeout(state.timer);
  state.navigated = false;
  state.error = null;
  const typed = $query.value.trim();
  const code = /^code:/i.test(typed);
  const text = code ? typed.slice(5).trim() : typed;
  state.isCode = code;
  if (!typed || (code && !text)) {
    show({ hits: [], strong: 0 }, text, typed ? "codeHint" : "empty");
    return;
  }
  // Words now. The last word is probably half-typed, so it matches as a prefix.
  ask({ op: "search", q: text, code, meaning: false, prefix_last: true, limit: 40 })
    .then((reply) => {
      if (generation === state.generation && state.finalGeneration !== generation) show(reply, text, "words");
    })
    .catch(failed);
  // The meaning is embedded now, so its vector is ready when typing pauses: the pause is the whole wait.
  ask({ op: "embed_ahead", q: text, code }).catch(() => {});
  state.timer = setTimeout(() => {
    ask({ op: "search", q: text, code, meaning: true, limit: 40 })
      .then((reply) => {
        if (generation !== state.generation) return;
        state.finalGeneration = generation;
        show(reply, text, reply.meaning ? "meaning" : "wordsOnly");
        if (debugPending) report();
      })
      .catch(failed);
  }, TYPING_PAUSE);
}

function show(reply, text, phase) {
  const hits = reply.hits || [];
  const strong = Math.min(reply.strong ?? hits.length, hits.length);
  state.text = text;
  state.phase = phase;
  state.strong = hits.slice(0, strong);
  state.weaker = hits.slice(strong);
  // Grouped by kind, the best hit's group first; code is one group with the room of all of them.
  const groups = new Map();
  for (const hit of state.strong) {
    const title = GROUP_OF[hit.kind] || "Files";
    if (!groups.has(title)) groups.set(title, []);
    groups.get(title).push(hit);
  }
  const perGroup = state.isCode ? ROWS_PER_GROUP * 3 : ROWS_PER_GROUP;
  state.groups = [...groups].map(([title, rows]) => ({ title, rows: rows.slice(0, perGroup), total: rows.length }));
  if (!state.navigated) state.showWeaker = false;
  // Follow the top hit until you pick something with the arrow keys.
  const ids = rowIDs();
  if (!state.navigated || !ids.includes(state.selection)) state.selection = ids[0] ?? null;
  render();
}

function failed(error) {
  state.error = String(error);
  renderFooter();
}

function rowIDs() {
  return [
    ...state.groups.flatMap((group) => group.rows.map((hit) => hit.path)),
    ...(state.weaker.length ? [WEAKER] : []),
    ...(state.showWeaker ? state.weaker.map((hit) => hit.path) : []),
  ];
}

function selectedHit() {
  return [...state.strong, ...state.weaker].find((hit) => hit.path === state.selection) ?? null;
}

function move(step) {
  const ids = rowIDs();
  if (!ids.length) return;
  const index = ids.indexOf(state.selection);
  state.selection = ids[Math.max(0, Math.min(ids.length - 1, (index < 0 ? -1 : index) + step))];
  state.navigated = true;
  render();
}

function toggleWeaker() {
  state.showWeaker = !state.showWeaker;
  state.selection = WEAKER;
  render();
}

function openSelected() {
  const hit = selectedHit();
  if (hit) openResult(hit).catch(failed);
}

function revealSelected() {
  const hit = selectedHit();
  if (hit) invoke("reveal", { path: hit.path }).catch(failed);
}

/// The same search in the window, for a bigger look (only one kind, if given).
function openInWindow(kind) {
  invoke("open_window", { query: $query.value.trim(), kind: kind ?? null }).catch(failed);
}

// MARK: Drawing

/// The panel's height: the window's, or in a window that fills the screen the panel's own, whose place the shell is
/// told so that only the panel takes the pointer.
function fit() {
  if (!fillsScreen) {
    invoke("panel_height", { height: state.height }).catch(() => {});
    return;
  }
  $panel.style.height = `${state.height}px`;
  const { left, top, width, height } = $panel.getBoundingClientRect();
  invoke("panel_area", { x: left, y: top, width, height }).catch(() => {});
}

if (fillsScreen) {
  document.documentElement.classList.add("fills-screen");
  window.addEventListener("resize", fit);
  fit();
}

function render() {
  const empty = state.phase === "empty";
  const height = empty ? FIELD_HEIGHT : $big.hidden ? PANEL_HEIGHT : BIG_HEIGHT;
  if (height !== state.height) {
    state.height = height;
    fit();
  }
  $body.hidden = empty;
  $footer.hidden = empty;
  if (empty) return;
  renderList();
  renderPreview();
  renderFooter();
}

function renderList() {
  $list.replaceChildren();
  const nothing = !state.strong.length && !state.weaker.length;
  $list.hidden = nothing;
  if (nothing) return;
  for (const group of state.groups) {
    $list.append(element("div", "group-title", group.title));
    for (const hit of group.rows) $list.append(row(hit));
    // More of this kind than the panel has room for: all of them in the window.
    if (group.total > group.rows.length && FILTER_OF[group.title]) {
      const more = element("div", "more", `Show all ${group.total} ${group.title.toLowerCase()}…`);
      more.title = `Open them in the DigUp window (${MOD}O shows everything)`;
      more.onclick = () => openInWindow(FILTER_OF[group.title]);
      $list.append(more);
    }
  }
  if (state.weaker.length) {
    const fold = element("div", "weaker" + (state.showWeaker ? " open" : "") + (state.selection === WEAKER ? " selected" : ""));
    fold.innerHTML = ICONS.chevron;
    const count = state.weaker.length;
    fold.append(state.showWeaker ? "Weaker matches" : `${count} weaker ${count === 1 ? "match" : "matches"}`);
    fold.onclick = toggleWeaker;
    $list.append(fold);
    if (state.showWeaker) for (const hit of state.weaker) $list.append(row(hit));
  }
  $list.querySelector(".selected")?.scrollIntoView({ block: "nearest" });
}

function row(hit) {
  const item = element("div", "row" + (state.selection === hit.path ? " selected" : ""));
  item.setAttribute("role", "option");
  item.append(thumbnail(hit));
  const text = element("div", "row-text");
  const title = element("div", "row-title");
  title.append(element("span", "name", nameOf(hit.path)));
  const place = placeOf(hit);
  if (place) title.append(element("span", "badge", place));
  const sub = element("div", "row-sub");
  // The words found, where keyword search found them; else where the file is.
  if (hit.excerpt && hit.excerpt.includes("«")) sub.innerHTML = marked(hit.excerpt);
  else sub.textContent = folderOf(hit);
  text.append(title, sub);
  item.append(text);
  item.onclick = () => {
    state.selection = hit.path;
    state.navigated = true;
    render();
  };
  item.ondblclick = openSelected;
  return item;
}

/// A picture of the file for its row: the picture itself, a video's frame at the moment, a PDF's page; else its
/// kind's icon. All come small from the helper (a full-size photo per row would cost the web view hundreds of MB).
function thumbnail(hit) {
  const pixels = Math.round(36 * (window.devicePixelRatio || 1));
  const what = renderOf(hit);
  if (!what) return kindIcon(hit.kind);
  const image = element("img", "thumb");
  image.alt = "";
  rendered(hit.path, what[0], what[1], pixels)
    .then((path) => { image.src = fileURL(path); })
    .catch(() => image.replaceWith(kindIcon(hit.kind)));
  return image;
}

function renderPreview() {
  $preview.replaceChildren();
  if (!state.strong.length && !state.weaker.length) {
    if (state.isCode && !state.hasCode) {
      $preview.append(message("Code search is off", "Choose folders with code in Settings → Code, and DigUp finds "
        + "code by what it does."));
    } else if (state.phase === "codeHint") {
      $preview.append(message("Search your code", "Say what the code does, or type a name that's in it."));
    } else if (state.phase === "words") {
      // The words are in and the meaning results on their way (as on the Mac): no verdict yet.
      const box = element("div", "message");
      box.append(element("span", "", "Searching…"));
      $preview.append(box);
    } else if (state.indexing) {
      const { done, total } = state.indexing;
      $preview.append(message("Nothing yet", `Still indexing (${done} of ${total} files). Until a file is read, `
        + "DigUp finds it only by its name."));
    } else if (state.isCode) {
      $preview.append(message("No good matches in your code", "Try saying what the code does, or a name that's in it."));
    } else {
      $preview.append(message("No good matches", "Try what you'd see or hear in it, or words you remember from it."));
    }
    return;
  }
  if (state.selection === WEAKER) {
    const count = state.weaker.length;
    $preview.append(message(state.showWeaker ? "Weaker matches" : `${count} weaker ${count === 1 ? "match" : "matches"}`,
      "They match much less well than the results above. Press Return to " + (state.showWeaker ? "fold them away." : "show them.")));
    return;
  }
  const hit = selectedHit();
  if (!hit) return;
  $preview.append(picture(hit), facts(hit));
}

/// The big picture: the photo or screenshot, the frame at the moment (it plays from there), the page, what's heard
/// at the moment, or the passage that matched.
function picture(hit) {
  const frame = element("div", "picture");
  const image = element("img");
  image.alt = "";
  frame.append(image);
  switch (hit.kind) {
    case "image":
    case "screenshot":
      if (SHOWN_AS_IS.has(extensionOf(hit.path))) image.src = fileURL(hit.path);
      else rendered(hit.path, "image", null, 1024).then((path) => { image.src = fileURL(path); }).catch(() => {});
      return frame;
    case "pdf":
      rendered(hit.path, "pdf", hit.loc ?? 1, 1024).then((path) => { image.src = fileURL(path); }).catch(() => {});
      return frame;
    case "video": {
      // The frame at the moment, its time on it; a click plays the video from there.
      const at = hit.loc ?? 0;
      rendered(hit.path, "video", at, 1024).then((path) => { image.src = fileURL(path); }).catch(() => {});
      const moment = element("div", "moment");
      const play = element("div", "play");
      play.innerHTML = ICONS.play;
      moment.append(image, play, element("span", "at", clock(at)));
      frame.replaceChildren(moment);
      frame.onclick = () => {
        const video = element("video");
        video.src = `${fileURL(hit.path)}#t=${at}`;
        video.controls = true;
        video.autoplay = true;
        frame.replaceChildren(video);
      };
      return frame;
    }
    case "audio": {
      const audio = element("div", "audio-picture");
      audio.innerHTML = ICONS.audio;
      const player = element("audio");
      player.src = `${fileURL(hit.path)}#t=${hit.loc ?? 0}`;
      player.controls = true;
      player.preload = "metadata";
      audio.append(player);
      frame.replaceChildren(audio);
      return frame;
    }
    default: {
      const passage = element("div", "passage" + (hit.kind === "code" ? " code" : ""));
      passage.textContent = (hit.excerpt ?? "").replace(/[«»]/g, "");
      ask({ op: "text", segment: hit.segment_id, code: state.isCode })
        .then((reply) => { if (reply.text) passage.innerHTML = highlighted(reply.text, state.text); })
        .catch(() => {});
      return passage;
    }
  }
}

function facts(hit) {
  const box = element("div", "facts");
  box.append(element("div", "title", nameOf(hit.path)), element("div", "line", folderOf(hit)),
             element("div", "line", details(hit)));
  const reason = element("div", "reason");
  reason.innerHTML = ICONS.found;
  reason.append(element("span", "", reasonOf(hit)));
  box.append(reason);
  if (hit.excerpt && hit.excerpt.includes("«") && hit.kind !== "doc" && hit.kind !== "code") {
    const words = element("div", "reason-text");
    words.innerHTML = marked(hit.excerpt);
    box.append(words);
  }
  const buttons = element("div", "buttons");
  const open = element("button", "", "Open");
  open.onclick = openSelected;
  const reveal = element("button", "", `Show in ${FILE_MANAGER}`);
  reveal.onclick = revealSelected;
  buttons.append(open, reveal);
  box.append(buttons);
  return box;
}

function renderFooter() {
  const strong = state.strong.length, weaker = state.weaker.length;
  let summary;
  if (state.error) summary = `DigUp's helper: ${state.error}`;
  else if (state.phase === "words") {
    summary = state.encoder === "starting" ? "Matching words; meaning search is warming up…" : "Matching words…";
  } else if (state.phase === "wordsOnly") summary = "Words only: meaning search isn't available";
  else if (state.phase === "codeHint") summary = "Searching your code";
  // Results while indexing (or before the model is in) may be missing some: that, where they're counted.
  else if (state.caveat && !state.isCode) summary = state.caveat;
  else summary = `${strong} ${strong === 1 ? "result" : "results"}` + (weaker ? ` · ${weaker} weaker` : "");
  $summary.textContent = summary;
  $keys.textContent = `↩ Open   ${MOD}↩ Show in ${FILE_MANAGER}   ␣ Preview`;
}

// MARK: The big preview (Space, as Quick Look on the Mac)

const $big = element("div", "big");
$big.hidden = true;
document.getElementById("panel").append($big);

/// Space, once a result is chosen with the arrows or a click: the panel at its tallest with the result over all of
/// it, a video playing from its moment. Space or Esc puts it away; the arrows go on through the results under it.
function toggleBig() {
  if (!$big.hidden) return closeBig();
  $big.hidden = false;
  renderBig();
  render();
}

function closeBig() {
  if ($big.hidden) return;
  $big.hidden = true;
  $big.replaceChildren();   // its video or sound stops with it
  render();
}

function renderBig() {
  const hit = selectedHit();
  if (!hit) return closeBig();
  const head = element("div", "head");
  head.append(element("span", "name", nameOf(hit.path)));
  const place = placeOf(hit);
  if (place) head.append(element("span", "place", place));
  let view;
  if (hit.kind === "video") {
    view = element("video");
    view.src = `${fileURL(hit.path)}#t=${hit.loc ?? 0}`;
    view.controls = true;
    view.autoplay = true;
  } else {
    view = picture(hit);
  }
  const box = element("div", "view");
  box.append(view);
  $big.replaceChildren(head, box);
}

function message(title, text) {
  const box = element("div", "message");
  box.append(element("strong", "", title), element("span", "", text));
  return box;
}

// MARK: Keys and events

$query.addEventListener("input", queryChanged);

document.addEventListener("keydown", (event) => {
  if (event.isComposing) return; // an input method is composing: its keys
  const modifier = isMac ? event.metaKey : event.ctrlKey;
  switch (event.key) {
    case "Escape":
      event.preventDefault();
      if (!$big.hidden) closeBig();
      else invoke("hide_panel").catch(() => {});
      break;
    case " ":
      // After the arrows or a click: the big preview (or the weaker matches' fold). While typing: a space.
      if (event.altKey || event.shiftKey || modifier || !(state.navigated || !$big.hidden) || !state.selection) return;
      event.preventDefault();
      if (state.selection === WEAKER) toggleWeaker();
      else toggleBig();
      break;
    case "ArrowDown":
    case "ArrowUp":
      if (event.altKey || event.shiftKey || modifier) return;
      event.preventDefault();
      move(event.key === "ArrowDown" ? 1 : -1);
      if (!$big.hidden) {
        if (state.selection === WEAKER) closeBig();
        else renderBig();
      }
      break;
    case "Enter":
      event.preventDefault();
      closeBig();
      if (modifier) revealSelected();
      else if (state.selection === WEAKER) toggleWeaker();
      else openSelected();
      break;
    case "c":
    case "C":
      if (!modifier || event.altKey || event.shiftKey || state.selection === WEAKER) return;
      copyResult(event, selectedHit(), state.navigated);
      break;
    case "o":
    case "O":
      if (!modifier || event.altKey || event.shiftKey) return;
      event.preventDefault();
      openInWindow();
      break;
  }
});

tauri.event.listen("panel-shown", () => {
  closeBig();
  // Like Spotlight: the last query, selected.
  $query.focus();
  $query.select();
  ask({ op: "prewarm" }).catch(() => {});
});

tauri.event.listen("helper", ({ payload }) => {
  const { from, event } = payload;
  if (from === "search" && event.event === "encoder") {
    state.encoder = event.state;
    if (state.phase !== "empty") renderFooter();
  }
});

/// Indexing and the model, from the shell: a badge beside the field while results may be incomplete ("Indexing 42%"),
/// as the Mac's panel has, with its progress as a ring.
function showState(app) {
  state.indexing = app.indexing || null;
  state.hasCode = app.hasCode !== false;
  state.caveat = app.caveat || null;
  $activity.hidden = !app.badge;
  if (app.badge) {
    const length = 2 * Math.PI * 4.6, done = Math.max(0.02, Math.min(1, app.progress ?? 0));
    $activity.innerHTML = app.progress == null ? "" : `<svg viewBox="0 0 12 12"><circle class="track" cx="6" cy="6" `
      + `r="4.6"/><circle class="done" cx="6" cy="6" r="4.6" stroke-dasharray="${(length * done).toFixed(2)} ${length.toFixed(2)}"/></svg>`;
    $activity.append(app.badge);
    $activity.title = app.line || "";
  }
  if (state.phase === "empty") return;
  renderFooter();
  if (!state.strong.length && !state.weaker.length) renderPreview();   // "Nothing yet": still indexing
}

tauri.event.listen("state", ({ payload }) => showState(payload));
invoke("app_state").then(showState).catch(() => {});

// Debug runs (--debug-query): type the query in, and once the meaning results and their pictures are in, report
// what the panel shows.
function debugSearch(query) {
  if (!query) return;
  debugPending = true;
  $query.value = query;
  queryChanged();
}
invoke("debug_query").then(debugSearch);
tauri.event.listen("debug-query", ({ payload }) => debugSearch(payload));   // after setup's first index

function report() {
  debugPending = false;
  // Dev snapshots (index.html?big): the selected result's big preview, as Space shows it.
  if (new URLSearchParams(location.search).has("big")) toggleBig();
  setTimeout(() => {
    const big = $preview.querySelector("img, video, audio, .passage");
    const thumbs = [...$list.querySelectorAll("img.thumb")];
    invoke("debug_report", {
      report: {
        query: $query.value,
        phase: state.phase,
        groups: state.groups.map((group) => ({ title: group.title, rows: group.rows.map((hit) => nameOf(hit.path)) })),
        weaker: state.weaker.length,
        selected: state.selection && nameOf(state.selection),
        preview: big && {
          tag: big.tagName.toLowerCase(),
          loaded: big.tagName === "IMG" ? big.complete && big.naturalWidth > 0 : null,
          size: big.tagName === "IMG" ? `${big.naturalWidth}x${big.naturalHeight}` : null,
          text: big.classList.contains("passage") ? big.textContent.slice(0, 80) : null,
        },
        thumbnails: `${thumbs.filter((image) => image.complete && image.naturalWidth > 0).length} of ${thumbs.length} drawn`,
        facts: [...$preview.querySelectorAll(".facts .title, .facts .line, .reason span")].map((node) => node.textContent),
        footer: [$summary.textContent, $keys.textContent],
      },
    }).catch(() => {});
  }, 1500);
}
