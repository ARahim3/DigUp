#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "markdown-it-py==4.0.0",
#   "mdit-py-plugins==0.5.0",
#   "jinja2==3.1.6",
# ]
# ///
"""DigUp's website: website/ → website/dist/.

    uv run website/build.py              build the site
    uv run website/build.py --serve      build, serve it on http://127.0.0.1:8000 and rebuild on every change
    uv run website/build.py --check      build, then fail on broken links, anchors, images or unfilled facts
    uv run website/build.py --offline    use the last saved GitHub data (.cache/) instead of asking GitHub

The changelog, the download buttons and the star count come from GitHub's API at build time (with GITHUB_TOKEN or
`gh auth token` when there is one), so a release needs no edit here. Everything else is in site.toml, content/ and
templates/; README.md says where.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import tomllib
import urllib.error
import urllib.request
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from jinja2 import Environment, FileSystemLoader
from markdown_it import MarkdownIt
from mdit_py_plugins.anchors import anchors_plugin
from mdit_py_plugins.container import container_plugin
from mdit_py_plugins.deflist import deflist_plugin
from markupsafe import Markup

ROOT = Path(__file__).resolve().parent
REPO_ROOT = ROOT.parent
CONTENT = ROOT / "content"
TEMPLATES = ROOT / "templates"
STATIC = ROOT / "static"
DIST = ROOT / "dist"
CACHE = ROOT / ".cache"


class BuildError(Exception):
    pass


def say(message: str) -> None:
    print(f"website: {message}", file=sys.stderr)


# ---------------------------------------------------------------------------------------------------------------------
# GitHub data


def github_token() -> str | None:
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        return token
    try:
        out = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=10)
        return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def github_get(path: str, token: str | None):
    request = urllib.request.Request(f"https://api.github.com{path}", headers={
        "Accept": "application/vnd.github+json", "User-Agent": "digup-website-build",
        **({"Authorization": f"Bearer {token}"} if token else {}),
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def github_data(repo: str, offline: bool) -> dict:
    """Releases and the repository's star count, from GitHub or, failing that, from the last build's copy."""
    saved = CACHE / "github.json"
    if not offline:
        try:
            token = github_token()
            releases = github_get(f"/repos/{repo}/releases?per_page=100", token)
            meta = github_get(f"/repos/{repo}", token)
            try:
                advisories = github_get(f"/repos/{repo}/security-advisories?state=published&per_page=100", token)
            except (urllib.error.URLError, OSError, ValueError):
                advisories = json.loads(saved.read_text()).get("advisories") if saved.exists() else None
            data = {"releases": releases, "stars": meta.get("stargazers_count", 0), "advisories": advisories,
                    "fetched": now_iso()}
            CACHE.mkdir(exist_ok=True)
            saved.write_text(json.dumps(data))
            return data
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
            say(f"GitHub didn't answer ({error}); using the saved copy")
    if saved.exists():
        return json.loads(saved.read_text())
    say("no GitHub data saved yet: the changelog and download buttons fall back to links")
    return {"releases": [], "stars": 0, "advisories": None, "fetched": None}


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


ASSET_KINDS = {
    "mac": re.compile(r"\.dmg$", re.I),
    "windows": re.compile(r"setup\.exe$", re.I),
    "linux_deb": re.compile(r"\.deb$", re.I),
    "linux_appimage": re.compile(r"\.AppImage$", re.I),
}
PLATFORM_OF = {"mac": "Mac", "windows": "Windows", "linux_deb": "Linux", "linux_appimage": "Linux"}


def size_text(size: int) -> str:
    if size >= 100 * 1024 * 1024:
        return f"{round(size / 1048576)} MB"
    if size >= 1024 * 1024:
        return f"{size / 1048576:.1f} MB"
    return f"{round(size / 1024)} KB"


def parse_date(iso: str | None) -> dt.datetime | None:
    return dt.datetime.fromisoformat(iso.replace("Z", "+00:00")) if iso else None


def date_text(when: dt.datetime | None) -> str:
    return f"{when:%B} {when.day}, {when.year}" if when else ""


def asset_info(asset: dict, release: dict) -> dict:
    digest = asset.get("digest") or ""
    return {
        "name": asset["name"], "url": asset["browser_download_url"], "size": size_text(asset["size"]),
        "bytes": asset["size"], "sha256": digest.split(":", 1)[1] if digest.startswith("sha256:") else "",
        "version": release["tag_name"].lstrip("v"), "tag": release["tag_name"], "page": release["html_url"],
        "date": date_text(parse_date(release["published_at"])), "beta": release["prerelease"],
    }


def latest_assets(releases: list[dict]) -> dict:
    """The newest published file of each kind, prereleases included (Windows and Linux are betas)."""
    latest: dict = {}
    for release in releases:
        for asset in release["assets"]:
            for kind, pattern in ASSET_KINDS.items():
                if kind not in latest and pattern.search(asset["name"]):
                    latest[kind] = asset_info(asset, release)
    return latest


# ---------------------------------------------------------------------------------------------------------------------
# Markdown


def slugify(text: str) -> str:
    text = re.sub(r"<[^>]+>", "", text).lower()
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    return re.sub(r"[\s_-]+", "-", text).strip("-")


CALLOUTS = {"note": "info", "tip": "tip", "warning": "warn"}


def markdown(anchors: bool = True) -> MarkdownIt:
    md = MarkdownIt("commonmark", {"html": True, "typographer": False}).enable(["table", "strikethrough"])
    if anchors:
        md.use(anchors_plugin, min_level=2, max_level=3, slug_func=slugify)
    md.use(deflist_plugin)

    def callout(kind):
        def render(self, tokens, idx, options, env):
            token = tokens[idx]
            if token.nesting == 1:
                title = token.info.strip()[len(kind):].strip()
                head = f'<p class="callout-title">{html.escape(title)}</p>' if title else ""
                return (f'<aside class="callout callout-{kind}"><svg class="icon" aria-hidden="true">'
                        f'<use href="#i-{CALLOUTS[kind]}"/></svg><div class="callout-body">{head}\n')
            return "</div></aside>\n"
        return render

    for kind in CALLOUTS:
        md.use(container_plugin, name=kind, render=callout(kind))

    def tabs(self, tokens, idx, options, env):
        return '<div class="tabs" data-tabs>\n' if tokens[idx].nesting == 1 else "</div>\n"

    def tab(self, tokens, idx, options, env):
        token = tokens[idx]
        if token.nesting == 1:
            label = token.info.strip()[3:].strip()
            return (f'<section class="tab" data-tab="{slugify(label)}" aria-label="{html.escape(label)}">'
                    f'<p class="tab-label">{html.escape(label)}</p>\n')
        return "</section>\n"

    def steps(self, tokens, idx, options, env):
        return '<div class="steps">\n' if tokens[idx].nesting == 1 else "</div>\n"

    md.use(container_plugin, name="tabs", render=tabs, marker=":")
    md.use(container_plugin, name="tab", render=tab)
    md.use(container_plugin, name="steps", render=steps)
    return md


FACT = re.compile(r"\{\{\s*((?:site|latest)\.[A-Za-z0-9_.]+)\s*\}\}")


def fill_facts(text: str, context: dict, where: str) -> str:
    def lookup(match: re.Match) -> str:
        value: object = context
        for part in match.group(1).split("."):
            if isinstance(value, dict) and part in value:
                value = value[part]
            else:
                raise BuildError(f"{where}: unknown fact {match.group(0)}")
        return str(value)
    return FACT.sub(lookup, text)


def finish_html(rendered: str, base_path: str) -> str:
    rendered = rendered.replace("<table>", '<div class="table-wrap"><table>').replace("</table>", "</table></div>")
    if base_path != "/":
        rendered = re.sub(r'(href|src)="/(?!/)', lambda m: f'{m.group(1)}="{base_path}', rendered)
    return rendered


def plain(text: str) -> str:
    """Markdown or HTML to plain text, for the search index and the table of contents."""
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[`*_]{1,3}", "", text)
    return html.unescape(re.sub(r"\s+", " ", text)).strip()


def sections_of(tokens) -> list[dict]:
    """A page's text, split at its h2 and h3 headings, for the search index."""
    sections = [{"id": "", "heading": "", "text": []}]
    skip_inline = False
    for i, token in enumerate(tokens):
        if token.type == "heading_open" and token.tag in ("h2", "h3"):
            sections.append({"id": token.attrGet("id") or "", "heading": plain(tokens[i + 1].content), "text": []})
            skip_inline = True
        elif token.type == "inline":
            if skip_inline:
                skip_inline = False
            else:
                sections[-1]["text"].append(plain(token.content))
    return [s | {"text": " ".join(s["text"]).strip()} for s in sections if s["text"] or s["heading"]]


