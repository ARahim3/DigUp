+++
title = "Report a bug"
description = "What to include in a bug report, where DigUp's logs are on each system, and how to report a security problem."
section = "Help"
order = 3
+++

Bugs and ideas go to [GitHub Issues]({{ site.issues }}). Search there first: someone may have reported it already, and a fix may be on its way.

## What helps

- Your computer: on a Mac its chip and memory; on Windows and Linux its processor and graphics card.
- The system and DigUp versions. On Linux also the desktop (GNOME, KDE…) and whether it's Wayland or X11.
- What you did or searched for, and what you expected instead.
- The logs, after a look through them (below).

A search that misses is a bug too. The ranking is measured against sets of searches with known answers, and a miss on real files is the most useful report there is: the kind of file, and the words you typed.

## Logs

:::: tabs
::: tab Mac
`app.log` and `indexer.log` in `{{ site.paths.mac_logs }}`. In Finder, choose Go → Go to Folder… and paste the path.
:::
::: tab Windows
The logs in `{{ site.paths.windows_logs }}`, and `worker.log` in `{{ site.paths.windows_data }}\index`. Paste the path into File Explorer's address bar.
:::
::: tab Linux
The logs in `{{ site.paths.linux_logs }}`, and `worker.log` in `{{ site.paths.linux_data }}/index`.
:::
::::

The logs can contain file names and your searches, so look through them before you paste them anywhere. On Windows and Linux, `speed.log` says whether the model runs on the graphics card or the processor; its last line is worth including when results look wrong.

## Ideas and changes

Please open an issue before you write code for a fix or a feature, so it gets a clear yes, not now, or how it should fit before you spend an evening on it. [Contributing](/docs/contributing/) has the rest.

## Security problems

Report a security problem privately, through [Report a vulnerability]({{ site.security_report }}) on the repository's Security tab, not in a public issue. [Privacy and security](/docs/privacy/#reporting-a-problem) says how reports are handled.
