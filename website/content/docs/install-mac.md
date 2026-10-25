+++
title = "Install on Mac"
description = "Download DigUp for an Apple Silicon Mac, or install it with Homebrew."
section = "Get started"
order = 1
platforms = ["mac"]
+++

## What you need

DigUp needs {{ site.requirements.mac }}. Intel Macs aren't supported. You'll also need about 1 GB of free space for the model and the app, plus room for the index, which is small for pictures and grows with the text in your documents ([how big it gets](/docs/faq/#index-size)).

## Download

::: steps
1. Download the DMG from the [download page](/download/#mac).
2. Open it and drag DigUp to Applications.
3. Open DigUp from Applications. Setup starts; see [First launch](/docs/first-launch/).
:::

The app is signed with a Developer ID and notarized by Apple, so macOS opens it without a warning.

## Or with Homebrew

```sh
{{ site.homebrew }}
```

The cask lives in the [arahim3/tap]({{ site.homebrew_tap }}) tap and follows each release. Once installed, DigUp updates itself, so `brew upgrade` leaves it alone. `brew uninstall --cask --zap digup` removes the app, the model and the index.

## What macOS asks

DigUp asks for nothing at install. Later, macOS may ask:

- once for each protected folder you choose, like Desktop, Documents and Downloads, whether DigUp may read it. Choose Allow, or DigUp sees those folders as empty.
- once, the first time you open a video at its moment, whether DigUp may control QuickTime Player. It uses that only to start the video at the moment that matched.

You can change both later in System Settings → Privacy & Security, under Files and Folders and under Automation.

## On a Mac

The model runs on the Mac's GPU with Metal. Screenshots and scanned PDF pages are also searchable by their text, read with Apple's text recognition, and a few formats are read only on a Mac: old Word .doc files, RAW photos and SVG pictures. DigUp lives in the menu bar; the Dock icon shows only while one of its windows is open.

::: tip Next
[First launch](/docs/first-launch/) walks through setup, and [Searching](/docs/searching/) through the panel.
:::