def toc_of(tokens) -> list[dict]:
    return [{"id": t.attrGet("id"), "text": plain(tokens[i + 1].content), "level": int(t.tag[1])}
            for i, t in enumerate(tokens) if t.type == "heading_open" and t.tag in ("h2", "h3")]


# ---------------------------------------------------------------------------------------------------------------------
# Content


def front_matter(path: Path) -> tuple[dict, str]:
    text = path.read_text()
    match = re.match(r"\+\+\+\n(.*?)\n\+\+\+\n", text, re.S)
    if not match:
        raise BuildError(f"{path.relative_to(ROOT)}: no +++ front matter")
    return tomllib.loads(match.group(1)), text[match.end():]


def git_date(path: Path) -> str:
    try:
        out = subprocess.run(["git", "log", "-1", "--format=%cs", "--", str(path)], cwd=REPO_ROOT,
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""
    if not out:
        return ""
    when = dt.date.fromisoformat(out)
    return f"{when:%B} {when.day}, {when.year}"


def load_docs(site: dict, context: dict, md: MarkdownIt) -> list[dict]:
    pages = []
    for path in sorted((CONTENT / "docs").glob("*.md")):
        meta, body = front_matter(path)
        for key in ("title", "description", "section"):
            if key not in meta:
                raise BuildError(f"{path.relative_to(ROOT)}: front matter needs {key}")
        if meta["section"] not in site["docs"]["sections"] and meta["section"] != "Docs":
            raise BuildError(f"{path.relative_to(ROOT)}: section {meta['section']!r} isn't in site.toml's docs.sections")
        slug = "" if path.stem == "index" else path.stem
        source = fill_facts(body, context, str(path.relative_to(ROOT)))
        tokens = md.parse(source)
        pages.append({
            **meta, "slug": slug, "url": f"docs/{slug}/" if slug else "docs/", "file": path.name,
            "html": Markup(finish_html(md.renderer.render(tokens, md.options, {}), site["base_path"])),
            "toc": toc_of(tokens), "sections": sections_of(tokens), "kind": meta.get("kind", "page"),
            "order": meta.get("order", 99), "updated": git_date(path),
            "edit": site["docs"]["edit_base"] + "docs/" + path.name,
        })
    return pages


def docs_nav(site: dict, pages: list[dict]) -> list[dict]:
    groups = []
    for name in site["docs"]["sections"]:
        items = sorted((p for p in pages if p["section"] == name), key=lambda p: (p["order"], p["title"]))
        if items:
            groups.append({"name": name, "pages": items})
    return groups


def load_items(name: str, key: str, context: dict, md: MarkdownIt, base_path: str) -> tuple[dict, list[dict]]:
    data = tomllib.loads((CONTENT / name).read_text())
    items = []
    for item in data.get(key, []):
        for needed in ("id", "title", "body"):
            if needed not in item:
                raise BuildError(f"content/{name}: an entry needs {needed} ({item.get('title', item.get('id'))})")
        body = fill_facts(item["body"], context, f"content/{name} → {item['id']}")
        items.append(item | {"html": Markup(finish_html(md.render(body), base_path)), "text": plain(md.render(body))})
    ids = [i["id"] for i in items]
    if len(ids) != len(set(ids)):
        raise BuildError(f"content/{name}: ids repeat")
    return data, items


# ---------------------------------------------------------------------------------------------------------------------
# Releases → the changelog


CATEGORY = re.compile(r"<p>([A-Z][A-Za-z ]{1,30}):</p>")


def link_github_refs(text: str, repo: str) -> str:
    """#123 and @name as GitHub shows them in release notes."""
    text = re.sub(r"(?<![\w/&`#])#(\d+)\b", rf"[#\1](https://github.com/{repo}/issues/\1)", text)
    return re.sub(r"(?<![\w/`@.])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\b", r"[@\1](https://github.com/\1)", text)


def changelog(releases: list[dict], repo: str, md: MarkdownIt) -> list[dict]:
    entries = []
    for release in releases:
        if release.get("draft"):
            continue
        body = (release.get("body") or "").replace("\r\n", "\n").strip()
        paragraphs = body.split("\n\n", 1)
        lede = paragraphs[0] if paragraphs and not paragraphs[0].lstrip().startswith(("-", "*", "#")) else ""
        rest = paragraphs[1] if lede and len(paragraphs) > 1 else ("" if lede else body)
        rendered = md.render(link_github_refs(rest, repo))
        rendered = CATEGORY.sub(lambda m: f'<h4 class="cat" data-cat="{slugify(m.group(1))}">{m.group(1)}</h4>',
                                rendered)
        platforms = []
        for asset in release["assets"]:
            for kind, pattern in ASSET_KINDS.items():
                if pattern.search(asset["name"]) and PLATFORM_OF[kind] not in platforms:
                    platforms.append(PLATFORM_OF[kind])
        when = parse_date(release.get("published_at"))
        title = (release.get("name") or release["tag_name"]).removeprefix("DigUp ").strip()
        bullets = [plain(item) for item in re.findall(r"<li>(.*?)</li>", rendered, re.S)]
        entries.append({
            "tag": release["tag_name"], "version": release["tag_name"].lstrip("v"), "title": title,
            "beta": release["prerelease"], "platforms": platforms, "date": date_text(when),
            "iso": when.isoformat() if when else "", "url": release["html_url"],
            "lede": Markup(md.renderInline(link_github_refs(lede, repo))) if lede else "",
            "lede_text": plain(md.renderInline(lede)) if lede else "",
            "html": Markup(rendered), "bullets": bullets,
            "assets": [asset_info(a, release) for a in release["assets"]],
        })
    return entries


def advisories_html(advisories: list[dict] | None, repo: str) -> str:
    """The published security advisories, newest first, for the privacy page's <!-- advisories --> marker."""
    listing = f'<a href="https://github.com/{repo}/security/advisories">GitHub</a>'
    if advisories is None:
        return f"<p>The published advisories are listed on {listing}.</p>"
    items = []
    for advisory in sorted(advisories, key=lambda a: a.get("published_at") or "", reverse=True):
        fixes = []
        for vulnerability in advisory.get("vulnerabilities") or []:
            name = ((vulnerability.get("package") or {}).get("name") or "").strip()
            patched = (vulnerability.get("patched_versions") or "").strip()
            system = re.sub(r"^DigUp \((.+)\)$", r"\1", name)
            if patched:
                fixes.append(html.escape(patched) + (f" for {html.escape(system)}" if system else ""))
        parts = [f'<a href="{html.escape(advisory["html_url"])}">{html.escape(advisory["ghsa_id"])}</a>']
        severity = (advisory.get("severity") or "").capitalize()
        if severity:
            parts.append(f'<span class="pill">{html.escape(severity)}</span>')
        parts.append(html.escape((advisory.get("summary") or "").rstrip(".")) + ".")
        if fixes:
            parts.append("Fixed in " + (", ".join(fixes[:-1]) + " and " + fixes[-1] if len(fixes) > 1 else fixes[0]) + ".")
        when = date_text(parse_date(advisory.get("published_at")))
        if when:
            parts.append(f"Published {when}.")
        items.append("<li>" + " ".join(parts) + "</li>")
    if not items:
        return f"<p>None published yet. They're listed on {listing} when they are.</p>"
    return '<ul class="advisories">' + "".join(items) + "</ul>"


# ---------------------------------------------------------------------------------------------------------------------
# Build


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:10]


