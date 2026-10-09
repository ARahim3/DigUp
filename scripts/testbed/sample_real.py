# Picks a random (seeded) sample of your own files by kind and clones them into <testbed>/real/.
# APFS clones (cp -c) share blocks with the originals, so the sample costs no disk space.
#   python3 -I sample_real.py <testbed_dir>
import os, random, re, subprocess, sys

HOME = os.path.expanduser("~")
OUT = os.path.join(sys.argv[1], "real")
ROOTS = [f"{HOME}/{d}" for d in ("Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music")]
SKIP = re.compile(r"/(node_modules|\.git|\.venv|venv|site-packages|build|DerivedData|Pods)/|\.noindex/|\.photoslibrary/|\.app/|/\.[^/]+/|DigUpTestbed/")
rng = random.Random(7)


def mdfind(query):
    found = []
    for root in ROOTS:
        if os.path.isdir(root):
            out = subprocess.run(["mdfind", "-0", "-onlyin", root, query], capture_output=True).stdout
            found += [p for p in out.decode("utf-8", "replace").split("\0") if p and not SKIP.search(p)]
    return sorted(set(found))


def attr(path, name):
    out = subprocess.run(["mdls", "-raw", "-name", name, path], capture_output=True).stdout.decode("utf-8", "replace").strip()
    try:
        return float(out)
    except ValueError:
        return None


def pick(paths, n, keep=lambda p: True):
    paths = paths[:]
    rng.shuffle(paths)
    chosen = []
    for p in paths:
        if len(chosen) == n:
            break
        if os.path.isfile(p) and keep(p):
            chosen.append(p)
    return chosen


def clone(paths, kind, manifest):
    dest_dir = os.path.join(OUT, kind)
    os.makedirs(dest_dir, exist_ok=True)
    for src in paths:
        name = os.path.basename(src)
        dst, i = os.path.join(dest_dir, name), 2
        while os.path.exists(dst):
            stem, ext = os.path.splitext(name)
            dst, i = os.path.join(dest_dir, f"{stem} {i}{ext}"), i + 1
        # -c clones (no extra space), -p keeps dates; cp copies xattrs (the screenshot flag) by default.
        if subprocess.run(["cp", "-c", "-p", src, dst], capture_output=True).returncode == 0:
            manifest.append(f"{kind}\t{os.path.relpath(dst, OUT)}\t{src}")
        else:
            print(f"  skipped (clone failed): {name}", file=sys.stderr)


manifest = []
shots = mdfind("kMDItemIsScreenCapture == 1 && kMDItemContentTypeTree == 'public.image'")
clone(pick(shots, 120), "screenshots", manifest)

images = mdfind("kMDItemContentTypeTree == 'public.image' && kMDItemIsScreenCapture != 1 && kMDItemPixelWidth >= 256 && kMDItemPixelHeight >= 256")
clone(pick(images, 120), "images", manifest)

pdfs = mdfind("kMDItemContentTypeTree == 'com.adobe.pdf'")
big = pick(pdfs, 2, lambda p: (attr(p, "kMDItemNumberOfPages") or 0) > 100)
clone(big + pick([p for p in pdfs if p not in big], 23, lambda p: 0 < (attr(p, "kMDItemNumberOfPages") or 0) <= 100), "pdfs", manifest)

docs = mdfind("kMDItemContentTypeTree == 'org.openxmlformats.wordprocessingml.document' || kMDItemContentTypeTree == 'com.microsoft.word.doc' || kMDItemContentTypeTree == 'public.rtf' || kMDItemContentTypeTree == 'net.daringfireball.markdown' || (kMDItemContentTypeTree == 'public.plain-text' && kMDItemFSName == '*.txt'c)")
clone(pick(docs, 15), "docs", manifest)

videos = [p for p in mdfind("kMDItemContentTypeTree == 'public.movie'") if not p.lower().endswith((".ts", ".mts"))]
clone(pick(videos, 6, lambda p: 30 <= (attr(p, "kMDItemDurationSeconds") or 0) <= 900 and os.path.getsize(p) <= 600e6), "videos", manifest)

audio = mdfind("kMDItemContentTypeTree == 'public.audio'")
dur = lambda lo, hi: (lambda p: lo <= (attr(p, "kMDItemDurationSeconds") or 0) < hi)
a_short = pick(audio, 3, dur(5, 300))
a_mid = pick([p for p in audio if p not in a_short], 2, dur(300, 1200))
a_long = pick([p for p in audio if p not in a_short + a_mid], 1, dur(1800, 5400))
clone(a_short + a_mid + a_long, "audio", manifest)

with open(os.path.join(OUT, "MANIFEST.tsv"), "w") as f:
    f.write("kind\ttestbed path\tsource\n" + "\n".join(manifest) + "\n")
counts = {}
for line in manifest:
    counts[line.split("\t")[0]] = counts.get(line.split("\t")[0], 0) + 1
print("real/:", ", ".join(f"{v} {k}" for k, v in counts.items()))
