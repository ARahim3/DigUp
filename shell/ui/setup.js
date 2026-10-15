// DigUp's setup window: what to search and the shortcut, with the model downloading in the background from the moment
// it opens (the shell starts that), as the Mac app's onboarding does. Folders show what's in them and how long their
// first pass takes (`digup estimate`; the times once the helper has timed this computer with the model), and open to
// their subfolders. Indexing starts as the folders step is left; the last step shows it going (the download, then the
// files, with the time left) until Done opens the window. Choose Folders… later is the folders step alone, with Save.
// `?code`: the folders step for code search (Settings → Code → Add Folders…, as the Mac app's code folder list): folders
// with code, each with the time its code takes to read and its index's size, open to their repositories.
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const isMac = /Mac/.test(navigator.platform);
const isWindows = /Win/.test(navigator.platform);
// A first launch that finds code in the home folder also asks about code search, after the folders (`code`).
let PAGES = ["welcome", "folders", "shortcut", "ready"];
const SHORT_LIST = 6;   // subfolders shown before "Show N more"
const CHEVRON = '<svg viewBox="0 0 16 16"><path d="M6 3.5 L10.5 8 L6 12.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';

const $ = (id) => document.getElementById(id);
let page = 0;
let firstTime = true;
let info = { offered: [], chosen: [], skipped: [], hotkey: "", model: { state: "checking" }, state: {}, auto: false };
const codeMode = new URLSearchParams(location.search).has("code");

// MARK: Paths
// The helper reports folders with forward slashes; on Windows the shell gives them with backslashes, and case doesn't
// matter. Folders are kept as the helper spells them and handed back as the system does.

function canon(path) { return (path || "").replaceAll("\\", "/").replace(/(.)\/+$/, "$1"); }
function key(path) { return isWindows ? canon(path).toLowerCase() : canon(path); }
function same(a, b) { return key(a) === key(b); }
function inside(path, folder) { return key(path).startsWith(key(folder) + "/"); }
function parentOf(path) { const c = canon(path); return c.slice(0, c.lastIndexOf("/")) || c; }
function native(path) { return isWindows ? canon(path).replaceAll("/", "\\") : canon(path); }
function nameOf(path) { return canon(path).split("/").filter(Boolean).pop() || path; }
function unique(paths) { return paths.filter((path, index) => paths.findIndex((other) => same(other, path)) === index); }

// MARK: The selection (the engine's FolderSelection): chosen folders, minus the folders skipped inside them

const selection = {
  chosen: [],
  skipped: [],
  isSearched(path) {
    return this.chosen.some((folder) => (same(path, folder) || inside(path, folder))
      && !this.skipped.some((skip) => inside(skip, folder) && (same(path, skip) || inside(path, skip))));
  },
  /// A folder's checkbox: mixed when some of its subfolders are skipped (it's searched) or chosen (it isn't).
  mark(folder) {
    if (this.isSearched(folder)) {
      return this.skipped.some((skip) => same(parentOf(skip), folder) && !this.isSearched(skip)) ? "mixed" : "on";
    }
    return this.chosen.some((chosen) => same(parentOf(chosen), folder)) ? "mixed" : "off";
  },
  /// A folder and its subfolders: all of it, or none of it.
  setFolder(folder, on) {
    this.skipped = this.skipped.filter((skip) => !same(parentOf(skip), folder));
    this.chosen = this.chosen.filter((chosen) => !same(parentOf(chosen), folder));
    this.setSubfolder(folder, on);
  },
  setSubfolder(folder, on) {
    if (on) {
      this.skipped = this.skipped.filter((skip) => !same(skip, folder));
      if (!this.isSearched(folder)) this.chosen.push(folder);
    } else {
      this.chosen = this.chosen.filter((chosen) => !same(chosen, folder));
      if (this.isSearched(folder)) this.skipped.push(folder);
    }
  },
  /// What the indexer gets: the chosen folders, without those another one already searches whole.
  folders() {
    const all = unique(this.chosen);
    return all.filter((folder) => !all.some((other) => !same(other, folder) && inside(folder, other)
      && !this.skipped.some((skip) => inside(skip, other) && (same(folder, skip) || inside(folder, skip)))));
  },
  /// The skips that leave something out (inside a folder that's searched).
  skips() {
    const folders = this.folders();
    return unique(this.skipped).filter((skip) => folders.some((folder) => inside(skip, folder)));
  },
};

