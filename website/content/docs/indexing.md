+++
title = "Indexing"
description = "The first pass, how DigUp keeps up after it, and how to pause it, keep it off battery, or keep it to set hours."
section = "Your files"
order = 3
+++

## The first pass

When you add folders, DigUp reads them once: every picture, page, passage, frame and stretch of sound becomes a place in its index. It reads the newest files first, so recent ones are searchable within minutes, and it reads long PDFs and documents to the end only after everything else is in.

How long it takes depends on what's there and on your computer. On a Mac, a few hundred files take a few minutes and a big Downloads folder about an hour. On Windows and Linux the model runs on the graphics card when that's faster; on a processor alone a picture takes a few seconds, so a large photo library can take hours. Setup and Add Folders show the estimate for each folder before anything runs, measured on your computer, and the estimates get better as DigUp learns how long each kind of file takes there.

## Following along

The menu bar icon on a Mac, or the tray icon on Windows and Linux, shows how it's going: the tiles of the logo fill with color as indexing proceeds, and two bars show when it's paused. Its menu has a status line, like "Indexing · 42%" or "Reading the rest of 3 long files"; on Windows and Linux, "Checking folders…" shows while DigUp walks your folders before reading them. Settings → Folders shows each folder's count.

## Pausing

Pause and Resume are in the menu. Quit stops indexing too, even in the middle of a file; DigUp picks up where it left off next time.

## Battery and schedule

On a Mac, Index on battery power is on by default. Turn it off in Settings → Folders and a folder's first pass waits for a charger. Low Power Mode and a hot Mac make the first pass wait either way, and up to 50 new files always go in at once.

Index only at set hours, in Settings → Folders, keeps reading to the hours you choose (1:00 to 7:00 by default). Search works all day, and what changed in between is picked up when the hours begin.

## After the first pass

DigUp watches the folders you chose. When something changes, it waits a moment for things to settle, compares sizes and dates, and reads only what's new or changed. A new screenshot is searchable about a second after it lands. There's no periodic rescan of your disk. On a Mac, changes DigUp wouldn't index, like a database or a log being rewritten, are ignored.

The model runs in a helper process that quits when it's done. The app itself stays small, about {{ site.numbers.idle_mac }} of memory on a Mac while idle; during the first pass, the helper uses up to about 2 GB.

## When the model changes

The index remembers which model made its vectors. If an update ever changes them, DigUp reads everything again by itself, and the release notes say so. An update that leaves the vectors the same keeps your index.
