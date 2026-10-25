+++
title = "Settings"
description = "Every setting in DigUp, tab by tab, on the Mac and on Windows and Linux."
section = "Reference"
order = 1
+++

Open Settings from the menu bar or tray menu, or with <kbd>⌘</kbd><kbd>,</kbd> in a DigUp window on a Mac. The Mac's Settings has four tabs: General, Folders, Code and Storage. On Windows and Linux there are three, with code search on the Folders tab.

## General

Search shortcut
: The keys that open the search panel from any app. Click to record others; DigUp refuses keys the system already uses, and says why. On GNOME and KDE under Wayland, the shortcut is set in the desktop's keyboard settings instead.

Open DigUp when you log in
: Keeps DigUp in the menu bar or tray from the start, so the shortcut always works.

Check for updates automatically
: Once a day DigUp asks GitHub for its newest version; nothing about your files is sent. Check Now checks right away. See [Updates and versions](/docs/updates/).

Clicking DigUp's tray icon (Windows and Linux)
: Opens the window, or shows the search panel. A right-click opens the menu either way.

Center the search panel (Linux, on desktops that place windows themselves)
: On these desktops the panel opens where the desktop puts new windows. Centered, it opens where it does on a Mac, but DigUp then keeps a transparent window over the whole screen, which costs about 50 MB more memory on a 1080p screen, so it's a choice.

Run the model on the processor (Windows and Linux)
: For a computer whose graphics card gives empty or wrong results. Slower, and the same results as on a Mac.

## Folders

Folders to search
: Each folder with its counts by kind, how many files are indexed, and "N not read" with the reasons. Removing a folder takes its files out of the index right away. Pause stops indexing until you resume.

Add Folders…
: Your usual folders that aren't searched yet, with estimates and one level of subfolders, plus any folder you choose.

Skip these folders
: Folders inside the ones you search that stay out. Code projects, app bundles and caches are skipped anyway.

Skip these file types
: Extensions to leave out, like `heic, txt`.

Index on battery power (Mac)
: On by default. When it's off, a folder's first pass waits for a charger; new files always go in right away.

Index only at set hours
: Files are read only between the times you set (1:00 to 7:00 by default), and what changed in between is picked up when they begin. Search works all day.

## Code

On a Mac this is its own tab; on Windows and Linux it's part of the Folders tab. See [Code search](/docs/code-search/).

Code folders
: The folders that hold your repositories, each with how long reading it takes and how much room its index needs. Add Folders… adds more.

Skip these folders (Mac)
: Folders inside your code folders that stay out of code search.

Open code in
: The editor results open in, at the line that matched.

Turn Off Code Search
: Deletes the code index. Turning it on again reads the code again.

## Storage

Model
: {{ site.model.name }} by {{ site.model.by }}, {{ site.model.license }}, {{ site.model.download }}: whether it's downloaded, and where it is. On a Mac, Use Files… takes the two files from somewhere else, for a network that blocks Hugging Face, and Copy Links copies their addresses.

Index
: Its size on disk (and the code index's), and where it is.

Privacy
: What DigUp reads and when it goes online.

Licenses (Windows and Linux)
: The notices of the open-source parts the app carries.
