+++
title = "Privacy and security"
description = "What DigUp does on the network, what it reads, what it stores and where, how its downloads and updates are signed, and how to report a problem."
section = "Under the hood"
order = 2
+++

Nothing you index leaves your computer. This page says exactly what DigUp does, so you don't have to take that on trust.

## On the network

DigUp goes online for two things only.

1. The model, once. On first launch it downloads the two model files ({{ site.model.download }}) from [Hugging Face]({{ site.model.gguf_url }}), checks their size and SHA-256 against values built into the app, and keeps them. On a Mac you can also hand it files downloaded elsewhere.
2. An update check, once a day. It asks GitHub for a small file listing the current release. The request carries what any download does, like the app's version and your system type, and nothing about your files or searches. Turn it off in Settings → General; an update is installed only when you choose it.

There's no account, no telemetry, no crash reporting and no analytics. Your searches are read by the model on your computer and never sent anywhere.

## What it reads

Only the folders you choose, and in them only pictures, PDFs, documents, spreadsheets and slides, recordings and videos; code only in the folders you pick for code search. DigUp reads your files and never changes, moves or uploads them. It skips hidden folders like `.ssh`, app bundles, caches and developer folders, and never downloads a file that lives only in the cloud.

Keys, certificates and similar files aren't among the kinds it reads. In code folders, files named like keys or password stores and any file holding a private key are skipped as well. A plain text document is read like any other document, so keep notes with secrets in a folder you don't choose, or skip that folder. Skipping or removing a folder takes its files out of the index right away. [Choosing folders](/docs/folders/) has the details.

## What it stores

The model and the index live in DigUp's folder in your user account ([where](/docs/uninstall/)). The index is one SQLite file holding, for each file, its path, size and dates, the text read from it, for keyword search, and its points in the model's space.

DigUp doesn't encrypt the index itself. Its folder is readable only by your user account, and on a Mac with FileVault it's on the encrypted disk like everything else. Anyone who can read it as you can also read the files it came from, but it is one consolidated copy of what's in them, so keep that in mind on a shared computer. Deleting the folder removes everything DigUp knows.

While it indexes, DigUp writes temporary resized copies of what the model reads (pictures, video frames, pieces of sound) to the system's temporary folder, and deletes them as it goes.

## Signing and updates

- The Mac app is signed with the developer's Apple Developer ID, notarized by Apple, and runs with the hardened runtime. Its updates are signed with a separate key whose public half the app carries, and it refuses an update that isn't signed with it.
- The Windows installer isn't code-signed yet, so Windows asks before running it. Updates to it and to the Linux AppImage are signed, and the app checks the signature before installing.
- Every file on GitHub Releases shows its SHA-256, and the [download page](/download/) repeats it.
- The project is open source under the MIT license and builds from the repository with pinned dependencies, so what runs can be checked against what's published.

## Reporting a problem

Please report a security problem privately, through [Report a vulnerability]({{ site.security_report }}) on the repository's Security tab, not in a public issue. Reports are acknowledged, fixed, released, and then published as an advisory with the reporter credited.

## Advisories

Published advisories, newest first, as GitHub lists them:

<!-- advisories -->

Each was reported privately and fixed in a release before it was published.

## This website

This site is static files. It sets no cookies, runs no analytics and loads nothing from other sites, apart from asking GitHub's public API for the star count when a page opens. The product video is on YouTube, and its player loads from youtube-nocookie.com only when you choose to watch it. The search on the site runs in your browser.