def build(offline: bool = False) -> dict:
    started = time.time()
    site = tomllib.loads((ROOT / "site.toml").read_text())
    base = site["base_path"]
    github = github_data(site["repo"], offline)
    releases = github["releases"]
    latest = {kind: None for kind in ASSET_KINDS} | latest_assets(releases)
    context = {"site": site, "latest": {k: v for k, v in latest.items() if v}}

    md = markdown()
    md_plain = markdown(anchors=False)
    docs = load_docs(site, context, md)
    advisory_list = advisories_html(github.get("advisories"), site["repo"])
    for page in docs:
        page["html"] = Markup(str(page["html"]).replace("<!-- advisories -->", advisory_list))
    nav = docs_nav(site, docs)
    flat = [p for group in nav for p in group["pages"]]
    for i, page in enumerate(flat):
        page["prev"] = flat[i - 1] if i > 0 else None
        page["next"] = flat[i + 1] if i + 1 < len(flat) else None
    trouble_meta, problems = load_items("troubleshooting.toml", "problem", context, md_plain, base)
    faq_meta, questions = load_items("faq.toml", "question", context, md_plain, base)
    entries = changelog(releases, site["repo"], md_plain)

    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir()
    shutil.copytree(STATIC, DIST / "assets", ignore=shutil.ignore_patterns(".DS_Store"))
    hashes = {str(p.relative_to(STATIC)): file_hash(p) for p in STATIC.rglob("*")
              if p.is_file() and p.name != ".DS_Store"}

    def url(path: str = "") -> str:
        return base + path.lstrip("/")

    def asset(path: str) -> str:
        if path not in hashes:
            raise BuildError(f"no static file {path}")
        return f"{base}assets/{path}?v={hashes[path]}"

    def absolute(path: str = "") -> str:
        return site["base_url"].rstrip("/") + url(path)

    def icon(name: str, cls: str = "") -> Markup:
        return Markup(f'<svg class="icon {cls}" aria-hidden="true"><use href="#i-{name}"/></svg>')

    # The home page's map of meaning (made by tools/space.py from real vectors): card pictures get their asset URLs.
    space = json.loads((CONTENT / "space.json").read_text()) if (CONTENT / "space.json").exists() else None
    if space:
        for search in space["searches"]:
            for card in search["cards"]:
                if card.get("img"):
                    card["src"] = asset("img/space/" + card["img"])

    env = Environment(loader=FileSystemLoader(TEMPLATES), autoescape=True, trim_blocks=True, lstrip_blocks=True)
    env.globals.update(site=site, latest=latest, url=url, asset=asset, absolute=absolute, icon=icon, nav=nav,
                       stars=github["stars"], releases=entries, year=dt.date.today().year,
                       problems=problems, trouble=trouble_meta, questions=questions, faq=faq_meta, space=space)

    def write(path: str, template: str, **values) -> None:
        target = DIST / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(env.get_template(template).render(path=path, **values))

    write("index.html", "home.html", page={"title": site["name"], "description": site["description"], "url": ""})
    write("download/index.html", "download.html", page={
        "title": "Download", "url": "download/",
        "description": "DigUp for Mac (Apple Silicon, macOS 14 or later), Windows 10 and 11, and Linux. "
                       "Free and open source; everything runs on your computer."})
    write("changelog/index.html", "changelog.html", page={
        "title": "Changelog", "url": "changelog/",
        "description": "Every DigUp release for Mac, Windows and Linux, and what changed in it."})
    write("donate/index.html", "donate.html", page={
        "title": "Donate", "url": "donate/",
        "description": "DigUp is free and open source. If it's useful to you, you can support it with a donation."})
    write("404.html", "404.html", page={"title": "Page not found", "url": "404.html",
                                         "description": "That page isn't on DigUp's site."})
    for page in docs:
        write(page["url"] + "index.html", "docs.html", page=page)

    feed(entries, site, absolute)
    search_index(docs, problems, questions, entries, site)
    sitemap(docs, absolute)
    (DIST / ".nojekyll").write_text("")
    say(f"built {len(docs) + 5} pages in {time.time() - started:.1f} s → {DIST.relative_to(REPO_ROOT)}")
    return site


