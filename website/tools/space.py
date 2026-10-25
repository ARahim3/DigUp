"""The home page's map of meaning: real EmbeddingGemma 2 vectors of the demo files → website/content/space.json.

Reads the vectors DigUp stored for the demo files (an index.sqlite: one 768-d fp16 vector per picture, video frame,
30 s of sound, PDF page and passage) and a 2-D layout of them (the product video's `space.json`: UMAP with cosine
after centering each modality, rows in the same order as the index's). Each search below is embedded by DigUp's own
query encoder (`digup worker --text-only`, with the search prompt), ranked as DigUp's meaning score ranks (cosine
minus the modality's average for the query, over the spread of all), and placed at the score-weighted centre of
its six best matches. Its best files become the cards, with their real cosine similarity: up to three, and only
those that DigUp's panel would show above its fold (at least half the best one's score). Thumbnails are cut from
the demo files themselves.

usage: python website/tools/space.py --index …/index.sqlite --layout …/space.json --corpus ~/DigUpDemo \
           --digup .build/release/digup --models .dev/models
"""
import argparse
import base64
import json
import shutil
import sqlite3
import subprocess
from collections import Counter
from itertools import product
from pathlib import Path

import numpy as np

SITE = Path(__file__).resolve().parent.parent
SEARCHES = [
    "a dog barking on the beach",
    "সৈকতে একটা কুকুর",
    "zebra in a video",
    "where they talk about sleep",
    "the clause about pets in the lease",
    "a sweet rice pudding recipe",
    "notes from our trip to Jordan",
]
KIND = {"image": "image", "screenshot": "image", "video": "video", "audio": "audio", "pdf": "text", "doc": "text"}
TOPICS = {"beach": "the beach", "safari": "safari", "podcast": "a podcast", "home": "home and food",
          "docs": "pages and notes"}
WORDS = {"image": "photos", "screenshot": "screenshots", "video": "video frames", "audio": "sound", "pdf": "text",
         "doc": "text"}
CARD_W, CARD_H = 0.165, 0.255   # a card's size as a share of the map's width and height
X0, X1, Y0, Y1 = 0.05, 0.95, 0.17, 0.92   # where the layout sits in the map (room for the search field on top)
LABEL_H, LABEL_CH, KINDS_CH = 0.028, 0.0074, 0.0057   # a label's height and its letters' widths, as shares of the map
SEARCH_FIELD = (0.27, 0.0, 0.73, 0.15)


def load(index: Path):
    db = sqlite3.connect(f"file:{index}?mode=ro&immutable=1", uri=True)
    rows = db.execute("""SELECT s.id, f.path, f.kind, s.kind, s.modality, s.loc, s.loc_end, s.excerpt, s.vec, f.info
                         FROM segments s JOIN files f ON f.id = s.file WHERE s.vec IS NOT NULL""").fetchall()
    segs = []
    for sid, path, fkind, skind, modality, loc, loc_end, excerpt, vec, info in rows:
        v = np.frombuffer(vec, dtype=np.float16).astype(np.float32)
        segs.append({"path": path, "fkind": fkind, "skind": skind, "modality": modality, "loc": loc,
                     "excerpt": excerpt or "", "v": v / (np.linalg.norm(v) + 1e-9), "info": json.loads(info or "{}")})
    return segs


