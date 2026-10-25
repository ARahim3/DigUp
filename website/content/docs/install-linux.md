+++
title = "Install on Linux"
description = "Install the DigUp beta from the .deb on Ubuntu, Debian and Mint, or run the AppImage anywhere else."
section = "Get started"
order = 3
platforms = ["linux"]
+++

DigUp for Linux is a beta. The search is the same as on the Mac, with the same model and the same results; it has had less use, so expect some rough edges and please [report them](/docs/report-a-bug/).

## What you need

DigUp needs a 64-bit Intel or AMD processor. The .deb works on Ubuntu 22.04, Debian 12, Mint 21 and newer; the AppImage runs on most other distributions. Plan for about 1 GB of free space for the model and the app.

## Install

:::: tabs
::: tab .deb
Download the .deb from the [download page](/download/#linux) and install it with apt:

```sh
sudo apt install ./DigUp_x.y.z_amd64.deb
```

The package is called `dig-up`, because Debian already has an unrelated `digup`. When DigUp finds a new version, it opens the release page; install the new .deb over the old one.
:::
::: tab AppImage
Download the AppImage from the [download page](/download/#linux), make it executable and run it:

```sh
chmod +x DigUp_x.y.z_amd64.AppImage
./DigUp_x.y.z_amd64.AppImage
```

The AppImage updates itself with one click. It's larger than the .deb because it carries the media libraries its preview needs.
:::
::::

Then setup starts; see [First launch](/docs/first-launch/).

## The shortcut on Wayland

GNOME and KDE under Wayland don't let apps set their own global shortcuts. During setup, DigUp adds <kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>Space</kbd> to the desktop's own keyboard settings, so you change it there: Settings → Keyboard → Keyboard Shortcuts on GNOME, System Settings → Shortcuts on KDE. On other Wayland desktops, Settings shows the command to bind to a shortcut of your own: DigUp's path followed by `--toggle`. On X11, DigUp sets the shortcut itself.

## The tray

DigUp lives in the tray. On GNOME the tray needs the AppIndicator extension, which Ubuntu includes; without it, the window's ⋯ menu has the same items. On a desktop without a tray at all, like Hyprland without a bar, use the window.

## Graphics card or processor

During setup, DigUp times the model on your graphics card (with Vulkan) and on the processor, and uses the card only if it's faster and gives the same results. If searches come back empty or wrong, turn on Settings → General → **Run the model on the processor**. The last line of `speed.log`, in `{{ site.paths.linux_logs }}`, says which one DigUp picked; a report of what it found on your card helps, since few Linux graphics cards have been tried.

## Not yet on Linux

The text inside screenshots isn't read yet (a screenshot is found by what it shows), and old .doc files, RAW photos and SVG pictures are skipped. A PDF viewer or a video player installed as a Flatpak can't be told the page or the moment, so it opens the file from the start; see [Opening results](/docs/opening-results/).
