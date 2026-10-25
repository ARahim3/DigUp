+++
title = "Updates and versions"
description = "How DigUp updates itself on each system, what a beta is, and how one version line covers the Mac, Windows and Linux."
section = "Reference"
order = 2
+++

## How updates arrive

Once a day, DigUp checks GitHub for a newer version. The check asks for one small file and sends nothing about your files; you can turn it off in Settings → General, and Check Now checks whenever you like.

A new version waits quietly instead of interrupting you: a dot on the menu bar icon and a line in the window on a Mac; "Update to DigUp x.y.z…" in the tray menu, a dot on the tray icon and a line in the window on Windows and Linux. Choosing it shows what changed, then installs and restarts.

| | How it updates |
|---|---|
| Mac | One click, in the app |
| Windows | One click, in the app |
| Linux, AppImage | One click, in the app |
| Linux, .deb | DigUp opens the release page; install the new .deb over the old one |
| Homebrew | Through the app; `brew upgrade` leaves it alone |

Updates are signed. An installed DigUp checks the signature and refuses an update that isn't signed with the project's key.

## Versions

One version line covers every system. A number names one state of the code, and a release carries only the systems that changed, so the others skip that number. That's why the Mac can be at 0.6.2 while Windows and Linux are at 0.7.0-beta.3. Each system's update feed lists only its own releases, so nobody downloads an update that changes nothing for them.

The last part of a version goes up for fixes, the middle part for new features. A system that isn't stable yet gets `-beta.N`.

## Betas

Windows and Linux are in beta: the search works as on the Mac, but it has had less use, so expect some rough edges. A beta updates to the next beta by itself, and to the stable version when it comes. When Windows and Linux are stable, one release will carry all three systems.

## What changed

The [changelog](/changelog/) lists every release with its notes, and has a [feed](/changelog/feed.xml) to follow.
