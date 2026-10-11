DigUp on Windows. Native and fast. No web shell.

- Start here: `docs/User-Guide.md` (use it), `docs/Builder-Guide.md` (build it).
- Code: `src/DigUp.Core` (engine), `src/DigUp.Embed` (model helper,
  digup-embed.exe), `src/digup` (CLI), `src/DigUp.App` (WPF app,
  DigUpApp.exe — the name differs from digup.exe on purpose).
- Model runtime: `powershell -File scripts\build-llama-windows.ps1`
  puts DLLs in `windows/native/x64`.
- Dev run (builds all, checks all, starts the app):
  `powershell -File scripts\dev-run-windows.ps1`.
- Build: `dotnet build DigUp.Windows.sln -c Release`.
- Ship: per-user Velopack, no admin. See `setup/velopack-notes.md`.
- Privacy: all on your PC. Model fetch once + daily update check only.
- Worker chatter goes to `<index>\worker.log`, never to your results.
