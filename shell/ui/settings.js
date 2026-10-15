// DigUp's Settings window, its tabs after the Mac app's (Sources/DigUpApp/SettingsWindow.swift). General: opening at
// login, centering the search panel where the desktop places windows itself (it costs memory, so it's a choice), where
// the shortcut lives, and updates. Folders: how indexing goes (with Pause), each folder searched and how far along it is, the
// folders and file types skipped, and the set hours. Code: code search's folders (added in setup's folder list for code),
// the editor its results open in, turning it off. Storage: the model, the index, privacy.
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const ask = (request) => invoke("ask", { request });
const isWindows = /Win/.test(navigator.platform);
const $ = (id) => document.getElementById(id);

const notes = {
  gnome: "DigUp added it to GNOME's keyboard shortcuts. To change it: Settings → Keyboard → View and Customize " +
    "Shortcuts → Custom Shortcuts.",
  kde: "DigUp added it to KDE's shortcuts. To change it: System Settings → Shortcuts → DigUp.",
  by_hand: "This desktop doesn't let apps set their own shortcuts. To open the panel with one, add a shortcut in its " +
    "keyboard settings that runs:",
};

let info = {};
let summaries = null;        // what's indexed under each folder (search-service's summaries)
let removing = null;         // the folder whose removal is being confirmed
let codeSummaries = null;    // what's indexed under each code folder
let removingCode = null;     // the code folder whose removal is being confirmed

// MARK: Tabs

function showTab(name) {
  for (const button of document.querySelectorAll("#tabs button")) {
    button.setAttribute("aria-selected", String(button.dataset.tab === name));
  }
  for (const tab of document.querySelectorAll(".tab")) tab.hidden = tab.id !== name;
  if (name === "folders") loadSummaries();
  if (name === "code") loadCodeSummaries();
}

for (const button of document.querySelectorAll("#tabs button")) button.onclick = () => showTab(button.dataset.tab);

// MARK: General

function renderGeneral() {
  $("login-option").hidden = !info.canOpenAtLogin;
  $("login").checked = info.openAtLogin;
  $("tray-click-option").hidden = !info.canChooseTrayClick;
  for (const choice of document.querySelectorAll('input[name="tray-click"]')) choice.checked = choice.value === info.trayClick;
  $("center-option").hidden = !info.canCenter;
  $("center").checked = info.centered;
  $("keys").replaceChildren(...info.hotkey.split("+").filter(Boolean).map((key) => element("span", "key", key)));
  const note = notes[info.shortcut.method];
  $("shortcut-note").hidden = !note;
  $("shortcut-note").textContent = note || "";
  $("shortcut-command").hidden = info.shortcut.method !== "by_hand";
  $("shortcut-command").textContent = info.shortcut.command;
  $("change-shortcut").hidden = info.shortcut.method !== "grab" || recording;
  $("recording").hidden = !recording;
  renderUpdates();
}

/// Updates: the daily check, and this version or the one waiting (updates.rs).
function renderUpdates() {
  $("update-checks").checked = info.updateChecks;
  $("update-info").textContent = "Once a day DigUp asks GitHub for its newest version; nothing about your files is sent. "
    + (info.installsUpdates ? "Updates install with one click."
      : "A new version is downloaded from its release page and installed as this one was.");
  const update = info.state && info.state.update;
  const version = $("update-version");
  version.classList.toggle("available", Boolean(update));
  version.textContent = !update ? `DigUp ${info.version}`
    : update.state === "downloading" ? `Downloading DigUp ${update.version}…` + (update.percent != null ? ` ${update.percent}%` : "")
    : update.state === "installing" ? `Installing DigUp ${update.version}…` : `DigUp ${update.version} is available`;
}

$("licenses").onclick = () => invoke("open_licenses").catch(fail);

$("update-version").onclick = () => {
  if (info.state && info.state.update) invoke("offer_update").catch(fail);
};
$("check-now").onclick = async () => {
  $("problem").hidden = true;
  $("check-now").disabled = true;
  try {
    await invoke("check_for_updates");
  } catch (error) {
    fail(error);
  }
  $("check-now").disabled = false;
};

