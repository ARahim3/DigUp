+++
title = "Choosing folders"
description = "Which folders DigUp reads, what it leaves out inside them, and how to see and change what isn't read."
section = "Your files"
order = 1
+++

DigUp reads only the folders you choose. You choose them during setup and change them any time in Settings → Folders.

## Adding folders

Add Folders… lists your usual folders that aren't searched yet, each with how many files of each kind it holds and how long its first pass will take, and lets you pick any other folder, an external drive included. Each folder opens to its subfolders, so you can take a whole folder or only some of it.

A folder you choose is read whole, whatever it holds. Even if it's a git repository or looks like a project, its pictures, documents, recordings and videos are read.

## What's left out inside a folder

Inside the folders you choose, DigUp skips what's rarely yours to search:

- hidden folders, like `.ssh` and `.git`, and app bundles and packages
- developer folders: `node_modules`, `venv`, `site-packages`, `__pycache__`, `DerivedData`, `Pods`, `Carthage`, and folders with a `CACHEDIR.TAG` (pip, cargo and ccache caches)
- `~/Library` on a Mac, and folders ending in `.noindex`
- code projects, folders with a `.git`, `package.json`, `pyproject.toml`, `requirements.txt` and the like: only their screenshots are read. Code itself is read only by [code search](/docs/code-search/), in the folders you pick for it.
- folders that look like datasets: hundreds of machine-named files of one kind, like training data
- files that only live in the cloud (see below)

To include something from a part that's skipped, add that folder itself as a folder to search: a folder you choose is always read whole.

## Skipping more

Settings → Folders has Skip a Folder… for folders inside the ones you search, and Skip these file types for extensions, like `heic, txt`. Removing or skipping a folder takes its files out of the index right away; your files themselves are never touched.

## Seeing what wasn't read

Next to each folder, Settings → Folders says how many files are indexed and how many weren't read. Click "N not read" to see why: inside code projects, only in the cloud, types DigUp doesn't read, folders that look like datasets, or, on a Mac, a Photos library.

## Cloud folders

iCloud Drive, OneDrive and Google Drive folders are read like any other folder, but only the files that are on your computer. Files that only live in the cloud are never downloaded to be read. To include them, make them available offline in that service's app ("Keep Downloaded" in iCloud Drive, "Always keep on this device" in OneDrive).

## External and network drives

An external drive can be chosen like any folder. When it's not connected, DigUp keeps what it knows about it and catches up when it's back. Network drives can be chosen too, but they've had little testing.

## The Photos library

On a Mac, the Photos library is a package DigUp doesn't open, so the pictures inside it aren't read. Photos exported to a folder are read like any other pictures.
