+++
title = "Searching"
description = "The search panel, its keys, the bigger search window, and what each result tells you."
section = "Search"
order = 1
+++

## The search panel

Press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>Space</kbd> on a Mac, or <kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>Space</kbd> on Windows and Linux, in any app. Describe what you're looking for, and results come as you type: on the left grouped by kind, on the right the one you've selected, big.

<figure><img src="/assets/img/shots/mac-video-moment.jpg" alt="DigUp's search panel on a Mac: the search 'zebra in a video', a video selected on the left, and on the right its frame at 0:42 with the line 'Matches the frame at 0:42'" width="1600" height="818" loading="lazy"><figcaption>The panel on a Mac, with the moment a video matched.</figcaption></figure>

The preview shows the part that matched: the video frame at the moment, the page of a PDF with your words marked, the passage of a document, the picture or the screenshot. A recording plays from the moment, right in the preview. Under it, a line says why the result is there: "Matches the frame at 0:42", "Matches what's heard at 7:55", "Matches the text on page 4", or "Has your words" when it's the exact words that matched.

Results well below the best one fold under "N weaker matches" at the end of the list, so the panel shows what stood out. Open the fold to see them.

## Keys

| Mac | Windows and Linux | What it does |
|---|---|---|
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>Space</kbd> | <kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>Space</kbd> | Opens the panel from any app |
| <kbd>↓</kbd> <kbd>↑</kbd> | <kbd>↓</kbd> <kbd>↑</kbd> | Moves through the results |
| <kbd>↩</kbd> | <kbd>Enter</kbd> | Opens the result: recordings and videos at the moment, code at the line, PDFs at the page where the app allows ([Opening results](/docs/opening-results/)) |
| <kbd>Space</kbd> | <kbd>Space</kbd> | A big preview at the page or moment, once you've moved to a result |
| <kbd>⌘</kbd><kbd>↩</kbd> | <kbd>Ctrl</kbd><kbd>Enter</kbd> | Shows it in Finder, Explorer or your file manager |
| <kbd>⌘</kbd><kbd>C</kbd> | <kbd>Ctrl</kbd><kbd>C</kbd> (in the window) | Copies the file, to paste anywhere |
| <kbd>⌘</kbd><kbd>O</kbd> | <kbd>Ctrl</kbd><kbd>O</kbd> | The same search in the bigger window |
| <kbd>Esc</kbd> | <kbd>Esc</kbd> | Closes the panel |

You can change the shortcut in Settings → General. On GNOME and KDE under Wayland it lives in the desktop's keyboard settings instead; see [Install on Linux](/docs/install-linux/#the-shortcut-on-wayland).

## The search window

<kbd>⌘</kbd><kbd>O</kbd> (or <kbd>Ctrl</kbd><kbd>O</kbd>) opens the same search in a window. It has filters by kind (All, Screenshots, Images, Docs, Video, Audio, and Code when [code search](/docs/code-search/) is on), a grid for pictures and screenshots, and the same preview. Opening DigUp from Applications, the Start menu or your app list shows this window too.

## While the first pass runs

You can search from the start. File names are searchable at once, and the newest files are read first, so recent ones turn up before old ones. The menu bar or tray icon shows how far along indexing is; until it's done, a result you expect may simply not be read yet.

## Results that look wrong

If a file you know is there doesn't come up, it may be in a part of a folder DigUp doesn't read, or of a kind it doesn't read. Settings → Folders shows "N not read" next to each folder, with the reasons. [Troubleshooting](/docs/troubleshooting/#indexing) covers the usual causes.