def embed(texts: list[str], digup: Path, models: Path) -> np.ndarray:
    p = subprocess.Popen([str(digup), "worker", "--text-only"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, env={"DIGUP_MODELS": str(models), "PATH": "/usr/bin:/bin"})
    assert json.loads(p.stdout.readline()).get("ready")
    out = []
    for n, text in enumerate(texts):
        p.stdin.write(json.dumps({"id": n + 1, "op": "text", "inputs": [f"task: search result | query: {text}"]}) + "\n")
        p.stdin.flush()
        reply = json.loads(p.stdout.readline())
        v = np.frombuffer(base64.b64decode(reply["vectors"]), dtype=np.float32)[: reply["dim"]]
        out.append(v / np.linalg.norm(v))
    p.stdin.write(json.dumps({"id": 0, "op": "quit"}) + "\n")
    p.stdin.flush()
    p.wait(timeout=10)
    return np.stack(out)


def clock(seconds: float) -> str:
    s = int(round(seconds))
    return f"{s // 60}:{s % 60:02d}"


def role(seg: dict) -> str:
    name = Path(seg["path"]).name
    if seg["fkind"] == "screenshot":
        return "a screenshot"
    if seg["fkind"] == "image":
        return "a photo"
    if seg["fkind"] == "video":
        return "a moment in a video"
    if seg["fkind"] == "audio":
        return "a minute in a podcast" if "/Podcasts/" in seg["path"] else "a sound"
    if seg["fkind"] == "pdf":
        return "a page of a PDF"
    if "/Recipes/" in seg["path"]:
        return "a recipe"
    return "a note" if name.endswith((".md", ".txt")) else "a document"


def peaks(path: str, start: float, seconds=8.0, bins=40) -> list[float]:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(start), "-t", str(seconds), "-i", path, "-ac", "1",
                          "-ar", "16000", "-f", "f32le", "-"], capture_output=True, check=True).stdout
    a = np.frombuffer(raw, dtype=np.float32)
    if len(a) < bins:
        return [0.2] * bins
    r = np.array([np.sqrt(np.mean(c ** 2)) for c in np.array_split(a, bins)])
    return [round(float(x), 2) for x in np.clip(r / (r.max() + 1e-9), 0.08, 1)]


def picture(seg: dict, out_dir: Path) -> str | None:
    """A small picture for the card, cut from the demo file itself; its name in static/img/space/."""
    path = Path(seg["path"])
    stem = "".join(c if c.isalnum() else "-" for c in path.stem.lower()).strip("-")
    if seg["fkind"] in ("image", "screenshot"):
        name = f"{stem}.jpg"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(path), "-vf", "scale=360:-2", "-q:v", "3",
                        str(out_dir / name)], check=True)
    elif seg["fkind"] == "video":
        name = f"{stem}-{int(seg['loc'] or 0)}.jpg"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(seg["loc"] or 0), "-i", str(path), "-frames:v", "1",
                        "-vf", "scale=360:-2", "-q:v", "3", str(out_dir / name)], check=True)
    elif seg["fkind"] == "pdf":
        page = int(seg["loc"] or 1)
        name = f"{stem}-p{page}.jpg"
        prefix = out_dir / f"{stem}-p{page}"
        subprocess.run(["pdftoppm", "-f", str(page), "-l", str(page), "-r", "60", "-jpeg", "-singlefile",
                        str(path), str(prefix)], check=True)
    else:
        return None
    return name


