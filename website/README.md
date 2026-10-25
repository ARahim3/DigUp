# DigUp's website

The site at [digup.arahim.dev](https://digup.arahim.dev): the product pages, the docs, troubleshooting, the FAQ and
the changelog. Plain HTML, CSS and JavaScript, built from Markdown and a few data files by one Python script.

```sh
uv run website/build.py --serve     # build, serve on http://127.0.0.1:8000, rebuild on every change
uv run website/build.py --check     # build, then fail on a broken link, anchor, image or unfilled fact
```

The script's dependencies (markdown-it-py, mdit-py-plugins, Jinja2) are pinned in its header; `uv` installs them.
The output goes to `website/dist/`, which isn't committed. `--serve` rebuilds when a page, template, data file or
static file changes; after editing `build.py` itself, stop it and start it again.

## What updates itself

At build time the script asks GitHub for the releases, the published security advisories and the star count (with
`GITHUB_TOKEN`, or `gh auth token` locally). From them come the changelog and its feed, every download button with
its file name, size, date and SHA-256, the "New" line on the home page, and the advisories on the privacy page.
`.github/workflows/website.yml` builds and publishes the site on every push to main that touches `website/`, and
again after every release is published or edited, so a release needs no edit here. `--offline` builds from the last
saved copy of that data (`website/.cache/`).

## Where things are

| | |
|---|---|
| `site.toml` | Facts used on many pages: the model's sizes, requirements, shortcuts, paths, editors, the product video, the platform cards, the comparison table on the download page, the docs' sections. Change a fact here once. |
| `content/docs/*.md` | One docs page each. TOML front matter between `+++` lines: `title`, `description`, `section` (one of `site.toml`'s `docs.sections`), `order`. |
| `content/troubleshooting.toml` | The problems on the troubleshooting page, by area. Each `id` is a link people share; don't change one. |
| `content/faq.toml` | The questions on the FAQ page; `home = true` also shows one on the home page. |
| `templates/` | Jinja templates: `base.html` (head, header, footer, the search panel), `home.html`, `docs.html`, `download.html`, `changelog.html`, `404.html`. |
| `static/` | `css/site.css` (the design, its colors as tokens at the top), `js/site.js` (theme, tabs, the home page's panel and map, the site search), fonts, images, the demo video. |
| `content/space.json`, `tools/space.py` | The home page's map: the real EmbeddingGemma 2 vectors of the demo's files, each search embedded by DigUp's own query encoder and ranked as DigUp ranks, with its best matches and their cosine similarity. `tools/space.py` makes it (and the card pictures in `static/img/space/`) from DigUp's index of the demo folder and the product video's 2-D layout; its header has the command. Run it again to change the searches. |
| `build.py` | The build, the dev server and the checks. |

## Writing pages

- Facts from `site.toml` go in as `{{ site.model.download }}`; the version of the current release as
  `{{ latest.mac.version }}`. An unknown name stops the build.
- Links to other pages start with `/` (`/docs/troubleshooting/#model-download-blocked`); the build adjusts them if
  the site moves under a path.
- Callouts: `::: note`, `::: tip` or `::: warning`, an optional title after it, closed with `:::`.
- Numbered steps: wrap an ordered list in `::: steps` … `:::`.
- Different instructions per system: `:::: tabs`, then `::: tab Mac`, `::: tab Windows`, `::: tab Linux`, each closed
  with `:::`, and `::::` at the end. Visitors see their own system's tab first, and their choice holds across pages.
- Settings and other term lists: a term on one line, `: its description` on the next.
- Keys: `<kbd>⌘</kbd><kbd>K</kbd>`.
- The privacy page's `<!-- advisories -->` is replaced with the list from GitHub.

The product video plays from YouTube (`site.toml` → `video`), and its player loads only when someone clicks to watch; the page itself loads nothing from YouTube. The demo recording (`static/video/demo.mp4`) and the screenshots in `static/img/` come from the app's real recordings.

The voice: plain and short, talking to the reader; what the model does first; every claim true to the released app
(not to main until it ships); no names of people or issue numbers in the docs (the changelog shows the release notes
as they were published).

## Search

Every page, section, problem, question and release note goes into `dist/search.json`, which the search panel
(<kbd>⌘</kbd><kbd>K</kbd>, <kbd>Ctrl</kbd><kbd>K</kbd> or <kbd>/</kbd> on any page) loads the first time it opens.
It matches words, word beginnings and a few synonyms (`SYNONYMS` in `site.js`), counts a title more than the text,
and favors troubleshooting when the words describe a problem.

## Publishing

Settings → Pages → Build and deployment → Source: GitHub Actions; then Custom domain `digup.arahim.dev`, with a
CNAME record `digup` → `arahim3.github.io` at the domain's DNS. To serve it at `https://arahim.dev/DigUp/` instead,
set `base_url` and `base_path` in `site.toml`.
