+++
title = "Opening results"
description = "Where a result opens: recordings and videos at the moment, PDFs at the page, code at the line, and which apps can be told where."
section = "Search"
order = 3
+++

<kbd>↩</kbd> (or <kbd>Enter</kbd>) opens the selected result in the app your system opens that kind of file with, at the place that matched when that app can be told where. <kbd>Space</kbd> shows a big preview at the page or moment either way, and the preview pane plays a recording from its moment.

## Recordings and videos

:::: tabs
::: tab Mac
A recording or a video opens at its moment in QuickTime Player or IINA. The first time, macOS asks whether DigUp may control QuickTime Player; DigUp uses that only to start it at the moment. If you said no, turn it on in System Settings → Privacy & Security → Automation → DigUp. Other players open the file from the start.
:::
::: tab Windows
A recording or a video opens at its moment in VLC, mpv or MPC-HC (and MPC-BE), when it's the app Windows opens that file with. Other players open the file from the start.
:::
::: tab Linux
A recording or a video opens at its moment in VLC or mpv, when it's your default app for that file. A player installed as a Flatpak can't be told the moment, so it opens the file from the start.
:::
::::

## PDFs

:::: tabs
::: tab Mac
A PDF opens in Preview with words from the page that matched in its search box, so Preview lists the matches page by page in its sidebar. Preview doesn't jump to the page by itself; <kbd>Space</kbd> in DigUp shows Quick Look right at the page.
:::
::: tab Windows
A PDF opens at the page in Edge, Chrome, Firefox, Brave, Acrobat or SumatraPDF, when it's the app Windows opens PDFs with. Other viewers open it at the first page.
:::
::: tab Linux
A PDF opens at the page in Evince (and Papers, Atril or Xreader), Okular, Firefox, Chrome, Chromium or Brave, when it's your default PDF app. A viewer installed as a Flatpak opens it at the first page.
:::
::::

<figure><img src="/assets/img/shots/mac-pdf-page.jpg" alt="DigUp's panel on a Mac with the search 'the clause about pets in the lease': page 4 of the lease in the preview, the words pets and clause marked" width="1600" height="818" loading="lazy"><figcaption>Whatever app opens the PDF, the preview shows the page that matched, with your words marked.</figcaption></figure>

## Code

Code opens in the editor you choose in Settings, at the line that matched: {{ site.editors.all }}, and on a Mac also {{ site.editors.mac }}, on Windows also {{ site.editors.windows }}. See [Code search](/docs/code-search/).

## Everything else

Pictures, screenshots and documents open in their usual app. <kbd>⌘</kbd><kbd>↩</kbd> (<kbd>Ctrl</kbd><kbd>Enter</kbd>) shows the file in Finder, Explorer or your file manager instead, and <kbd>⌘</kbd><kbd>C</kbd> copies the file itself, to paste into a message or another folder.
