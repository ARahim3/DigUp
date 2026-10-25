+++
title = "How it works"
description = "How DigUp turns your files into one searchable space with EmbeddingGemma 2, ranks results, runs the model, and keeps its index valid."
section = "Under the hood"
order = 1
+++

## The model

[{{ site.model.name }}]({{ site.model.url }}) is the embedding model {{ site.model.by }} released in {{ site.model.released }}. It takes text, pictures, sound or video, and turns each into a list of {{ site.model.dims }} numbers, a point in one shared space where things that mean the same land close together, whatever kind of input they came from. A photo of a dog on a beach lands next to the words "a dog on the beach", in any of the model's {{ site.model.languages }} languages. It's open under {{ site.model.license }}, and at {{ site.model.params }} parameters it's small enough to run on a laptop.

DigUp runs [ggml-org's 8-bit build]({{ site.model.gguf_url }}) of it through [llama.cpp](https://github.com/ggml-org/llama.cpp). The build comes as two files: the text part ({{ site.model.text_part }}) and the image and audio encoders ({{ site.model.encoders }}). That's the one download DigUp makes.

Two facts about the model shape the design. It listens to 30 seconds of sound per input, so long recordings are read as overlapping 30-second windows. And it takes a limited number of video frames at once, so DigUp embeds a video's keyframes as pictures, one per shot, plus its soundtrack as sound.

## From files to points

Nothing long is squeezed into one point. Each file is read in pieces the size the model handles well, each piece gets its own point with its place in the file, and at search time the best piece of a file is its score. That's also where the result opens.

| Kind | What becomes a point | Where it opens |
|---|---|---|
| Photo | The picture | The file |
| Screenshot | The picture, at twice a photo's detail. On a Mac, its text is read too, for exact words | The file |
| PDF | Each page's text; a page with little text, like a scan, as a picture | The page |
| Document, spreadsheet, slides | Passages of about 1,800 characters; sheets by name and rows, slides with their notes | The passage |
| Audio | 30-second windows, one every 25 seconds, so no sentence falls between two | The moment |
| Video | A frame every 3 seconds, kept when the picture changed (about one per shot), plus the soundtrack | The moment |
| Code | Stretches of whole lines up to 1,800 characters, with the file's path in its repository | The line |

The readers that turn files into pictures, text and sound come from each system: on a Mac, macOS's own ImageIO, PDFKit and AVFoundation; on Windows and Linux, PDFium, FFmpeg, stb and miniz. They only decode files. Everything after that is the same code everywhere.

## One file for the index

Every point is stored at half precision (1.5 KB each) in one SQLite file, next to a keyword index of the same text. A search compares your words with every point by plain matrix multiplication; for the tens of thousands of points a home folder makes, that takes a few milliseconds, so there's no separate vector database. Code search keeps a second file of its own.

## Ranking

Your words go through the same model, with its search prompt, while you type. Each piece in the index gets a meaning score: how close it is to your words, measured against the other pieces of its kind for this search, so a picture and a page can be ranked together. Exact words add to it: the more of your words a file has, in its name or its text, the more they count, and a query that looks like an invoice number or an error code counts them double. A kind you name ("in a video") gets a small boost.

This combination was chosen by measurement. On the project's test sets, it put the right file first more often than fusing two ranked lists did (0.88 against 0.73 on the synthetic set), because rank fusion throws away how strong each match is: one common word in a terminal screenshot could beat a chart that matched by meaning.

Results below half the best score fold under "weaker matches", a display rule only.

## Exact words

Keyword search runs in SQLite's full-text index over file names, document and page text, and on a Mac the text read from screenshots and scans. Words match whole, with their endings; a word of three letters or more that's in no file as typed matches as the start of longer words. Numbers of four digits or more are matched as written. The model alone found 5 of 9 exact lookups like error codes in the project's tests; with keywords, all of them.

## Running the model

The model runs in a helper process next to the app. On a Mac it runs on the GPU with Metal. On Windows and Linux it runs on the graphics card with Vulkan when a quick check at setup finds that faster and giving the same results, and on the processor otherwise; searches always run on the processor there, so the panel never waits for a graphics card to wake up.

The indexing helper reads the next batch of files while the model embeds the current one, and quits when it's done. A smaller helper holds just the text part of the model while you search, and quits after ten minutes without one. If reading a file runs away, the helper stops it, notes the file, skips it and goes on.

## Keeping the index valid

The index remembers which model, revision and version of its vectors made them, and never mixes them. Before any update to llama.cpp ships, a test checks that fixed inputs (texts, pictures, a recording) still give the stored reference vectors, at a cosine similarity of 0.999 or more. An update that passes keeps your index; one that didn't would make DigUp read everything again by itself.

## Numbers

Measured on the developer's Mac (an M4 Pro) and the project's test files. The test sets are small, so these give a sense of scale, not a benchmark.

| What | Measured |
|---|---|
| Results after you stop typing | {{ site.numbers.results }}, {{ site.numbers.results_cold }} the first time |
| A new screenshot becomes searchable | About a second after it lands |
| Right file first on the test sets | {{ site.numbers.evals_first }} searches (English, Bengali, Arabic), {{ site.numbers.evals_top5 }} in the top 5 |
| The app, idle | {{ site.numbers.idle_mac }} |
| The search helper | About 250 MB, while you search |
| The indexing helper | Under about 2 GB at peak |
| Index size | A photo about 1.6 KB, a PDF page about 6 KB, an hour of video 1 to 2 MB |

The code is open: [github.com/{{ site.repo }}]({{ site.github }}).
