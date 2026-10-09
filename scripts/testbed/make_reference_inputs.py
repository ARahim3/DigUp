"""Writes the fixed inputs of Tests/LlamaRuntimeTests (ReferenceVectorTests): a screenshot-like PNG, a photo-like JPEG
and a speech-like WAV, all synthetic (no personal or third-party media) and the same on every run. The files are
committed; this only says how they were made.

usage: worker/.venv/bin/python -I scripts/testbed/make_reference_inputs.py Tests/LlamaRuntimeTests/Reference
"""
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
rng = np.random.default_rng(20261008)


def disc(image, cx, cy, r, color):
    yy, xx = np.ogrid[: image.shape[0], : image.shape[1]]
    image[(xx - cx) ** 2 + (yy - cy) ** 2 <= r * r] = color


# A screenshot: a window with a sidebar, an alert, lines of "text" and a button (1440 × 900, as a Retina shot halved).
screen = np.full((900, 1440, 3), (246, 246, 248), np.uint8)
screen[:52] = (230, 230, 235)
for x, color in [(22, (255, 95, 87)), (44, (254, 188, 46)), (66, (40, 200, 64))]:
    disc(screen, x, 26, 6, color)
screen[52:, :240] = (236, 238, 242)
for row in range(14):
    width = int(rng.integers(60, 180))
    screen[80 + row * 30 : 90 + row * 30, 24 : 24 + width] = (120, 120, 130)
screen[90:150, 280:1380] = (255, 228, 228)
screen[112:126, 300 : 300 + 520] = (200, 40, 40)
for row in range(16):
    width = int(rng.integers(300, 1060))
    screen[180 + row * 26 : 190 + row * 26, 280 : 280 + width] = (60, 60, 70)
screen[620:660, 280:440] = (0, 122, 255)
screen[636:644, 310:410] = (255, 255, 255)
Image.fromarray(screen).save(out / "screen.png", optimize=True)

# A photo: sky, sun, two hills, a tree, and grain (1024 × 768, saved as the indexer saves photos: JPEG at 90).
height, width = 768, 1024
t = np.linspace(0, 1, height)[:, None, None]
photo = (1 - t) * np.array([90, 150, 230]) + t * np.array([200, 220, 240]) + np.zeros((1, width, 3))
disc(photo, 780, 180, 60, (255, 230, 150))
xs = np.arange(width)
for base, amplitude, period, color in [(470, 40, 380, (90, 150, 80)), (560, 30, 260, (60, 120, 60))]:
    ridge = base + amplitude * np.sin(xs / period * 2 * np.pi)
    photo[np.arange(height)[:, None] >= ridge[None, :]] = color
for row in range(120):
    half = row // 3
    photo[420 + row, 200 - half : 200 + half] = (30, 90, 40)
photo[540:600, 192:208] = (110, 80, 50)
photo = np.clip(photo + rng.normal(0, 6, photo.shape), 0, 255).astype(np.uint8)
Image.fromarray(photo).save(out / "photo.jpg", quality=90)

# Speech-like sound: a voice-like pitch contour with harmonics under three formants, in six syllables, a little
# noise; 4 s of 16 kHz mono 16-bit PCM, as the indexer writes audio windows.
rate, seconds = 16_000, 4.0
n = int(rate * seconds)
time = np.arange(n) / rate
pitch = 150 + 30 * np.sin(2 * np.pi * time / seconds) + 10 * np.sin(2 * np.pi * 3 * time)
phase = 2 * np.pi * np.cumsum(pitch) / rate
voice = np.zeros(n)
for k in range(1, 25):
    frequency = k * pitch
    formants = sum(np.exp(-(((frequency - f) / bandwidth) ** 2)) for f, bandwidth in [(550, 120), (1500, 200), (2600, 300)])
    voice += (formants + 0.05) / k * np.sin(k * phase)
envelope = np.zeros(n)
for syllable in range(6):
    start, length = int((0.15 + syllable * 0.62) * rate), int(0.42 * rate)
    envelope[start : start + length] = np.sin(np.linspace(0, np.pi, length)) ** 2
sound = voice * envelope + rng.normal(0, 0.01, n)
pcm = np.round(sound / np.abs(sound).max() * 0.5 * 32767).astype("<i2")
with open(out / "speech.wav", "wb") as wav:
    wav.write(b"RIFF" + struct.pack("<I", 36 + pcm.nbytes) + b"WAVE")
    wav.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16))
    wav.write(b"data" + struct.pack("<I", pcm.nbytes) + pcm.tobytes())

for name in ["screen.png", "photo.jpg", "speech.wav"]:
    print(name, (out / name).stat().st_size, "bytes")