def feed(entries: list[dict], site: dict, absolute) -> None:
    items = []
    for entry in entries[:30]:
        content = html.escape(str(entry["lede"]) + str(entry["html"]))
        items.append(f"""  <entry>
    <title>{html.escape(entry['title'])}</title>
    <link href="{absolute('changelog/')}#{entry['tag']}"/>
    <id>{absolute('changelog/')}#{entry['tag']}</id>
    <updated>{entry['iso']}</updated>
    <content type="html">{content}</content>
  </entry>""")
    updated = entries[0]["iso"] if entries else now_iso()
    (DIST / "changelog").mkdir(exist_ok=True)
    (DIST / "changelog" / "feed.xml").write_text(f"""<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>DigUp releases</title>
  <link href="{absolute('changelog/')}"/>
  <link rel="self" href="{absolute('changelog/feed.xml')}"/>
  <id>{absolute('changelog/')}</id>
  <updated>{updated}</updated>
  <author><name>{html.escape(site['author'])}</name></author>
{chr(10).join(items)}
</feed>
""")


def search_index(docs, problems, questions, entries, site) -> None:
    records = []
    for page in docs:
        if page["kind"] in ("troubleshooting", "faq"):
            continue
        for section in page["sections"]:
            records.append({"k": "Docs", "t": page["title"], "h": section["heading"],
                            "u": page["url"] + (f"#{section['id']}" if section["id"] else ""),
                            "s": page["section"], "x": section["text"][:1400]})
    records.append({"k": "Docs", "t": "Donate", "h": "", "u": "donate/", "s": "Project",
                    "x": "DigUp is free and open source. If it's useful to you, you can support it with a donation: "
                         + site["support_terms"] + " Other ways to help: star it on GitHub, report a bug, contribute."})
    for problem in problems:
        records.append({"k": "Help", "t": problem["title"], "h": "", "u": f"docs/troubleshooting/#{problem['id']}",
                        "s": problem.get("area", "Troubleshooting"), "x": problem["text"][:1400],
                        "p": problem.get("platforms", [])})
    for question in questions:
        records.append({"k": "FAQ", "t": question["title"], "h": "", "u": f"docs/faq/#{question['id']}",
                        "s": question.get("group", "FAQ"), "x": question["text"][:1400]})
    for entry in entries:
        records.append({"k": "Changelog", "t": entry["version"], "h": entry["title"],
                        "u": f"changelog/#{entry['tag']}", "s": entry["date"],
                        "x": (entry["lede_text"] + " " + " ".join(entry["bullets"]))[:1400]})
        for bullet in entry["bullets"]:
            records.append({"k": "Changelog", "t": entry["version"], "h": bullet[:140],
                            "u": f"changelog/#{entry['tag']}", "s": entry["date"], "x": bullet[:600]})
    (DIST / "search.json").write_text(json.dumps(records, ensure_ascii=False, separators=(",", ":")))


