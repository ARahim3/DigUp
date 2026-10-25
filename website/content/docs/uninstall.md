+++
title = "Uninstall"
description = "How to remove DigUp from each system, with the model, the index and the settings."
section = "Reference"
order = 4
+++

DigUp keeps its model, its index and its settings in a few known places, so removing it leaves nothing behind.

:::: tabs
::: tab Mac
Quit DigUp from its menu, then:

1. Delete DigUp from Applications.
2. Delete `{{ site.paths.mac_data }}`, which holds the model and the indexes.
3. Delete `{{ site.paths.mac_settings }}`, its settings.

With Homebrew, this does all three:

```sh
brew uninstall --cask --zap digup
```
:::
::: tab Windows
Uninstall DigUp in Settings → Apps → Installed apps. Tick "Delete the application data" to remove the model and the index too.

By hand, they're in `{{ site.paths.windows_data }}` (the model and the index) and `{{ site.paths.windows_app }}` (settings and logs).
:::
::: tab Linux
Remove the package, or delete the AppImage:

```sh
sudo apt remove dig-up
```

Then delete:

- `{{ site.paths.linux_data }}`, the model and the index
- `{{ site.paths.linux_config }}` and `{{ site.paths.linux_app }}`, settings and logs
- `{{ site.paths.linux_autostart }}`, if DigUp opened at login

On GNOME, also remove DigUp's shortcut in Settings → Keyboard → Keyboard Shortcuts.
:::
::::

Your own files are never changed by DigUp, so there's nothing to undo in them.