/// A switch: the shell does it, or the box goes back and says why.
function wire(box, command) {
  box.addEventListener("change", async () => {
    $("problem").hidden = true;
    try {
      await invoke(command, { on: box.checked });
    } catch (error) {
      box.checked = !box.checked;
      fail(error);
    }
  });
}

wire($("login"), "set_open_at_login");
wire($("center"), "set_center_panel");
wire($("update-checks"), "set_update_checks");
for (const choice of document.querySelectorAll('input[name="tray-click"]')) {
  choice.addEventListener("change", () => {
    $("problem").hidden = true;
    invoke("set_tray_click", { click: choice.value }).then(() => { info.trayClick = choice.value; }).catch(fail);
  });
}

// MARK: The shortcut (where DigUp grabs it itself: Windows, X11; shortcut.js)

let recording = false;

$("change-shortcut").onclick = () => {
  recording = true;
  $("problem").hidden = true;
  renderGeneral();
  recordShortcut((text) => { $("recording").textContent = text; }, (shown, problem) => {
    recording = false;
    if (shown) info.hotkey = shown;
    if (problem) fail(problem);
    renderGeneral();
  });
};

// MARK: Folders

/// How indexing goes: the status line, a bar while something's under way, the counts, and Pause or Resume.
function renderStatus() {
  const state = info.state || {};
  $("status-line").textContent = state.line || "";
  $("status-bar").hidden = state.progress == null;
  $("status-fill").style.width = `${Math.round(100 * (state.progress || 0))}%`;
  const parts = [`${(state.searchable || 0).toLocaleString()} of ${(state.files || 0).toLocaleString()} files searchable`];
  if (state.pending) parts.push(`${state.pending.toLocaleString()} waiting`);
  if (state.unfinished) parts.push(`${state.unfinished.toLocaleString()} long ${state.unfinished === 1 ? "file" : "files"} to finish`);
  $("status-detail").textContent = parts.join(" · ");
  $("pause").hidden = !info.folders?.length;
  $("pause").textContent = state.paused ? "Resume" : "Pause";
}

$("pause").onclick = () => invoke("pause_indexing", { paused: !(info.state || {}).paused }).catch(fail);

async function loadSummaries() {
  try {
    summaries = (await ask({ op: "summaries" })).roots || [];
  } catch {
    summaries = summaries || [];
  }
  renderFolders();
}

function renderFolders() {
  const rows = $("folder-rows");
  rows.replaceChildren();
  if (!info.folders?.length) rows.append(element("div", "empty", "No folders yet. Add the ones DigUp should search."));
  for (const folder of info.folders || []) {
    const summary = (summaries || []).find((item) => samePath(item.path, folder)) || null;
    rows.append(folderRow(folder, summary));
    if (removing && samePath(removing, folder)) rows.append(confirmRemoval(folder, summary));
  }
  const skipped = $("skipped-rows");
  skipped.replaceChildren();
  if (!info.skipped?.length) {
    skipped.append(element("div", "empty", "None. Code projects, app bundles and caches are skipped anyway."));
  }
  for (const folder of info.skipped || []) {
    const row = element("div", "row");
    const text = element("div", "text");
    text.append(element("div", "path", shown(folder)));
    row.append(text, removeButton("Search this folder again", () => {
      setSkipped(info.skipped.filter((path) => path !== folder));
    }));
    skipped.append(row);
  }
}

/// The fields: set from the settings when the window opens or they change, never while you're editing them.
function renderFields() {
  $("types").value = (info.skipTypes || []).join(", ");
  const hours = info.indexHours || { on: false, start: 60, end: 420 };
  $("hours").checked = hours.on;
  $("times").hidden = !hours.on;
  $("hours-start").value = clock(hours.start);
  $("hours-end").value = clock(hours.end);
}

