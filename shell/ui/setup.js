// DigUp's setup window: what to search and the shortcut, with the model downloading in the background from the moment
// it opens (the shell starts that), as the Mac app's onboarding does. Folders show what's in them (`digup estimate`):
// counts, not times, until the estimates are measured on more than the Mac.
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const isMac = /Mac/.test(navigator.platform);
const isWindows = /Win/.test(navigator.platform);
const PAGES = ["welcome", "folders", "shortcut", "ready"];

const $ = (id) => document.getElementById(id);
const folders = new Map();   // path → {checked, row, counts}
let page = 0;
let info = { offered: [], chosen: [], hotkey: "", model: { state: "checking" }, auto: false };

async function start() {
  info = await invoke("setup_info");
  // The usual folders, then any chosen before (Choose Folders… after setup). On a first launch they start checked,
  // all but Downloads (much of what lands there is passing through).
  const chosen = new Set(info.chosen);
  const firstTime = chosen.size === 0;
  for (const path of info.offered) addFolder(path, firstTime ? !/[\\/]Downloads$/i.test(path) || info.auto : chosen.has(path));
  for (const path of info.chosen) if (!folders.has(path)) addFolder(path, true);
  estimate([...folders.keys()]);
  showModel(info.model);
  tauri.event.listen("model", ({ payload }) => showModel(payload));
  showKeys(info.hotkey);
  if (!firstTime) page = 1;   // Choose Folders…: straight to the folders
  const asked = PAGES.indexOf(new URLSearchParams(location.search).get("page"));   // dev snapshots: ?page=folders
  if (asked >= 0) page = asked;
  render();
  if (info.auto) setTimeout(clickThrough, 500);
}

// MARK: Pages

function render() {
  PAGES.forEach((name, index) => { $(name).hidden = index !== page; });
  $("back").hidden = page === 0;
  $("next").textContent = page === PAGES.length - 1 ? "Start" : "Continue";
  $("next").disabled = page === 1 && !chosenFolders().length;
}

$("next").addEventListener("click", async () => {
  if (page < PAGES.length - 1) {
    page += 1;
    render();
    return;
  }
  $("next").disabled = true;
  try {
    await invoke("finish_setup", { folders: chosenFolders() });
  } catch (error) {
    $("model").textContent = String(error);
    $("next").disabled = false;
  }
});

$("back").addEventListener("click", () => {
  page = Math.max(0, page - 1);
  render();
});

/// Debug runs (--debug-setup): every offered folder, every page, then Start.
async function clickThrough() {
  while (page < PAGES.length - 1) {
    $("next").click();
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  $("next").click();
}

// MARK: Folders

function addFolder(path, checked) {
  const row = document.createElement("label");
  row.className = "folder";
  const box = document.createElement("input");
  box.type = "checkbox";
  box.checked = checked;
  box.addEventListener("change", () => {
    folders.get(path).checked = box.checked;
    render();
  });
  const text = document.createElement("div");
  text.className = "text";
  const name = document.createElement("div");
  name.className = "name";
  name.textContent = path.split(/[\\/]/).filter(Boolean).pop() || path;
  const where = document.createElement("div");
  where.className = "path";
  where.textContent = isWindows ? path.replaceAll("/", "\\") : path;
  text.append(name, where);
  const counts = document.createElement("div");
  counts.className = "counts";
  counts.textContent = "Counting…";
  row.append(box, text, counts);
  $("folder-list").append(row);
  folders.set(path, { checked, row, counts });
}

function chosenFolders() {
  return [...folders].filter(([, folder]) => folder.checked).map(([path]) => path);
}

async function estimate(paths) {
  if (!paths.length) return;
  let answers = [];
  try {
    answers = await invoke("estimate", { folders: paths });
  } catch (error) {
    for (const path of paths) folders.get(path).counts.textContent = "";
    return;
  }
  for (const path of paths) {
    const answer = answers.find((item) => same(item.folder, path));
    folders.get(path).counts.textContent = answer ? countsText(answer) : "";
  }
}

/// The helper reports folders with forward slashes (and Windows paths compare without case).
function same(a, b) {
  const plain = (path) => (path || "").replaceAll("\\", "/").replace(/\/$/, "");
  return isWindows ? plain(a).toLowerCase() === plain(b).toLowerCase() : plain(a) === plain(b);
}

/// "1,204 pictures · 37 PDFs · 12 documents · 3 videos"
function countsText(answer) {
  if (answer.readable === false) return "Can't read it";
  const files = answer.files || {};
  const part = (count, one, many) => (count ? `${count.toLocaleString()} ${count === 1 ? one : many}` : null);
  const parts = [
    part((files.image || 0) + (files.screenshot || 0), "picture", "pictures"),
    part(files.pdf, "PDF", "PDFs"),
    part(files.doc, "document", "documents"),
    part(files.audio, "recording", "recordings"),
    part(files.video, "video", "videos"),
  ].filter(Boolean);
  return parts.length ? parts.join(" · ") : "Nothing DigUp searches in it";
}

$("add-folder").addEventListener("click", async () => {
  const picked = (await invoke("pick_folders")).filter((path) => !folders.has(path));
  for (const path of picked) addFolder(path, true);
  estimate(picked);
  render();
});

// MARK: The shortcut and the model

function showKeys(hotkey) {
  const keys = isMac ? [...hotkey.replace(/[^⌃⌥⇧⌘]/g, "")].concat(hotkey.replace(/[⌃⌥⇧⌘]/g, "")) : hotkey.split("+");
  $("keys").replaceChildren(...keys.filter(Boolean).map((key) => {
    const cap = document.createElement("span");
    cap.className = "key";
    cap.textContent = key;
    return cap;
  }));
  $("reveal-key").textContent = isMac ? "⌘↩" : "Ctrl+↩";
  $("reveal-text").textContent = isMac ? "shows it in Finder" : isWindows ? "shows it in Explorer" : "shows it in its folder";
}

function showModel(model) {
  const megabytes = (bytes) => Math.round(bytes / 1e6).toLocaleString();
  const lines = {
    checking: "Checking the model…",
    waiting: "Waiting for the network to download the model",
    ready: "Model ready",
    failed: `The model couldn't download: ${model.message || "unknown error"}`,
  };
  let text = lines[model.state] || "";
  if (model.state === "downloading") {
    text = model.total
      ? `Downloading the model · ${Math.floor((100 * model.bytes) / model.total)}% of ${megabytes(model.total)} MB`
      : "Downloading the model…";
    if (model.problem) text += ` (${model.problem}, trying again)`;
  }
  $("model").textContent = text;
}

start();