// MARK: Folders

const rows = [];                 // the folders listed, as the helper spells them
const estimates = new Map();     // key(folder) → the helper's estimate of it
const open = new Set();          // key(folder) of folders showing their subfolders
const showAll = new Set();       // … showing all of them
let calibrated = false;          // the times are this computer's (timed with the model, or measured by indexing)
let estimating = 0;

function addRow(path) {
  if (rows.some((row) => same(row, path))) return;
  rows.push(canon(path));
}

/// The helper's look at these folders (one answer per folder, with its subfolders), or again for all of them once
/// this computer has been timed.
async function estimate(paths) {
  if (!paths.length) return;
  estimating += 1;
  renderFolders();
  try {
    const answers = await invoke("estimate", { folders: paths.map(native), code: codeMode });
    for (const answer of answers) {
      estimates.set(key(answer.folder), answer);
      if (answer.readable !== false) calibrated = answer.calibrated !== false;
    }
    for (const path of paths) {
      if (!estimates.has(key(path))) estimates.set(key(path), { folder: path, failed: true, files: {}, seconds: 0 });
    }
  } catch {
    for (const path of paths) estimates.set(key(path), { folder: path, failed: true, files: {}, seconds: 0 });
  }
  estimating -= 1;
  renderFolders();
}

/// What a folder adds as checked now: all of it but its unchecked subfolders, or just its checked ones.
function partOf(row) {
  const answer = estimates.get(key(row));
  const part = { seconds: 0, later: 0, bytes: 0, files: {}, kinds: {} };
  if (!answer) return null;
  const add = (estimate, sign) => {
    part.seconds += sign * (estimate.seconds || 0);
    part.bytes += sign * (estimate.bytes || 0);
    part.later += sign * (estimate.later_seconds || 0);
    for (const [kind, count] of Object.entries(estimate.files || {})) part.files[kind] = (part.files[kind] || 0) + sign * count;
    for (const [kind, seconds] of Object.entries(estimate.kind_seconds || {})) {
      part.kinds[kind] = (part.kinds[kind] || 0) + sign * seconds;
    }
  };
  const subfolders = answer.subfolders || [];
  if (!selection.isSearched(row)) {
    for (const subfolder of subfolders) if (selection.isSearched(subfolder.folder)) add(subfolder, 1);
    return part;
  }
  // Inside another listed folder that searches it: counted there.
  if (rows.some((other) => !same(other, row) && inside(row, other) && selection.isSearched(other))) return part;
  add(answer, 1);
  for (const subfolder of subfolders) if (!selection.isSearched(subfolder.folder)) add(subfolder, -1);
  return part;
}

/// The whole selection: files and seconds by kind, and the first pass and the rest of long files.
function selectionPart() {
  const total = { seconds: 0, later: 0, bytes: 0, files: {}, kinds: {} };
  for (const row of rows) {
    const part = partOf(row);
    if (!part) continue;
    total.seconds += Math.max(0, part.seconds);
    total.bytes += Math.max(0, part.bytes);
    total.later += Math.max(0, part.later);
    for (const [kind, count] of Object.entries(part.files)) total.files[kind] = (total.files[kind] || 0) + Math.max(0, count);
    for (const [kind, seconds] of Object.entries(part.kinds)) total.kinds[kind] = (total.kinds[kind] || 0) + Math.max(0, seconds);
  }
  return total;
}

