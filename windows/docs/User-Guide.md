# DigUp for Windows — User Guide

DigUp finds your files by what is in them. Describe what you look for
in your own words. It finds photos, screenshots, PDFs, documents,
recordings, videos, and (if you turn it on) code.

Some words used here, said once in plain language:

- **Index** — a private list DigUp keeps of what is in your files, so
  search is fast. It lives on your PC only.
- **Embedding** — a list of 768 numbers that stands for the meaning of
  a picture, page, or sound clip. Files with close meanings have close
  numbers. The model that makes them is EmbeddingGemma 2.
- **Tray** — the small icons by the clock (bottom right). DigUp lives there.
- **Hotkey** — keys you press anywhere to open search
  (default: Ctrl+Alt+Space).

## Install

1. Run the DigUp installer (per user, no admin password needed).
2. Open DigUp from Start. A one-time setup asks for folders, code
   on/off, then downloads the model once (865 MB) with a progress bar.
3. Press **Ctrl+Alt+Space** in any app and describe what you look for.

A dimmed, blurred screen with a search card opens in front of everything.
Results show a preview: pictures and video frames as thumbnails, words
for documents and code. Enter opens, Esc closes.

DigUp needs Windows 10 22H2 or Windows 11, and works on Intel, AMD,
and Snapdragon PCs (NVIDIA cards are fastest, others use CPU).

## Daily use

| Keys | What happens |
|---|---|
| Ctrl+Alt+Space | Open search from any app (change it in settings) |
| Down / Up | Move through results |
| Enter | Open it: videos and sound at the moment, PDFs at the page, code at the line |
| Space | Preview the selected file itself: pictures full-size, PDFs at the page, videos and sound playing from the moment, code around the lines (same as the Mac: arrows, then Space; Space in the search box still types) |
| Ctrl+O | Same search, bigger window |
| Ctrl+C | Copy the file, to paste anywhere |
| Esc | Hide the panel |

DigUp sits in the tray. Right-click it to pause indexing, pick folders,
or quit. New files are searchable seconds after they land.

## Code search (off until you turn it on)

Turn it on in settings for the folders you pick. Then start a search
with `code:` and say what the code does, or type a name from the code:

- `code: retry a failed call with backoff` finds the function.
- `code: refreshAccessToken` goes to the line that defines it.

Results open in your editor at the line (VS Code, Cursor, Visual
Studio, JetBrains, Sublime, Notepad++). Code never shows in other searches.

## What it reads (only folders you choose)

- Pictures and screenshots (by what they show; screenshots also by text).
- PDFs, page by page (long ones: first 30 pages fast, rest later).
- Documents: txt, md, html and more. Number-heavy exports match by exact text.
- Sound of any length, in 30-second windows. A match points at its moment.
- Video of any length: one picture per shot plus the soundtrack.
- Code, only where you turned it on.

It never reads keys, passwords, hidden folders, app data, or files that
only live in the cloud (OneDrive placeholders are skipped, never
downloaded). It only reads. It never changes, moves, or uploads files.

## Updates and privacy

- Nothing you index leaves your PC. DigUp goes online only to fetch the
  model once and to check for updates once a day (no file data sent).
  You can turn the check off.
- Updates are small (**deltas**: only what changed is downloaded).

## Remove it

Quit (tray → Quit), uninstall from Settings → Apps. Your index and the
model are removed only if you tick "remove my data". Settings live in
`C:\Users\<you>\AppData\Local\DigUp\`.

## If something looks wrong

- **Indexing stopped and starts again later**: normal. DigUp remembers
  what is done and goes on with the rest (even after a restart or a
  power cut). Only new or changed files are read again.
- **A file says "failed"**: DigUp skips it and indexes everything else.
  A file that crashes the helper three times is left out, with the
  reason shown. Change the file and it is tried again.
- **Search shows an error**: try again; if it stays, the details are in
  `C:\Users\<you>\AppData\Local\DigUp\error.log` — send that file with
  the bug report.

## Limits (same as Mac)

- Screenshot text reading knows common languages best; Bengali, Arabic
  and 100+ languages still match by meaning across languages.
- Chinese, Japanese and Thai are not split into words (exact-word match
  is weaker there; meaning still works).
- First pass is heavy once (minutes for hundreds of files, measured
  ~10 files a second on a fast PC; CPU and GPU spike, then rest). After
  that, only new files are read. The model runs in a helper that quits
  when done. The app idles around 115 MB.