/// A folder searched (with `code`, a code folder): its name, where it is, what's in it, how much of it is indexed, and
/// Remove.
function folderRow(folder, summary, code = false) {
  const row = element("div", "row");
  const text = element("div", "text");
  const name = element("div", "name", nameOf(folder));
  if (summary?.missing || summary?.unreadable) name.append(element("span", "flag", summary.missing ? "Not connected" : "No access"));
  text.append(name, element("div", "path", shown(folder)));
  if (summary && Object.keys(summary.kinds || {}).length) text.append(element("div", "counts", countsText(summary.kinds)));
  const side = element("div", "side");
  if (summary) {
    side.append(element("div", "indexed", summary.missing || summary.unreadable ? "Kept for when it's back"
      : `${summary.indexed.toLocaleString()} of ${summary.files.toLocaleString()} indexed`));
    const states = [
      summary.pending ? `${summary.pending.toLocaleString()} waiting` : null,
      summary.unfinished ? `${summary.unfinished.toLocaleString()} long ${summary.unfinished === 1 ? "file" : "files"} to finish` : null,
      summary.skipped ? `${summary.skipped.toLocaleString()} skipped` : null,
      summary.failed ? `${summary.failed.toLocaleString()} couldn't be read` : null,
    ].filter(Boolean).join(" · ");
    if (states) side.append(element("div", "states", states));
  }
  row.append(text, side, removeButton(code ? "Stop searching the code in this folder" : "Stop searching this folder", () => {
    if (code) {
      removingCode = folder;
      renderCode();
    } else {
      removing = folder;
      renderFolders();
    }
  }));
  return row;
}

/// "Stop searching “Pictures”?", in place, as the Mac app asks.
function confirmRemoval(folder, summary, code = false) {
  const box = element("div", "confirm");
  const files = summary ? `Its ${summary.files.toLocaleString()} ${summary.files === 1 ? "file leaves" : "files leave"}` : "Its files leave";
  const last = code && (info.code?.folders || []).length === 1;
  box.append(element("p", "", code
    ? `Stop searching the code in “${nameOf(folder)}”? ${files} the code index.${last ? " That turns code search off." : ""}`
    : `Stop searching “${nameOf(folder)}”? ${files} the index. Adding it back later indexes them again.`));
  const actions = element("div", "actions");
  const cancel = element("button", "", "Cancel");
  cancel.onclick = () => {
    removing = removingCode = null;
    renderFolders();
    renderCode();
  };
  const remove = element("button", "danger", "Remove");
  remove.onclick = async () => {
    removing = removingCode = null;
    try {
      await invoke(code ? "remove_code_folder" : "remove_folder", { folder });
    } catch (error) {
      fail(error);
    }
    await refresh();
  };
  actions.append(cancel, remove);
  box.append(actions);
  return box;
}

function removeButton(title, action) {
  const button = element("button", "remove", "−");
  button.title = title;
  button.setAttribute("aria-label", title);
  button.onclick = action;
  return button;
}

async function setSkipped(skipped) {
  try {
    await invoke("set_skipped", { skipped });
  } catch (error) {
    fail(error);
  }
  await refresh();
}

$("add-folders").onclick = () => invoke("choose_folders").catch(fail);
$("skip-folder").onclick = async () => {
  const picked = await invoke("pick_folders");
  if (picked.length) setSkipped([...(info.skipped || []), ...picked.filter((path) => !info.skipped.includes(path))]);
};

// File types: applied on Return, and when the field is left.
async function applyTypes() {
  try {
    info.skipTypes = await invoke("set_skip_types", { types: $("types").value });
    $("types").value = info.skipTypes.join(", ");
  } catch (error) {
    fail(error);
  }
}
$("types").addEventListener("keydown", (event) => { if (event.key === "Enter") applyTypes(); });
$("types").addEventListener("blur", applyTypes);