function renderFolders() {
  const list = $("folder-list");
  const scroll = list.closest("main").scrollTop;
  list.replaceChildren(...rows.map(folderBox));
  if (codeMode && !rows.length) list.append(element("p", "note", "No folders with code turned up in your home folder. Add "
                                                    + "the ones that hold your repositories."));
  list.closest("main").scrollTop = scroll;
  renderFooter();
}

function folderBox(row) {
  const answer = estimates.get(key(row));
  const mark = selection.mark(row);
  const subfolders = answer?.subfolders || [];
  const isOpen = open.has(key(row)) && subfolders.length > 0;
  const box = element("div", "folder-box" + (mark === "off" ? " off" : ""));
  const header = element("div", "folder");
  const disclosure = element("button", "disclosure" + (isOpen ? " open" : ""));
  disclosure.innerHTML = CHEVRON;
  disclosure.disabled = !subfolders.length;
  disclosure.title = isOpen ? "Hide its subfolders" : "Choose among its subfolders";
  disclosure.onclick = (event) => {
    event.stopPropagation();
    if (open.has(key(row))) open.delete(key(row)); else open.add(key(row));
    renderFolders();
  };
  const check = checkbox(mark, () => {
    selection.setFolder(row, mark !== "on");
    renderFolders();
  });
  const text = element("div", "text");
  text.append(element("div", "name", nameOf(row)));
  // Unchecked, a folder shows all it holds (what checking it would take); else what's searched of it.
  const part = mark === "off" ? wholePart(answer) : partOf(row);
  if (answer?.failed) text.append(element("div", "counts", "Couldn't look inside it; it can still be searched."));
  else if (answer?.readable === false) text.append(element("div", "counts problem", "Can't read it"));
  else if (part && Object.values(part.files).some((count) => count > 0)) text.append(element("div", "counts", countsText(part.files)));
  else text.append(element("div", "path", answer ? (Object.keys(answer.files || {}).length ? "Nothing to search in the subfolders checked" : codeMode ? "No code here" : "Nothing DigUp searches in it") : native(row)));
  header.append(disclosure, check, text);
  if (answer && !answer.failed && answer.readable !== false && calibrated) header.append(timeOf(part, mark === "off"));
  else if (!answer) header.append(element("div", "time", "…"));
  header.onclick = (event) => {
    if (event.target.closest("button, input")) return;
    selection.setFolder(row, mark !== "on");
    renderFolders();
  };
  box.append(header);
  if (isOpen) {
    const list = element("div", "subfolders");
    const all = showAll.has(key(row));
    for (const subfolder of all ? subfolders : subfolders.slice(0, SHORT_LIST)) list.append(subfolderRow(subfolder));
    if (!all && subfolders.length > SHORT_LIST) {
      const more = element("button", "more", `Show ${subfolders.length - SHORT_LIST} more`);
      more.onclick = () => { showAll.add(key(row)); renderFolders(); };
      list.append(more);
    }
    box.append(list);
  }
  return box;
}

function wholePart(answer) {
  return answer ? { seconds: answer.seconds || 0, later: answer.later_seconds || 0, bytes: answer.bytes || 0,
                    files: answer.files || {} } : null;
}

function subfolderRow(subfolder) {
  const on = selection.isSearched(subfolder.folder);
  const item = element("div", "subfolder" + (on ? "" : " off"));
  const toggle = () => {
    selection.setSubfolder(subfolder.folder, !on);
    renderFolders();
  };
  const counts = countsText(subfolder.files || {}) + (codeMode && subfolder.bytes ? ` · ${roughBytes(subfolder.bytes)}` : "");
  item.append(checkbox(on ? "on" : "off", toggle), element("span", "name", nameOf(subfolder.folder)),
              element("span", "counts", counts));
  if (calibrated) item.append(timeOf({ seconds: subfolder.seconds, later: subfolder.later_seconds }, !on, true));
  item.onclick = (event) => { if (!event.target.closest("input")) toggle(); };
  return item;
}

