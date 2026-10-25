+++
title = "First launch"
description = "What setup asks, what the model download is, and what happens while DigUp reads your folders for the first time."
section = "Get started"
order = 4
+++

## Setup

The first time you open DigUp, a short setup walks you through four steps. Nothing is read until you've chosen folders and started.

::: steps
1. The first screen says what DigUp does and the one download it needs. The model ({{ site.model.download }}) starts downloading in the background as you go on, and its progress shows at the bottom of every step.
2. Choose the folders to search. Your usual folders are listed with how many files of each kind they hold and how long their first pass will take, measured on your computer. Open a folder to choose only some of its subfolders, use Add Folder… for any other one (an external drive too), and Skip some folders or file types for the rest. Start Indexing applies your choice.
3. If your computer has code projects, setup offers [code search](/docs/code-search/) for the folders that hold them. It stays off unless you choose folders for it.
4. Try the shortcut: <kbd>⇧</kbd><kbd>⌘</kbd><kbd>Space</kbd> on a Mac, <kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>Space</kbd> on Windows and Linux. Click it to record another; one that the system or another app already uses is refused with the reason.
:::

The last screen, You're all set, says where DigUp lives and lists the keys of the search panel. To have the shortcut work right after you log in, turn on Open DigUp when you log in, in Settings → General.

## The model

DigUp downloads {{ site.model.by }}'s {{ site.model.name }} once: the text part ({{ site.model.text_part }}) and the image and audio encoders ({{ site.model.encoders }}), from [Hugging Face]({{ site.model.gguf_url }}). It checks each file's size and SHA-256 before using it, and a download that stops resumes where it left off when DigUp opens again. If your network blocks Hugging Face, see [the model download fails or is blocked](/docs/troubleshooting/#model-download-blocked).

## The first pass

Once both model files are in, DigUp reads the folders you chose, newest files first, so last month's screenshots and photos are searchable within minutes. File names are searchable right away, before the model is in.

How long the whole pass takes depends on what's there and on your computer: a few minutes for a few hundred files on a Mac, about an hour for a big Downloads folder. On a processor alone, a picture takes a few seconds, so a large photo library can take hours. It happens once; after that, DigUp only reads what's new or changed. [Indexing](/docs/indexing/) explains the progress, pausing, and indexing only at set hours.

## Where DigUp lives

On a Mac, DigUp is in the menu bar; on Windows and Linux, in the tray. Its icon shows how indexing is going, and its menu has the search, Settings, Pause and Quit. Opened at login it stays there quietly; opened from Applications, the Start menu or your app list, it shows the search window.

::: tip Next
Press the shortcut and type something you remember. [Searching](/docs/searching/) covers the panel, and [Writing a good search](/docs/search-tips/) what to type.
:::
