+++
title = "Command line"
description = "The digup program inside the app: search the app's index from a terminal, or get results as JSON for scripts."
section = "Reference"
order = 3
+++

The helper DigUp uses to index and to search is also a command-line program, `digup`. It ships inside the app, so there's nothing more to install.

On a Mac it's `{{ site.paths.mac_cli }}`. The Windows and Linux apps carry the same program in their helper folder (with the .deb, `{{ site.paths.linux_cli }}`), though it has had less use from a terminal there.

## Search

```sh
digup search "payment declined error"
digup search "a dog on the beach" --kind image,video -n 5
digup search "code: retry a failed call with backoff"
digup search "invoice 2047" --json
```

It searches the app's own index, the same one the panel uses. `--json` prints the results for scripts and other tools, `--kind` limits them to kinds (screenshot, image, pdf, doc, audio, video), and `-n` sets how many. Each search loads the text part of the model first, so the first result takes about half a second.

## Other commands

- `digup status` says what's in the index.
- `digup estimate <folder>` says what would be read in a folder and how long its first pass would take, without reading it.
- `digup --help` lists everything, including the commands the app itself uses.

`search`, `status` and `estimate` are safe to run while the app runs. Don't run `digup index` on the app's own index, since the app's helper writes to it too; give it another folder with `--index` instead.

## The index file

The index is a plain SQLite file in DigUp's data folder ([where it is](/docs/uninstall/)). You can open it read-only with any SQLite tool, and keyword search works straight from it, since it's SQLite's full-text search. Searching by meaning needs the model, which is what `digup search` adds.