function checkbox(mark, action) {
  const box = document.createElement("input");
  box.type = "checkbox";
  box.checked = mark === "on";
  box.indeterminate = mark === "mixed";
  box.onclick = (event) => {
    event.preventDefault();   // the selection decides what it shows
    action();
  };
  return box;
}

/// "about 4 min" (and "+ 2 min later" for the rest of long files).
function timeOf(part, quiet, small) {
  const time = element("div", "time");
  const seconds = part?.seconds || 0;
  time.textContent = seconds < 1 ? (small ? "" : "—") : `about ${roughDuration(seconds)}`;
  if (codeMode) {
    if (!small && (part?.bytes || 0) > 0) time.append(element("small", "", roughBytes(part.bytes)));
    time.title = "How long reading this code takes, once, and about how much room its index needs. After that, only "
      + "what changes is read again.";
  } else {
    if (!small && (part?.later || 0) >= 30) time.append(element("small", "", `+ ${roughDuration(part.later)} later`));
    time.title = "How long the first pass takes on this computer. Long PDFs and documents get their first pages in it, "
      + "and the rest afterwards.";
  }
  if (quiet) time.classList.add("quiet");
  return time;
}

/// "1,204 pictures · 37 PDFs · 12 documents · 3 videos"
function countsText(files) {
  const part = (count, one, many) => (count > 0 ? `${count.toLocaleString()} ${count === 1 ? one : many}` : null);
  if (codeMode) return part(files.code, "file of code", "files of code") || "No code here";
  return [
    part((files.image || 0) + (files.screenshot || 0), "picture", "pictures"),
    part(files.pdf, "PDF", "PDFs"),
    part(files.doc, "document", "documents"),
    part(files.audio, "recording", "recordings"),
    part(files.video, "video", "videos"),
  ].filter(Boolean).join(" · ") || "Nothing DigUp searches in it";
}

/// "360 KB", "12 MB": an index's size, roughly.
function roughBytes(count) {
  if (count < 1e6) return `${Math.max(1, Math.round(count / 1e3))} KB`;
  if (count < 1e9) return `${Math.round(count / 1e6)} MB`;
  return `${(count / 1e9).toFixed(1)} GB`;
}

/// "45 s", "4 min", "1.5 h": the precision an estimate deserves (the Mac app's roughDuration).
function roughDuration(seconds) {
  if (seconds < 90) return `${Math.round(seconds)} s`;
  if (seconds < 5400) return `${Math.round(seconds / 60)} min`;
  return `${(seconds / 3600).toFixed(1)} h`;
}

$("add-folder").addEventListener("click", async () => {
  const picked = (await invoke("pick_folders")).map(canon);
  const added = [];
  for (const path of picked) {
    // A subfolder of a folder listed opens there, checked; any other folder is listed, checked.
    const listed = rows.find((row) => inside(path, row) && same(parentOf(path), row));
    if (listed) open.add(key(listed));
    else if (!rows.some((row) => same(row, path))) {
      addRow(path);
      added.push(path);
    }
    selection.setSubfolder(path, true);
  }
  renderFolders();
  estimate(added);
});

// MARK: The code step (a first launch that finds folders with code)

const codeChosen = new Set();
const codeEstimates = new Map();