def place_cards(points: list[tuple[float, float]], query: tuple[float, float], labels: list) -> list[tuple[float, float]]:
    """Put each card in a clear spot near its point: covering no other card, match, the search, the search field or
    the line along the bottom, and where it can, none of the lines to the matches, the names of neighbourhoods or
    another card's lead. Each card gets its thirty best spots, spread out, and the best combination of them is kept."""
    path = [(query[0] + (px - query[0]) * t, query[1] + (py - query[1]) * t)
            for px, py in points for t in np.linspace(0.1, 0.9, 9)]
    keep_clear = [SEARCH_FIELD, (query[0] - 0.02, query[1] - 0.035, query[0] + 0.02, query[1] + 0.035)]
    spots = [(float(x), float(y)) for x in np.arange(0.012, 0.988 - CARD_W, 0.01)
             for y in np.arange(0.03, 0.935 - CARD_H, 0.01)]

    def overlaps(x, y, b):
        return x < b[2] and x + CARD_W > b[0] and y < b[3] and y + CARD_H > b[1]

    def covers(x, y, p, margin):
        return x - margin < p[0] < x + CARD_W + margin and y - margin < p[1] < y + CARD_H + margin

    def lead(x, y, p):   # where a card's dashed lead from its point meets the card
        return min(max(p[0], x), x + CARD_W), min(max(p[1], y), y + CARD_H)

    def cost(x, y, p):
        ex, ey = lead(x, y, p)
        c = np.hypot((ex - p[0]) * 16 / 9, ey - p[1]) + 0.1 * np.hypot((x + CARD_W / 2 - p[0]) * 16 / 9, y + CARD_H / 2 - p[1])
        return c + 0.5 * sum(covers(x, y, q, 0.0) for q in path) + 0.12 * sum(overlaps(x, y, b) for b in labels)

    options = []
    for p in points:
        cells: dict = {}   # the best spot in each 6 % square of the map, so the choices spread around the point
        for x, y in spots:
            if any(overlaps(x, y, b) for b in keep_clear) or any(covers(x, y, q, 0.012) for q in points):
                continue
            c, cell = cost(x, y, p), (int(x / 0.06), int(y / 0.06))
            if cell not in cells or c < cells[cell][0]:
                cells[cell] = (c, (x, y))
        options.append(sorted(cells.values())[:30])

    def apart(a, b):
        return not (a[0] < b[0] + CARD_W + 0.008 and a[0] + CARD_W + 0.008 > b[0] and
                    a[1] < b[1] + CARD_H + 0.012 and a[1] + CARD_H + 0.012 > b[1])

    best_total, best_layout = None, None
    for combo in product(*options):
        layout = [spot for _, spot in combo]
        if not all(apart(layout[i], layout[j]) for i in range(len(layout)) for j in range(i + 1, len(layout))):
            continue
        total = sum(c for c, _ in combo)
        for j, (x, y) in enumerate(layout):   # a lead that runs under another card
            ex, ey = lead(x, y, points[j])
            for t in np.linspace(0.1, 0.9, 9):
                lx, ly = points[j][0] + (ex - points[j][0]) * t, points[j][1] + (ey - points[j][1]) * t
                total += 0.3 * sum(cx < lx < cx + CARD_W and cy < ly < cy + CARD_H for k, (cx, cy) in enumerate(layout) if k != j)
        if best_total is None or total < best_total:
            best_total, best_layout = total, layout
    assert best_layout, "no room for the cards"
    return best_layout