async function applyHours() {
  const on = $("hours").checked;
  const hours = { on, start: minutes($("hours-start").value, 60), end: minutes($("hours-end").value, 420) };
  $("times").hidden = !on;
  try {
    await invoke("set_index_hours", hours);
    info.indexHours = hours;
  } catch (error) {
    fail(error);
  }
}
$("hours").addEventListener("change", applyHours);
$("hours-start").addEventListener("change", applyHours);
$("hours-end").addEventListener("change", applyHours);

// MARK: Code

async function loadCodeSummaries() {
  if (!(info.code?.folders || []).length) {
    codeSummaries = [];
  } else {
    try {
      codeSummaries = (await ask({ op: "summaries", code: true })).roots || [];
    } catch {
      codeSummaries = codeSummaries || [];
    }
  }
  renderCode();
}

function renderCode() {
  const code = info.code || { folders: [], editors: [], editor: "default" };
  const on = code.folders.length > 0;
  // How far the code index is, over all code folders.
  const total = { files: 0, indexed: 0, pending: 0 };
  for (const summary of codeSummaries || []) {
    for (const name of Object.keys(total)) total[name] += summary[name] || 0;
  }
  $("code-status").hidden = !on || codeSummaries == null;
  $("code-status-line").textContent = total.pending
    ? `Reading code: ${total.indexed.toLocaleString()} of ${total.files.toLocaleString()} files`
    : `${total.indexed.toLocaleString()} ${total.indexed === 1 ? "file" : "files"} of code searchable`;
  const size = info.storage?.codeBytes;
  $("code-status-detail").textContent = size ? `The code index takes ${bytes(size)}` : "";

  const rows = $("code-rows");
  rows.replaceChildren();
  if (!on) rows.append(element("div", "empty", "Code search is off. Choose the folders that hold your code to turn it on."));
  for (const folder of code.folders) {
    const summary = (codeSummaries || []).find((item) => samePath(item.path, folder)) || null;
    rows.append(folderRow(folder, summary, true));
    if (removingCode && samePath(removingCode, folder)) rows.append(confirmRemoval(folder, summary, true));
  }
  $("add-code").textContent = on ? "Add Folders…" : "Choose Code Folders…";

  const select = $("code-editor");
  const options = [...code.editors, { id: "default", name: "The file's default app" }];
  select.replaceChildren(...options.map((editor) => {
    const option = element("option", "", editor.name);
    option.value = editor.id;
    return option;
  }));
  select.value = code.editor;
  $("code-off").hidden = !on || !$("code-off-confirm").hidden;
}

$("add-code").onclick = () => invoke("choose_code_folders").catch(fail);
$("code-editor").addEventListener("change", async () => {
  try {
    await invoke("set_code_editor", { editor: $("code-editor").value });
    info.code.editor = $("code-editor").value;
  } catch (error) {
    fail(error);
  }
});
$("code-off").onclick = () => {
  const size = info.storage?.codeBytes;
  $("code-off-text").textContent = "Turn off code search? Its index" + (size ? ` (${bytes(size)})` : "")
    + " is deleted, and turning it on again reads the code again.";
  $("code-off-confirm").hidden = false;
  $("code-off").hidden = true;
};
$("code-off-cancel").onclick = () => {
  $("code-off-confirm").hidden = true;
  renderCode();
};
$("code-off-go").onclick = async () => {
  $("code-off-confirm").hidden = true;
  try {
    await invoke("turn_off_code");
  } catch (error) {
    fail(error);
  }
  await refresh();
};

// MARK: Storage

function renderStorage() {
  const storage = info.storage || {}, model = (info.state || {}).model || {};
  const states = { ready: "Downloaded", checking: "Checking…", waiting: "Waiting for the network", failed: "The download stopped" };
  $("model-status").textContent = model.state === "downloading"
    ? `Downloading · ${model.total ? Math.floor((100 * model.bytes) / model.total) : 0}%` : states[model.state] || "";
  pathButton($("model-path"), storage.models);
  $("index-size").textContent = bytes(storage.indexBytes || 0) + (storage.codeBytes ? ` (code ${bytes(storage.codeBytes)})` : "");
  pathButton($("index-path"), storage.index);
  $("version").textContent = `DigUp ${info.version || ""} · EmbeddingGemma 2 by Google (Apache 2.0), run by llama.cpp (MIT).`;
  $("licenses").hidden = !info.licenses;
}

