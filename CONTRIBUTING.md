# Contributing to DigUp

Thanks for your interest in DigUp. It's a small project with one maintainer, so a few notes up front save everyone
time.

## Open an issue first

Please open an issue before you write any code, for a fix as much as for a feature. The same fix or feature may already
be in progress and not pushed yet. An issue gets you a clear "yes", "not now" or "here's how it should fit" before you
spend an evening on it. A pull request that arrives without one may be closed with a link back here.

## Pull requests

Once an issue says go:

- Keep it to one fix or one feature, with the reason in the description.
- Make sure `swift test` passes.
- If it changes what search returns, run the evals in `evals/` before and after (see "Build from source" in the
  README) and include both results.
- For speed or memory changes, measure before and after on the same Mac.

DigUp keeps everything on the Mac, so changes that send data elsewhere, like telemetry or cloud services, aren't a fit.

## What to expect

DigUp is maintained alongside a day job and other projects, so replies can take a few days, sometimes longer. A quiet
week means busy, not ignored, and every issue gets an answer, even if it's "not now".

Not every pull request will be merged, even good ones. The project has a direction, and some changes won't fit it.
Others get reworked or rewritten to fit work in progress, and when that happens you'll be credited in the release
notes.

## Reporting a bug

Helpful reports include your Mac (chip and memory), the macOS and DigUp versions, what you did or searched for, and
what you expected instead. Logs are in `~/Library/Application Support/DigUp/index.noindex` (`app.log` and
`indexer.log`). They can contain file names and your searches, so look through them before you paste.

For a security problem, please use "Report a vulnerability" on the Security tab instead of a public issue.