def place_label(text: str, kinds: str, cx: float, top: float, points: np.ndarray, taken: list) -> tuple[float, float]:
    """The spot nearest above (cx, top) where a label covers no point, no other label and not the search field."""
    w = len(text) * LABEL_CH + 0.008 + len(kinds) * KINDS_CH
    for dy in np.arange(0, 0.2, 0.005):
        for dx in (0, -0.015, 0.015, -0.03, 0.03, -0.05, 0.05):
            x, y = cx + dx, top - 0.012 - LABEL_H - dy
            box = (x - w / 2 - 0.006, y - 0.01, x + w / 2 + 0.006, y + LABEL_H + 0.01)
            if box[0] < 0.01 or box[2] > 0.99 or box[1] < 0.02:
                continue
            others = taken + [SEARCH_FIELD]
            if any(box[0] < t[2] and box[2] > t[0] and box[1] < t[3] and box[3] > t[1] for t in others):
                continue
            inside = (points[:, 0] > box[0]) & (points[:, 0] < box[2]) & (points[:, 1] > box[1]) & (points[:, 1] < box[3])
            if not inside.any():
                taken.append(box)
                return x, y
    return cx, top - 0.012 - LABEL_H


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--layout", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--digup", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    args = parser.parse_args()

    segs = load(args.index)
    layout = json.loads(args.layout.read_text())
    assert layout["n"] == len(segs), "the layout and the index hold different vectors"
    xy = np.array([[p["x"], p["y"]] for p in layout["points"]])
    to_map = lambda p: (X0 + p[0] * (X1 - X0), Y0 + p[1] * (Y1 - Y0))  # noqa: E731
    V = np.stack([s["v"] for s in segs])
    mods = sorted(set(s["modality"] for s in segs))
    out_img = SITE / "static/img/space"
    if out_img.exists():
        shutil.rmtree(out_img)
    out_img.mkdir(parents=True)

    points = [{"x": round(to_map((p["x"], p["y"]))[0] * 100, 2), "y": round(to_map((p["x"], p["y"]))[1] * 100, 2),
               "k": p["k"]} for p in layout["points"]]
    # a label above each neighbourhood that holds together, at its dense middle (a few files of a topic stray far),
    # with the kinds of file it holds: files about the same thing sit together whatever their kind
    mapped = np.array([to_map((p["x"], p["y"])) for p in layout["points"]])
    labels, taken = [], []
    for topic, text in TOPICS.items():
        members = [i for i, p in enumerate(layout["points"]) if p.get("t") == topic]
        if len(members) < 6:
            continue
        pts = mapped[members]
        med = np.median(pts, axis=0)
        core = pts[np.argsort(np.linalg.norm(pts - med, axis=1))[: max(4, int(len(pts) * 0.6))]]
        kinds = " + ".join(w for w, _ in Counter(WORDS[segs[i]["fkind"]] for i in members).most_common())
        lx, ly = place_label(text, kinds, float(np.median(core[:, 0])), float(core[:, 1].min()), mapped, taken)
        labels.append({"text": text, "kinds": kinds, "x": round(lx * 100, 2), "y": round(ly * 100, 2)})
        print(f"label {text!r} ({kinds}) at {labels[-1]['x']}, {labels[-1]['y']}")

    searches = []
    for text, q in zip(SEARCHES, embed(SEARCHES, args.digup, args.models)):
        cos = V @ q
        mean_by = {m: cos[[i for i, s in enumerate(segs) if s["modality"] == m]].mean() for m in mods}
        z = np.array([cos[i] - mean_by[s["modality"]] for i, s in enumerate(segs)]) / (cos.std() + 1e-9)
        order = np.argsort(-z)
        top = order[:6]
        w = np.clip(z[top], 0.1, None)
        qx, qy = to_map((xy[top] * w[:, None]).sum(0) / w.sum())
        near, seen = [], set()
        for i in order:
            if segs[i]["path"] in seen:
                continue
            if near and z[i] < 0.5 * z[near[0]]:
                break
            seen.add(segs[i]["path"])
            near.append(int(i))
            if len(near) == 3:
                break
        print(f"{text!r}")
        cards = []
        for i in near:
            s = segs[i]
            card = {"i": i, "name": Path(s["path"]).name, "kind": KIND.get(s["fkind"], "text"), "role": role(s),
                    "cos": round(float(cos[i]), 2), "z": round(float(z[i]), 2)}
            if s["fkind"] in ("video", "audio") and s["loc"] is not None:
                card["at"] = clock(s["loc"])
            if s["fkind"] == "pdf":
                card["at"] = f"p. {int(s['loc'] or 1)}"
            if s["fkind"] == "audio":
                card["peaks"] = peaks(s["path"], s["loc"] or 0)
            elif s["fkind"] == "doc":
                card["excerpt"] = " ".join(s["excerpt"].split())[:160]
            else:
                card["img"] = picture(s, out_img)
            print(f"  {card['role']:<22} {card['name']:<44} cos={card['cos']} z={card['z']} {card.get('at', '')}")
            cards.append(card)
        spots = place_cards([to_map(xy[c["i"]]) for c in cards], (qx, qy), taken)
        for card, (x, y) in zip(cards, spots):
            card["x"], card["y"] = round(x * 100, 2), round(y * 100, 2)
            px, py = to_map(xy[card["i"]])
            card["px"], card["py"] = round(px * 100, 2), round(py * 100, 2)
        searches.append({"q": text, "x": round(qx * 100, 2), "y": round(qy * 100, 2), "cards": cards})

    data = {"n": len(segs), "dim": int(V.shape[1]), "points": points, "labels": labels, "searches": searches}
    (SITE / "content/space.json").write_text(json.dumps(data, ensure_ascii=False, indent=1))
    print("wrote content/space.json:", len(points), "points,", len(searches), "searches")


if __name__ == "__main__":
    main()