/// A folder's path; a click shows it in the file manager.
function pathButton(button, path) {
  button.replaceChildren();
  if (!path) return;
  const inner = document.createElement("bdi");
  inner.textContent = shown(path);
  button.append(inner);
  button.title = isWindows ? "Show in Explorer" : "Show in Files";
  button.onclick = () => invoke("reveal", { path }).catch(fail);
}

// MARK: Words

function countsText(kinds) {
  const part = (count, one, many) => (count > 0 ? `${count.toLocaleString()} ${count === 1 ? one : many}` : null);
  return [
    part((kinds.image || 0) + (kinds.screenshot || 0), "picture", "pictures"),
    part(kinds.pdf, "PDF", "PDFs"),
    part(kinds.doc, "document", "documents"),
    part(kinds.audio, "recording", "recordings"),
    part(kinds.video, "video", "videos"),
    part(kinds.code, "file of code", "files of code"),
  ].filter(Boolean).join(" · ");
}

/// Sizes the way file managers count them: "62 KB", "2.1 MB".
function bytes(count) {
  if (count < 1000) return `${count} bytes`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = count / 1000, unit = 0;
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1; }
  return `${value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

function clock(minute) {
  return `${String(Math.trunc(minute / 60) % 24).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}`;
}

function minutes(text, fallback) {
  const match = /^(\d{1,2}):(\d{2})/.exec(text || "");
  return match ? Number(match[1]) * 60 + Number(match[2]) : fallback;
}

function nameOf(path) {
  return path.split(/[\\/]/).filter(Boolean).pop() || path;
}

function shown(path) {
  return isWindows ? path.replaceAll("/", "\\") : path;
}

function samePath(a, b) {
  const plain = (path) => (path || "").replaceAll("\\", "/").replace(/\/$/, "");
  return isWindows ? plain(a).toLowerCase() === plain(b).toLowerCase() : plain(a) === plain(b);
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function fail(error) {
  $("problem").textContent = String(error);
  $("problem").hidden = false;
}

// MARK: Start

async function refresh() {
  info = await invoke("settings_info");
  renderGeneral();
  renderStatus();
  renderFolders();
  renderFields();
  renderStorage();
  renderCode();
  if (!$("folders").hidden) loadSummaries();
  if (!$("code").hidden) loadCodeSummaries();
}

// Back from the code folders window (or anything else that changed the settings): shown as they are now.
window.addEventListener("focus", () => { refresh().catch(() => {}); });

// Indexing as it goes, and what's indexed under each folder at most every two seconds.
let summariesTimer = null;
tauri.event.listen("state", ({ payload }) => {
  const before = info.state || {};
  info.state = payload;
  renderStatus();
  renderStorage();
  renderUpdates();
  // The code index's progress isn't in the state: its folders are asked again while the tab is up.
  const counts = payload.searchable !== before.searchable || payload.pending !== before.pending;
  const load = !$("folders").hidden && counts ? loadSummaries : !$("code").hidden ? loadCodeSummaries : null;
  if (load && !summariesTimer) {
    summariesTimer = setTimeout(() => { summariesTimer = null; load(); }, 2000);
  }
});

async function start() {
  await refresh();
  // Debug runs (--debug-settings): the page is up.
  if (info.debug) {
    invoke("debug_report", { report: { settings: true, hotkey: info.hotkey, openAtLogin: info.openAtLogin,
                                       canOpenAtLogin: info.canOpenAtLogin, folders: info.folders } }).catch(() => {});
  }
  const asked = new URLSearchParams(location.search).get("tab");   // dev snapshots: ?tab=folders
  showTab(asked || "general");
}

start();