def sitemap(docs, absolute) -> None:
    paths = ["", "download/", "changelog/", "donate/"] + [page["url"] for page in docs]
    body = "".join(f"  <url><loc>{absolute(p)}</loc></url>\n" for p in paths)
    (DIST / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n'
                                      '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
                                      f"{body}</urlset>\n")
    (DIST / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {absolute('sitemap.xml')}\n")


# ---------------------------------------------------------------------------------------------------------------------
# Checks


def check(site: dict) -> list[str]:
    base = site["base_path"]
    problems: list[str] = []
    ids: dict[Path, set[str]] = {}
    pages = sorted(DIST.rglob("*.html"))
    for page in pages:
        ids[page] = set(re.findall(r'\sid="([^"]+)"', page.read_text()))
    for page in pages:
        text = page.read_text()
        where = page.relative_to(DIST)
        if FACT.search(text) or "{{" in re.sub(r"<(script|pre|code)\b.*?</\1>", "", text, flags=re.S):
            problems.append(f"{where}: an unfilled {{{{ … }}}} is left")
        for attr, value in re.findall(r'\s(href|src|poster)="([^"]*)"', text):
            if not value or value.startswith(("http:", "https:", "mailto:", "data:", "javascript:")):
                continue
            path, _, fragment = value.partition("#")
            path = path.split("?", 1)[0]
            if not path:
                target = page
            elif path.startswith(base):
                target = DIST / path[len(base):]
            elif path.startswith("/"):
                problems.append(f"{where}: {value} is outside the site's base path {base}")
                continue
            else:
                target = (page.parent / path).resolve()
            if target.is_dir() or path.endswith("/"):
                target = target / "index.html"
            if not target.exists():
                problems.append(f"{where}: {attr}={value} points at nothing")
            elif fragment and target.suffix == ".html" and fragment not in ids.get(target, set()):
                problems.append(f"{where}: {value} has no #{fragment} there")
    return problems


# ---------------------------------------------------------------------------------------------------------------------
# Serving


def watched_state() -> dict:
    state = {}
    for folder in (CONTENT, TEMPLATES, STATIC):
        for path in folder.rglob("*"):
            if path.is_file():
                state[path] = path.stat().st_mtime
    state[ROOT / "site.toml"] = (ROOT / "site.toml").stat().st_mtime
    return state


def serve(port: int, site: dict) -> None:
    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send_head(self):
            # Serve /<base_path>… from dist, so a base path of "/DigUp/" works locally too.
            prefix = site["base_path"].rstrip("/")
            if prefix and self.path.startswith(prefix):
                self.path = self.path[len(prefix):] or "/"
            return super().send_head()

    server = ThreadingHTTPServer(("127.0.0.1", port), partial(Quiet, directory=str(DIST)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    say(f"serving http://127.0.0.1:{port}{site['base_path']} (Ctrl+C to stop); rebuilding on changes")
    state = watched_state()
    try:
        while True:
            time.sleep(0.6)
            now = watched_state()
            if now != state:
                state = now
                try:
                    build(offline=True)
                except BuildError as error:
                    say(f"error: {error}")
    except KeyboardInterrupt:
        server.shutdown()


def main() -> int:
    parser = argparse.ArgumentParser(description="Build DigUp's website.")
    parser.add_argument("--serve", action="store_true", help="serve dist/ and rebuild on changes")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--check", action="store_true", help="fail on broken links and unfilled facts")
    parser.add_argument("--offline", action="store_true", help="use the saved GitHub data")
    args = parser.parse_args()
    try:
        site = build(offline=args.offline)
    except BuildError as error:
        say(f"error: {error}")
        return 1
    if args.check:
        problems = check(site)
        for problem in problems:
            say(f"check: {problem}")
        if problems:
            return 1
        say("check: every link, anchor and image resolves")
    if args.serve:
        serve(args.port, site)
    return 0


if __name__ == "__main__":
    sys.exit(main())
