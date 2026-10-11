# Ship notes (Velopack, per user, no admin)

This is the plan for release builds. Today `dotnet publish` makes the
self-contained folder (tested: `digup.exe` runs with no .NET installed).
Velopack wraps that folder into an installer with auto-update.

## What goes in the installer

- `DigUpApp.exe` + `digup.exe` + `digup-embed.exe` (self-contained publish).
  The app assembly is DigUpApp on purpose: DigUp.dll would overwrite
  digup.dll on case-insensitive disks (the Mac build does the same).
- `windows/native/x64/llama.dll` + `mtmd.dll` (+ `ggml*.dll`) for x64.
- `windows/native/arm64/` same set for Snapdragon (built on ARM64).
- `ffmpeg.exe` + `ffprobe.exe` (sound and video; app folder only, never PATH).
- `pdfium.dll` (PDF text and page pictures).
- Tesseract data files (text in screenshots).
- `e_sqlite3.dll` (already inside publish output; no SQLite install needed).

Nothing else. No drivers. No services. No admin rights.

## Where user data lives

- `C:\Users\<name>\AppData\Local\DigUp\` — settings, models, index.
- Uninstall removes the app. Data is removed only if the user ticks
  "remove my index and models". Nothing is left in system folders.

## Updates

- Velopack feed (releases page). The app checks once a day.
- The check sends nothing about files. It can be turned off in settings.
- Updates are deltas (small downloads), installed on next start.

## Safety proof (before each release)

1. Fresh Windows 11 VM, install as normal user (no admin password used).
2. Run, index a test folder, search, open one result of each kind.
3. Update to the next build through the app. Index and settings survive.
4. Uninstall. App folder gone; `autoruns` shows no new entries.
5. Log all four steps in the release notes.
