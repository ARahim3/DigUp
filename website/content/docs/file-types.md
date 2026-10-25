+++
title = "What DigUp reads"
description = "Every kind of file DigUp reads on each system, what it reads from it, and what it leaves out."
section = "Your files"
order = 2
+++

## By kind

| Kind | Formats | What's read |
|---|---|---|
| Photos and pictures | JPEG, PNG, HEIC and HEIF, WebP, AVIF, GIF, TIFF, BMP and more. On a Mac also RAW photos (CR2, NEF, ARW, DNG and others) and SVG | The picture |
| Screenshots | The same formats | The picture, and on a Mac the text in it, for exact words |
| PDFs | Any, scans included | Each page's text; a page with little or no text, like a scan, as a picture (and on a Mac its text too) |
| Documents | txt, md, typ, rtf, docx, odt, html. On a Mac also old Word .doc | The text, in passages of about 1,800 characters |
| Spreadsheets and slides | xlsx, ods, pptx, odp | Each sheet's name and rows; each slide's text and speaker notes |
| Audio | MP3, M4A, AAC, WAV, AIFF, FLAC, and on Windows and Linux also OGG, Opus, WMA and more | 30 seconds at a time, every 25 seconds, silence skipped |
| Video | MP4, MOV, M4V, and on Windows and Linux also MKV, WebM, AVI, WMV and more | A frame every few seconds, one per shot, plus the soundtrack as audio |
| Code (only with code search) | Source files, YAML, TOML, notebooks, a repository's docs | Stretches of whole lines, notebook cells without outputs |

On a Mac, DigUp reads pictures, audio and video with macOS's own frameworks, so it reads the formats macOS itself opens. On Windows and Linux it reads them with FFmpeg, PDFium and stb.

## Screenshots

On a Mac, screenshots are the pictures macOS marks as screenshots, wherever you keep them. On Windows and Linux, they're the pictures named like screenshots (Screenshot…, Snipping Tool and Spectacle names). Everywhere, a picture in a folder named Screenshots counts as one, whatever it's called.

## Long files

Audio and video of any length are read whole. A PDF over 50 pages gets its first 30 pages in the first pass and the rest once everything else is in, 30 at a time, up to 5,000 pages. Long documents work the same way, 40 passages first, up to 5,000 passages (about 8 million characters).

## Small and odd files

- Pictures smaller than 256 pixels and recordings shorter than 2 seconds are skipped.
- Text that's mostly numbers, like a data export, is found by its exact text only: it has no meaning for the model to place.
- Copy-protected songs (.m4p, from Apple Music or the old iTunes Store) are skipped, since only the Music app can play them.
- A file that can't be read, or whose reading runs away, is skipped, and the rest go on.

## Not read

Pages, Keynote and Numbers files, EPUB books, email (mail apps keep it in their own stores), archives like zip, apps, and code outside the folders you pick for code search. DigUp never reads keys or certificates, and never changes, moves or uploads any file.