function renderCode() {
  const list = $("code-list");
  list.replaceChildren(...info.codeOffered.map((folder) => {
    const on = codeChosen.has(folder);
    const box = element("div", "folder-box" + (on ? "" : " off"));
    const row = element("div", "folder");
    const toggle = () => {
      if (on) codeChosen.delete(folder); else codeChosen.add(folder);
      renderCode();
    };
    const text = element("div", "text");
    text.append(element("div", "name", nameOf(folder)));
    const answer = codeEstimates.get(key(folder));
    text.append(element("div", "counts", answer ? (answer.files?.code ? `${answer.files.code.toLocaleString()} files of code`
      : "No code here") : native(folder)));
    row.append(checkbox(on ? "on" : "off", toggle), text);
    if (answer?.files?.code) {
      const time = element("div", "time" + (on ? "" : " quiet"),
                           answer.seconds < 1 ? "under a second" : `about ${roughDuration(answer.seconds)}`);
      if (answer.bytes > 0) time.append(element("small", "", roughBytes(answer.bytes)));
      row.append(time);
    } else if (!answer) {
      row.append(element("div", "time", "…"));
    }
    row.onclick = (event) => { if (!event.target.closest("input")) toggle(); };
    box.append(row);
    return box;
  }));
  renderFooter();
}

async function estimateCode() {
  try {
    const answers = await invoke("estimate", { folders: info.codeOffered.map(native), code: true });
    for (const answer of answers) codeEstimates.set(key(answer.folder), answer);
  } catch {
    // The folders show without their times.
  }
  if (PAGES[page] === "code") renderCode();
}

// MARK: Pages

function render() {
  PAGES.forEach((name, index) => { $(name).hidden = index !== page; });
  $("back").hidden = firstTime ? page === 0 || page === PAGES.length - 1 : false;
  $("back").textContent = firstTime ? "Back" : "Cancel";
  $("next").textContent = !firstTime ? "Save" : page === PAGES.length - 1 ? "Done" : "Continue";
  $("next").disabled = page === 1 && !selection.folders().length;
  $("model").hidden = codeMode || page === 0 || page === PAGES.length - 1;
  renderFooter();
  if (PAGES[page] === "ready") renderProgress();
  if (PAGES[page] === "code") renderCode();
}

function renderFooter() {
  $("next").disabled = page === 1 && !selection.folders().length;
  let summary = "";
  if (PAGES[page] === "folders") {
    if (!selection.folders().length) summary = "Choose at least one folder";
    else if (estimating > 0 || rows.some((row) => selection.isSearched(row) && !estimates.has(key(row)))) summary = "Looking at your folders…";
    // Turning code search on: what reading the code takes, and its index.
    else if (codeMode && !info.chosen.length) {
      const total = selectionPart();
      summary = calibrated ? `About ${roughDuration(total.seconds)} to read, an index of about ${roughBytes(total.bytes)}` : "";
    }
    // Later (Choose Folders…) the folders searched already aren't read again: no first pass to tell.
    else if (!firstTime) summary = "";
    else if (calibrated) summary = `First pass: about ${roughDuration(selectionPart().seconds)}`;
    else summary = "Times show once DigUp has timed this computer";
  }
  if (PAGES[page] === "code") {
    const chosen = [...codeChosen].map((folder) => codeEstimates.get(key(folder))).filter(Boolean);
    const seconds = chosen.reduce((sum, answer) => sum + (answer.seconds || 0), 0);
    const size = chosen.reduce((sum, answer) => sum + (answer.bytes || 0), 0);
    summary = !codeChosen.size ? "Code search stays off for now"
      : `Reading the code: about ${roughDuration(Math.max(1, seconds))}, an index of about ${roughBytes(size)}`;
  }
  $("summary").textContent = summary;
}

$("next").addEventListener("click", async () => {
  const name = PAGES[page];
  if (name === "folders") {
    $("next").disabled = true;
    try {
      // Indexing starts now (once the model is in), while the rest of setup goes on.
      await invoke(codeMode ? "set_code_folders" : "apply_setup_folders",
                   { folders: selection.folders().map(native), skipped: selection.skips().map(native) });
    } catch (error) {
      $("summary").textContent = String(error);
      $("next").disabled = false;
      return;
    }
    if (!firstTime) {
      invoke("close_window").catch(() => {});
      return;
    }
  }
  if (name === "code") {
    const folders = [...codeChosen];
    if (folders.length) {
      $("next").disabled = true;
      try {
        await invoke("set_code_folders", { folders: folders.map(native), skipped: [] });
      } catch (error) {
        $("summary").textContent = String(error);
        $("next").disabled = false;
        return;
      }
    }
  }
  if (name === "ready") {
    $("next").disabled = true;
    try {
      await invoke("finish_setup");
    } catch (error) {
      $("progress-note").textContent = String(error);
      $("next").disabled = false;
    }
    return;
  }
  page += 1;
  render();
});

$("back").addEventListener("click", () => {
  if (!firstTime) {
    invoke("close_window").catch(() => {});
    return;
  }
  page = Math.max(0, page - 1);
  render();
});

/// Debug runs (--debug-setup): every offered folder, every page, then Done.
async function clickThrough() {
  while (page < PAGES.length - 1) {
    $("next").click();
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  $("next").click();
}

// MARK: The last step: the download, then indexing, as it goes

const progress = {
  state: {},                 // the shell's snapshot (status.rs)
  model: { state: "checking" },
  samples: [],               // the download: [time, bytes], the last few seconds of them
  pass: null,                // this indexing pass: {start, done: {kind: n}, total, doneFiles}
  rest: null,                // the rest of long files: {done, total, files}
};

function renderProgress() {
  const { state, model } = progress;
  const what = $("progress-what"), left = $("progress-left"), bar = $("bar"), fill = $("bar-fill");
  let fraction = null, busy = false, done = false, label = "", time = "", note = "";
  if (model.state === "downloading") {
    label = "Downloading the model";
    fraction = model.total ? model.bytes / model.total : 0;
    const rate = downloadRate();
    time = `${Math.floor(fraction * 100)}%` + (rate > 0 && model.total ? ` · about ${roughDuration((model.total - model.bytes) / rate)} left` : "");
    note = "865 MB, once. DigUp starts reading your files when it's in; until then, search finds files by name.";
    if (model.problem) note = `${model.problem}; trying again.`;
  } else if (model.state === "waiting") {
    label = "Waiting for the network to download the model";
    busy = true;
  } else if (model.state === "failed") {
    label = "The model couldn't download";
    note = model.message || "";
  } else if (state.measuring) {
    label = "Checking this computer's speed";
    busy = true;
    note = "DigUp times its model on this computer once, to tell how long indexing takes here.";
  } else if (state.activity === "indexing" && state.indexing) {
    const { done: count, total } = state.indexing;
    label = "Reading your files";
    fraction = total ? count / total : 0;
    const seconds = timeLeft();
    time = `${count.toLocaleString()} of ${total.toLocaleString()}` + (seconds != null ? ` · ${leftText(seconds)}` : "");
    note = "You can search right away: results fill in as DigUp reads your files, newest first.";
  } else if (state.activity === "finishing" && progress.rest) {
    const { done: count, total, files } = progress.rest;
    label = `Reading the rest of ${files.toLocaleString()} long ${files === 1 ? "file" : "files"}`;
    fraction = total ? count / total : 0;
    const later = selectionPart().later, pace = progress.pace || 1;
    time = `${Math.floor(fraction * 100)}%` + (later > 0 ? ` · ${leftText(later * (1 - fraction) * pace)}` : "");
    note = "Everything is searchable; long PDFs and documents are being read past their first pages.";
  } else if (state.activity === "idle" || (state.activity === "starting" && state.searchable > 0 && !state.pending)) {
    label = state.searchable ? `${state.searchable.toLocaleString()} ${state.searchable === 1 ? "file" : "files"} indexed` : "Up to date";
    done = true;
    note = "Search from the window, or press the shortcut in any app.";
  } else if (state.activity === "failed") {
    label = state.line || "Indexing stopped";
  } else {
    label = "Looking at your folders";
    busy = true;
  }
  what.textContent = label;
  left.textContent = time;
  bar.className = "bar" + (busy ? " busy" : "") + (done ? " done" : "");
  fill.style.width = busy || done ? "" : `${Math.round(100 * Math.max(0, Math.min(1, fraction ?? 0)))}%`;
  $("progress-note").textContent = note;
}

/// The download's bytes a second over the last few seconds.
function downloadRate() {
  const samples = progress.samples;
  if (samples.length < 2) return 0;
  const [firstTime, firstBytes] = samples[0], [lastTime, lastBytes] = samples[samples.length - 1];
  return lastTime > firstTime ? (lastBytes - firstBytes) / ((lastTime - firstTime) / 1000) : 0;
}

/// Seconds left in this pass: what's still to come of each kind, at its estimated cost, at the pace this computer
/// has kept so far (the estimate's times are this computer's once it's timed; the pace corrects the rest).
function timeLeft() {
  const pass = progress.pass, state = progress.state;
  if (!pass || !state.indexing) return null;
  const part = selectionPart();
  let remaining = 0, doneWork = 0, remainingFiles = 0;
  for (const [kind, files] of Object.entries(part.files)) {
    const perFile = files > 0 ? (part.kinds[kind] || 0) / files : 0;
    const done = pass.done[kind] || 0;
    remaining += Math.max(0, files - done) * perFile;
    remainingFiles += Math.max(0, files - done);
    doneWork += Math.min(done, files) * perFile;
  }
  // The pass's own count of what's left (some files aren't read: too small, or skipped) scales what's still to come.
  const left = Math.max(0, state.indexing.total - state.indexing.done);
  if (remainingFiles > 0) remaining *= left / remainingFiles;
  const elapsed = (Date.now() - pass.start) / 1000;
  const sure = doneWork >= 3 || elapsed >= 15;
  if (sure && doneWork > 0) progress.pace = Math.max(0.05, Math.min(500, elapsed / doneWork));
  if (!sure && !calibrated) return null;
  return remaining * (sure ? progress.pace : 1);
}

function leftText(seconds) {
  return seconds < 60 ? "less than a minute left" : `about ${roughDuration(seconds)} left`;
}

tauri.event.listen("state", ({ payload }) => {
  progress.state = payload;
  if (PAGES[page] === "ready") renderProgress();
});

tauri.event.listen("helper", ({ payload }) => {
  const { from, event } = payload;
  if (from !== "index" || event.code) return;
  if (event.event === "sync" && event.new > 0) {
    progress.pass = { start: Date.now(), done: {}, doneFiles: 0 };
  } else if (event.event === "file") {
    // A pass starts over when its count does (the backfill after new files, a later sync).
    if (!progress.pass || event.done < progress.pass.doneFiles) progress.pass = { start: Date.now(), done: {}, doneFiles: 0 };
    progress.pass.done[event.kind] = (progress.pass.done[event.kind] || 0) + 1;
    progress.pass.doneFiles = event.done;
  } else if (event.event === "rest") {
    progress.rest = { done: event.done, total: event.total, files: event.files };
  }
});

// The model for the footer, and the download's pace.
function showModel(model) {
  progress.model = model;
  if (model.state === "downloading" && model.bytes != null) {
    progress.samples.push([Date.now(), model.bytes]);
    while (progress.samples.length > 2 && Date.now() - progress.samples[0][0] > 8000) progress.samples.shift();
  }
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
  if (PAGES[page] === "ready") renderProgress();
}

// This computer was timed: the folders' times are its own now.
tauri.event.listen("speed", () => {
  if (rows.length) estimate([...rows]);
});

// MARK: The shortcut

function showKeys(hotkey) {
  const keys = isMac ? [...hotkey.replace(/[^⌃⌥⇧⌘]/g, "")].concat(hotkey.replace(/[⌃⌥⇧⌘]/g, "")) : hotkey.split("+");
  $("keys").replaceChildren(...keys.filter(Boolean).map((key) => element("span", "key", key)));
  $("reveal-key").textContent = isMac ? "⌘↩" : "Ctrl+↩";
  $("reveal-text").textContent = isMac ? "shows it in Finder" : isWindows ? "shows it in Explorer" : "shows it in its folder";
}

/// Where the shortcut lives on a desktop that keeps it itself (GNOME, KDE), or the command to give it (other Wayland
/// desktops).
function showShortcut(shortcut) {
  const notes = {
    gnome: "DigUp adds it to GNOME's keyboard shortcuts. To change it later: Settings → Keyboard → View and Customize " +
      "Shortcuts → Custom Shortcuts.",
    kde: "DigUp adds it to KDE's shortcuts. To change it later: System Settings → Shortcuts → DigUp.",
    by_hand: "This desktop doesn't let apps set their own shortcuts. To open the panel with one, add a shortcut in " +
      "its keyboard settings that runs:",
  };
  const note = notes[shortcut?.method];
  $("shortcut-note").hidden = !note;
  $("shortcut-note").textContent = note || "";
  $("shortcut-command").hidden = shortcut?.method !== "by_hand";
  $("shortcut-command").textContent = shortcut?.command || "";
  $("change-shortcut").hidden = shortcut?.method !== "grab";
}

// Where DigUp grabs the shortcut itself (Windows, X11), it can be changed here (shortcut.js).
$("change-shortcut").addEventListener("click", () => {
  $("change-shortcut").hidden = true;
  $("recording").hidden = false;
  recordShortcut((text) => { $("recording").textContent = text; }, (shown, problem) => {
    if (shown) showKeys(shown);
    $("recording").textContent = problem || "";
    $("recording").hidden = !problem;
    $("change-shortcut").hidden = false;
  });
});

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

async function start() {
  info = await invoke(codeMode ? "code_setup_info" : "setup_info");
  firstTime = !info.setUp;
  if (firstTime && info.codeOffered?.length) {
    PAGES = ["welcome", "folders", "code", "shortcut", "ready"];
    estimateCode();
  }
  if (codeMode) {
    $("folders").querySelector("h2").textContent = "Which code should DigUp search?";
    $("folders-subtitle").textContent = "Pick the folders with your code, and open one to leave out some of its "
      + "repositories. DigUp reads what git keeps (not dependencies or build output) into an index of its own, so "
      + "code shows up only when you search for code.";
  }
  progress.state = info.state || {};
  // The usual folders, then any chosen before (a chosen subfolder of a folder listed shows inside it). On a first
  // launch they start checked, all but Downloads (much of what lands there is passing through).
  for (const path of info.offered) addRow(path);
  for (const path of info.chosen) if (!rows.some((row) => same(row, path) || same(row, parentOf(path)))) addRow(path);
  if (firstTime && !info.chosen.length) {
    selection.chosen = info.offered.filter((path) => info.auto || !/[\\/]Downloads$/i.test(path)).map(canon);
  } else {
    selection.chosen = info.chosen.map(canon);
    selection.skipped = (info.skipped || []).map(canon);
  }
  // A folder with some of its subfolders chosen or skipped starts open, so it shows which.
  for (const row of rows) {
    if ([...selection.chosen, ...selection.skipped].some((path) => same(parentOf(path), row))) open.add(key(row));
  }
  estimate([...rows]);
  if (!codeMode) {
    showModel(info.model);
    tauri.event.listen("model", ({ payload }) => showModel(payload));
    showKeys(info.hotkey);
    showShortcut(info.shortcut);
  }
  if (!firstTime) page = 1;   // Choose Folders…: the folders, with Save
  const asked = PAGES.indexOf(new URLSearchParams(location.search).get("page"));   // dev snapshots: ?page=folders
  if (asked >= 0) page = asked;
  render();
  // The time left changes between events.
  setInterval(() => { if (PAGES[page] === "ready") renderProgress(); }, 1000);
  if (info.auto) setTimeout(clickThrough, 500);
}

start();
