# DigUp Atlas plan

Turn the DigUp fork into a macOS digital asset map for people who need to understand files across local and external volumes. Keep semantic suggestions separate from user decisions. Deliver D0, D1, D2, D3, and D4 in order. Do not delete, move, rename, or upload user files in this program.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs `pstack/skills/poteto-mode/playbooks/autopilot-stack.md`. The operator lands every PR. Every owner reports STACK-READY. D0, D1, D2, D3, and D4 stop for operator review.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [ ] State the protocol and this plan to the operator, then stop. Start execution only on the operator's explicit go.
- [ ] Read these from trunk at program start. Re-read them at every tick. If the fork does not vendor pstack, read the named installed skill and record that source instead.
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/autopilot-stack.md`
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/autopilot-full.md`
  - [ ] `git show origin/main:pstack/skills/swarm/SKILL.md`
  - [ ] `git show origin/main:scripts/ui/drive.sh`
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/opening-a-pr.md`
  - [ ] `git show origin/main:pstack/skills/architect/SKILL.md`
  - [ ] `git show origin/main:pstack/skills/how/SKILL.md`
  - [ ] `git show origin/main:pstack/skills/interrogate/SKILL.md`
  - [ ] `git show origin/main:pstack/skills/show-me-your-work/SKILL.md`
- [ ] On the operator's go, arm the audit tick as `/loop 1h` with the tick prompt below. Never leave the cadence to memory. Kimi Code has no `/loop`, so use its hourly scheduler with the same prompt.
- [ ] Use this tick prompt, verbatim. "Re-read the execution playbook from trunk. Audit the operation against it and fix drift in this tick. Probe every active lane and judge progress by side effects only. Stand down a stuck lane and dispatch its replacement now. Then post a short status message to the operator in chat only when the audit found a tracked change that no earlier status message reported, such as a PR opened, a code-ready head, a round launched or closed, a verdict, a merge, a stuck agent and the action taken, a blocker added or cleared, or a decision only the operator can make. Name every such change and nothing else. Do not repeat a table, the merged list, or an unchanged blocker. If the audit found none, end the turn with no reply text. Either way, log this tick's row in your decision trail. The row names the items reported, or none."
- [ ] On the operator's hold or stand-down, send every owner a zero-writes order at once.

### Spawn owners

- [ ] Spawn one owner per PR with the full lifecycle the execution playbook names.
- [ ] Follow this dependency graph. Start dependent work only after its parent merges, or base it on the parent branch when the execution playbook stacks.
  - [ ] D0 branches from the fork's `main` at upstream SHA `dc2651ad8299160bbe91e972f857e1a1599a8419`.
  - [ ] D1 after D0.
  - [ ] D2 after D1.
  - [ ] D3 after D2.
  - [ ] D4 after D3.
- [ ] Hold the file boundaries. D0 touches only the project plan, app identity, update-channel behavior, build scripts, and UI verification files. D1 touches only inventory, identity, sync, and their UI files. D2 touches only stable tags and their UI files. D3 touches only semantic suggestions, evaluations, and their UI files. D4 touches only offline availability, preview storage, and their UI files.
- [ ] Hold the review gate. D0, D1, D2, D3, and D4 change an interaction. They wait for the operator's review in chat with screenshots and a video before merge.

### PR mechanics, for every PR

- [ ] Resolve the forge once. Default to `gh`; if `command -v origin` succeeds and Origin can resolve the repository, use `origin pr` for every PR operation. Record any fallback to `gh`. Never require `gt`.
- [ ] Open the PR ready, never draft, per **Opening a PR**. Use the run's built-in PR tool when it has one, else `origin pr create --status open --base <base-branch>` or `gh pr create --base <base-branch>` according to the resolved forge. A stack child targets its parent branch.
- [ ] Run `scripts/build-llama.sh && swift build -c release && swift test` once before the PR-facing push. Push with hooks on.
- [ ] Apply the `unslop` skill before each commit and run `/no-comments` before review.
- [ ] Triage every Bugbot and security-reviewer comment per `../references/bugbot-triage.md`. Skip Bugbot in Kimi Code because it is unavailable.
- [ ] Keep owners on their assigned branches. Owners never rebase, retarget, merge, close a PR, or arm auto-merge. The root absorbs trunk drift with a bottom-up chain rebase and owns every base change.

### Verdict and merge, for every PR

- [ ] A full swarm runs once, at the code-ready head. Another full swarm runs only for new behavior, a redesign, or a large new diff. A rebase, a merge-conflict resolution, or a minor fix gets a single verifier at the new head. Run each full swarm per `pstack/skills/swarm/SKILL.md`. One gates lane. The ten live lanes from the PR's **Verify, live** block. The perf lane from its **Verify, perf** block. Two or more audit lanes, each with its own focus, that read the diff and the receipts and distrust the PR body. The root audits the receipts in the merge-ready report before the verdict.
- [ ] Clean only when every lane is `PASS`. Findings go back to the owner, including a defect that a lane filed as a note. A new head gets a fresh verdict, except for results that stay valid under the patch-id rule in `playbooks/shipping.md`.
- [ ] Append each clean PR in dependency order with its base set to its parent's branch. Compare `git patch-id` at the verdict SHA with the current head before trusting an older verdict. Rerun affected lanes when the patch or its build output changes. The root owns the chain, and the operator lands the contiguous verified run bottom-up.

### Boot recipe, for every live lane

Each live lane runs on its own isolated macOS VM at the PR head. Cursor cloud VMs and control skills are unavailable in Kimi Code. Use a macOS VM with Xcode 26 or later, ffmpeg, accessibility permission, and the pinned model files. Allow network access for the initial Homebrew and model downloads, then disable it for offline lanes. Drive the real app through `scripts/ui/drive.sh`, which uses AppleScript, Accessibility, and `screencapture`.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] Run `scripts/build-llama.sh && swift build -c release && swift test && ./build.sh`. Open `build.noindex/DigUpAtlas.app` and wait for the main window's accessibility identifier.
- [ ] Deliver user input only through `scripts/ui/drive.sh`. Use `sqlite3 -readonly`, `log show`, `stat`, `hdiutil`, and process inspection as read-only diagnostics. Create test volumes and fixture files only inside the lane's scratch directory.
- [ ] Save every screenshot to `/tmp/swarm-<pr-id>/worker-<n>/<slug>.png` and return the paths with the report.

## Establish the independent fork and UI verification baseline (D0)

**Depends on.** None.

**Files.**

- [ ] Create `docs/digup-atlas-plan.md`.
- [ ] Edit `Resources/Info.plist`.
- [ ] Edit `Sources/DigUpApp/AppSettings.swift`.
- [ ] Edit `Sources/DigUpApp/Updates.swift`.
- [ ] Edit `Sources/DigUpApp/AppController.swift`.
- [ ] Edit `Sources/DigUpApp/StatusMenu.swift`.
- [ ] Edit `Sources/DigUpApp/SettingsWindow.swift`.
- [ ] Edit `build.sh`.
- [ ] Create `scripts/ui/drive.sh`.
- [ ] Create `scripts/verify-fork.sh`.
- [ ] Create `Tests/DigUpKitTests/ForkIdentityTests.swift`.

**Build.**

- [ ] Set the display name to `DigUp Atlas`, replace the bundle identifier and UserDefaults domain, and keep the SwiftPM target names unchanged.
- [ ] Remove the upstream Sparkle feed and public key from the active configuration. Disable updater startup and remove or disable update controls until the fork has its own signed feed.
- [ ] Preserve `LICENSE` and `Resources/Acknowledgements.txt`, and include both in the packaged app.
- [ ] Add accessibility identifiers and a UI driver that can launch the app, select a fixture root, run a search, and capture the result.
- [ ] Keep the existing cross-platform source intact. Limit product support and verification to macOS.

**You see.**

- [ ] The packaged app launches as `DigUp Atlas` and never contacts the upstream update feed.
- [ ] The UI driver captures a semantic search result without changing the fixture files.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add `ForkIdentityTests` for independent defaults and disabled upstream updates. Run `scripts/verify-fork.sh && swift test --filter ForkIdentityTests` and then `swift test`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `k2.8-high` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `scripts/make-testbed.sh`, index the same fixture, and search for `football` at trunk and head. Save `fork-regression.png`. Pass when both return the same fixture asset and the head shows the new app identity.
- [ ] Lane 2. Launch the packaged app with no existing defaults. Save `fork-clean-launch.png`. Pass when the main window appears and no setup error mentions Sparkle.
- [ ] Lane 3. Seed upstream UserDefaults with a sentinel and launch the fork. Save `fork-defaults.png`. Pass when the fork has no sentinel and the upstream value is unchanged.
- [ ] Lane 4. Inspect the packaged license and acknowledgements through the driver. Save `fork-licenses.png`. Pass when the original MIT copyright and bundled-code notices are present.
- [ ] Lane 5. Run the update check with network logging enabled. Save `fork-updates.png`. Pass when no request targets `ARahim3/DigUp` and the app remains usable offline.
- [ ] Lane 6. Index a read-only fixture directory. Save `fork-read-only.png`. Pass when every source file's size, modification time, and content hash remains unchanged.
- [ ] Lane 7. Quit during an indexing batch and relaunch. Save `fork-restart.png`. Pass when the app resumes without a database migration or integrity error.
- [ ] Lane 8. Run the UI driver twice on the same fixture. Save `fork-driver-repeat.png`. Pass when both runs select the same asset and produce nonempty screenshots.
- [ ] Lane 9. Build and launch on a clean VM with only the documented prerequisites. Save `fork-clean-vm.png`. Pass when the driver reaches the main window without manual Xcode setup.
- [ ] Lane 10. Remove the model files and launch the app. Save `fork-model-missing.png`. Pass when the app reports the documented model-download state and does not crash.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Measure clean release build duration and cold launch to the main window at trunk and head on the same VM.
- [ ] Probe. Record one trunk measurement first, then alternate trunk and head three times. Use `/usr/bin/time` for the build and the UI driver's timestamp for launch.
- [ ] Baseline. Record the trunk median build duration and cold-launch duration before judging the head.
- [ ] Rule. Fail when the head median build or launch duration regresses by more than 10 percent, or when either side lacks a measurement.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2, lane 5, and lane 10 screenshots into `docs/media/D0-launch-review.png`, `docs/media/D0-updates-review.png`, and `docs/media/D0-model-missing-review.png`.
- [ ] Record a 30 to 60 second video of launch, disabled updates, and the model-missing state on a lane VM. Save it as `docs/media/D0-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at STACK-READY. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done where Bugbot exists.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends D0 to the base-branch stack and the operator lands it first.

## Build the read-only asset inventory (D1)

**Depends on.** D0.

**Files.**

- [ ] Edit `Sources/DigUpKit/IndexStore.swift`.
- [ ] Edit `Sources/DigUpKit/Indexer.swift`.
- [ ] Edit `Sources/DigUpApp/FolderWatcher.swift`.
- [ ] Edit `Sources/DigUpApp/Engine.swift`.
- [ ] Create `Sources/DigUpKit/AssetInventory.swift`.
- [ ] Create `Sources/DigUpApp/InventoryView.swift`.
- [ ] Create `Tests/DigUpKitTests/AssetInventoryTests.swift`.
- [ ] Create `Tests/DigUpKitTests/AssetIdentityTests.swift`.

**Build.**

- [ ] Define `AssetID`, `VolumeID`, `AssetLocation`, and `Availability` with states `available`, `unavailable`, and `deleted`. Never use a path as an asset ID.
- [ ] Migrate `files` to carry a persistent `asset_uuid`, and add volume metadata keyed by a volume UUID where macOS provides one. Preserve `asset_uuid` through `IndexStore.move` and content requeue. Compute a content fingerprint only for ambiguous delete-and-reinsert cases, and reuse the prior ID only when volume and content evidence match.
- [ ] Build `AssetInventory` as a read-only API over file, location, scan-state, and volume data. Do not change `segments` or trigger embedding for inventory reads.
- [ ] Persist FSEvents event IDs and handle rescan flags. Reconcile missed events with metadata scans without re-embedding unchanged content.
- [ ] Add an inventory view that groups assets by kind and volume and distinguishes discovered, analyzed, unreadable, and unavailable items.
- [ ] Keep deletion, file moves, renaming, and cleanup actions out of the UI.

**You see.**

- [ ] A user opens the app and browses the authorized asset inventory without entering a search query.
- [ ] Ejecting a volume changes its assets to `unavailable` without deleting their records.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add `AssetIdentityTests` for same-volume moves, copies, content edits, inode reuse guards, and volume remounts. Run `swift test --filter AssetIdentityTests`.
- [ ] Add `AssetInventoryTests` for availability, unreadable files, vanished roots, event replay, Unicode paths, and zero embedding on metadata-only reconciliation. Run `swift test --filter AssetInventoryTests` and then `swift test`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `k2.8-high` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Index the standard testbed and run the same semantic query at trunk and head. Save `inventory-regression.png`. Pass when the head preserves the trunk result and also lists the asset in the inventory.
- [ ] Lane 2. Index a manifest-backed fixture with 20,000 files. Save `inventory-complete.png`. Pass when the inventory counts match the manifest by kind and scan state.
- [ ] Lane 3. Move 1,000 unchanged files within one test volume. Save `inventory-move.png`. Pass when every asset keeps its ID and the embedding counter remains unchanged.
- [ ] Lane 4. Modify one indexed document. Save `inventory-edit.png`. Pass when only that asset receives new segments and its ID remains stable.
- [ ] Lane 5. Detach a test DMG during an active scan. Save `inventory-eject.png`. Pass when its known assets become unavailable and no asset record is deleted.
- [ ] Lane 6. Remount the same DMG at a different mount path. Save `inventory-remount.png`. Pass when existing assets become available without duplicate IDs or re-embedding unchanged files.
- [ ] Lane 7. Change files while the app is stopped, then relaunch. Save `inventory-restart.png`. Pass when event replay or reconciliation produces the same inventory as a fresh metadata scan.
- [ ] Lane 8. Add and rename files below a directory named `Photos.v2`. Save `inventory-dotted-path.png`. Pass when the watcher schedules the changes and the inventory matches the fixture.
- [ ] Lane 9. Revoke read permission from one fixture directory. Save `inventory-unreadable.png`. Pass when the UI names the unreadable scope and preserves its last known records.
- [ ] Lane 10. Index duplicate names with precomposed and decomposed Unicode paths. Save `inventory-unicode.png`. Pass when each real file has one inventory row and no unique-constraint error occurs.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Measure no-op metadata sync duration on the 20,000-file fixture at trunk and head. Also measure the head's 1,000-file move reconciliation and inventory opening time.
- [ ] Probe. Record one trunk no-op sync first, then alternate trunk and head three times. Run the head-only move and inventory probes three times with the same fixture.
- [ ] Baseline. Record the trunk median no-op sync duration before judging the head.
- [ ] Rule. Fail when the head no-op sync median regresses by more than 10 percent, move reconciliation exceeds 10 seconds, inventory opening exceeds 2 seconds, or any unchanged file is re-embedded.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2, lane 5, and lane 6 screenshots into `docs/media/D1-inventory-review.png`, `docs/media/D1-eject-review.png`, and `docs/media/D1-remount-review.png`.
- [ ] Record a 30 to 60 second video of the inventory, eject, and remount flow on a lane VM. Save it as `docs/media/D1-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at STACK-READY. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done where Bugbot exists.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends D1 after D0 and the operator lands it bottom-up.

## Keep user tags stable across indexing changes (D2)

**Depends on.** D1.

**Files.**

- [ ] Edit `Sources/DigUpKit/IndexStore.swift`.
- [ ] Edit `Sources/DigUpKit/Indexer.swift`.
- [ ] Create `Sources/DigUpKit/Tags.swift`.
- [ ] Create `Sources/DigUpApp/TagsView.swift`.
- [ ] Create `Tests/DigUpKitTests/TagsTests.swift`.

**Build.**

- [ ] Define stable `TagID` values and `tags` plus `tag_decisions` tables. Reference `asset_uuid`, never a file path or a vector row.
- [ ] Support confirmed and manually removed decisions in one transaction with the asset lookup. Give every user decision one writer through `IndexStore`.
- [ ] Keep asset and tag tables when a model fingerprint reset rebuilds derived segments. Preserve tags across file moves, content reindexing, model resets, volume ejects, and app restarts. Treat a confirmed copy as a separate asset unless identity evidence proves otherwise.
- [ ] Add a topic view for creating, renaming, merging, and removing user tags without moving or renaming source files.
- [ ] Allow multiple tags per asset and keep tag names independent from folder names.
- [ ] Do not generate semantic tags in this PR.

**You see.**

- [ ] A user organizes assets into stable topics and keeps those topics after files move or the semantic index rebuilds.
- [ ] Renaming a topic changes one label without changing file locations or embedding counts.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add `TagsTests` for create, rename, merge, multiple tags, moves, reindexing, model resets, copies, deletes, unavailable volumes, and concurrent writes. Run `swift test --filter TagsTests` and then `swift test`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `k2.8-high` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Trunk has no stable tags. Record that fact, run the standard semantic search at both revisions, and create a tag at head. Save `tags-regression.png`. Pass when search results stay equivalent and the new tag survives restart.
- [ ] Lane 2. Create a `Football` tag and assign two videos from different folders. Save `tags-create.png`. Pass when both assets appear under one topic without file changes.
- [ ] Lane 3. Rename `Football` to `Football matches`. Save `tags-rename.png`. Pass when every assignment remains and no embedding runs.
- [ ] Lane 4. Assign `Travel` and `Family` to the same photo. Save `tags-multiple.png`. Pass when the photo appears in both topics and physical size is counted once.
- [ ] Lane 5. Move 100 tagged files within a volume. Save `tags-move.png`. Pass when all asset IDs and tag assignments remain unchanged.
- [ ] Lane 6. Rebuild the semantic index with a changed model fingerprint. Save `tags-model-reset.png`. Pass when all user tags and assignments remain after the rebuild.
- [ ] Lane 7. Eject and remount a tagged test volume. Save `tags-volume.png`. Pass when tags remain visible while unavailable and reopen the original files after remount.
- [ ] Lane 8. Copy a tagged file and tag only the copy. Save `tags-copy.png`. Pass when the two assets have independent tag decisions.
- [ ] Lane 9. Delete one fixture file through Finder and reconcile. Save `tags-delete.png`. Pass when the active inventory marks it deleted without deleting its audit record or changing other tags.
- [ ] Lane 10. Merge two tags with overlapping assets. Save `tags-merge.png`. Pass when the result has no duplicate assignments and the operation survives restart.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Measure semantic search latency on the standard fixture at trunk and head. Also measure renaming one tag assigned to 10,000 assets at head.
- [ ] Probe. Record trunk search latency first, then alternate trunk and head five times. Run the head-only tag rename three times.
- [ ] Baseline. Record trunk median and 95th-percentile search latency before judging the head.
- [ ] Rule. Fail when head 95th-percentile search latency regresses by more than 10 percent, tag rename exceeds 1 second, or the rename triggers embedding.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2, lane 4, and lane 6 screenshots into `docs/media/D2-create-review.png`, `docs/media/D2-multiple-review.png`, and `docs/media/D2-model-reset-review.png`.
- [ ] Record a 30 to 60 second video of tag creation, rename, and model rebuild on a lane VM. Save it as `docs/media/D2-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at STACK-READY. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done where Bugbot exists.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends D2 after D1 and the operator lands it bottom-up.

## Add semantic suggestions without changing user decisions (D3)

**Depends on.** D2.

**Files.**

- [ ] Edit `Sources/DigUpKit/IndexStore.swift`.
- [ ] Edit `Sources/DigUpKit/Searcher.swift`.
- [ ] Edit `Sources/digup/main.swift`.
- [ ] Create `Sources/DigUpKit/SemanticSuggestions.swift`.
- [ ] Create `Sources/DigUpApp/SuggestionsView.swift`.
- [ ] Create `Tests/DigUpKitTests/SemanticSuggestionsTests.swift`.
- [ ] Create `evals/asset-topics.json`.

**Build.**

- [ ] Define `TagSuggestion` with asset ID, tag ID, confidence, model version, and state. Store suggestions separately from `tag_decisions`.
- [ ] Aggregate segment scores into file-level suggestions. Use existing tags first and leave low-confidence assets unclassified.
- [ ] Generate candidate topic clusters for unlabeled assets. Keep clusters disposable until the user confirms a topic.
- [ ] Write acceptance or rejection through the user-decision API. Suppress rejected suggestions across scans and model updates.
- [ ] Record suggestion source and model version so a user can inspect why a label appeared.
- [ ] Build a labeled multimodal evaluation set and a repeatable `digup eval asset-topics` command. Do not train on unconfirmed suggestions.
- [ ] Keep automatic file moves, automatic deletion, and silent tag assignment out of the product.

**You see.**

- [ ] A user reviews content-based topics and suggestions, then accepts or rejects them without losing prior decisions.
- [ ] A model update changes suggestions only, never confirmed or rejected user decisions.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add `SemanticSuggestionsTests` for segment aggregation, confidence thresholds, multiple topics, acceptance, rejection, model upgrades, unconfirmed training exclusion, and empty corpora. Run `swift test --filter SemanticSuggestionsTests` and then `swift test`.
- [ ] Run `digup eval asset-topics` against `evals/asset-topics.json`. Pass when top-three suggestion recall reaches at least 85 percent and every low-confidence fixture remains unclassified.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `k2.8-high` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Trunk has no topic suggestions. Record that fact, run the standard semantic search at both revisions, and inspect suggestions at head. Save `suggestions-regression.png`. Pass when search stays equivalent and suggestions remain separate from user tags.
- [ ] Lane 2. Create a user tag named `Football`, then index videos with opaque filenames and known football content. Save `suggestions-football.png`. Pass when the app suggests `Football` with evidence and does not confirm it automatically.
- [ ] Lane 3. Accept one suggestion. Save `suggestions-accept.png`. Pass when exactly one user decision is created and it survives reindexing.
- [ ] Lane 4. Reject one suggestion and rescan twice. Save `suggestions-reject.png`. Pass when the rejected label does not return as a new suggestion.
- [ ] Lane 5. Change the model version and regenerate suggestions. Save `suggestions-model-update.png`. Pass when confirmed and rejected decisions remain unchanged.
- [ ] Lane 6. Review a video with football and travel segments. Save `suggestions-multitopic.png`. Pass when the file can hold both suggestions and its physical size is counted once.
- [ ] Lane 7. Index ambiguous and low-confidence assets. Save `suggestions-unclassified.png`. Pass when they remain unclassified and no broad label is forced.
- [ ] Lane 8. Start with no user tags and inspect candidate clusters. Save `suggestions-cold-start.png`. Pass when candidates remain disposable and no source file moves.
- [ ] Lane 9. Disable networking and generate suggestions. Save `suggestions-offline.png`. Pass when all processing completes locally and no network request leaves the VM.
- [ ] Lane 10. Run the labeled evaluation through the app and inspect one incorrect suggestion. Save `suggestions-audit.png`. Pass when source, confidence, and model version explain the suggestion and the user can reject it.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Measure standard semantic search latency at trunk and head. Also measure suggestion generation for 100 images and peak helper memory at head.
- [ ] Probe. Record trunk search latency first, then alternate trunk and head five times. Run the head-only suggestion probe three times on the same 100-image fixture.
- [ ] Baseline. Record trunk median and 95th-percentile search latency before judging the head.
- [ ] Rule. Fail when head 95th-percentile search latency regresses by more than 10 percent, suggestion generation exceeds 60 seconds, or peak helper memory exceeds 2 GB on the reference VM.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2, lane 4, and lane 8 screenshots into `docs/media/D3-football-review.png`, `docs/media/D3-reject-review.png`, and `docs/media/D3-cold-start-review.png`.
- [ ] Record a 30 to 60 second video of suggestion review, rejection, and cold-start clustering on a lane VM. Save it as `docs/media/D3-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at STACK-READY. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done where Bugbot exists.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends D3 after D2 and the operator lands it bottom-up.

## Browse disconnected volumes with local previews (D4)

**Depends on.** D3.

**Files.**

- [ ] Edit `Sources/DigUpKit/IndexStore.swift`.
- [ ] Edit `Sources/DigUpApp/Engine.swift`.
- [ ] Edit `Sources/DigUpApp/AddFolders.swift`.
- [ ] Create `Sources/DigUpKit/OfflinePreviewStore.swift`.
- [ ] Create `Sources/DigUpApp/OfflineLibraryView.swift`.
- [ ] Create `Sources/DigUpApp/PreviewCache.swift`.
- [ ] Create `Tests/DigUpKitTests/OfflinePreviewStoreTests.swift`.

**Build.**

- [ ] Define `PreviewKind` for image thumbnails, video contact sheets, and representative document pages. Key each preview by asset ID and content version.
- [ ] Store preview files and metadata on the Mac under the fork's application-support directory. Never copy an original asset into the preview cache.
- [ ] Add per-volume preview modes for index only, standard previews, and enhanced previews. Enforce a user-set byte budget and report files without previews.
- [ ] Keep unavailable assets in search results with their volume name, last known path, tags, and available previews. Require reconnection before opening the original.
- [ ] Invalidate stale previews after content changes and preserve confirmed tags when a preview is evicted.
- [ ] Add a per-volume action that deletes only derived indexes and previews after explicit confirmation. Keep source files untouched.
- [ ] Treat cloud placeholders as unavailable local content and do not trigger a download for offline preview generation.

**You see.**

- [ ] A user finds an asset on a disconnected volume, recognizes it from a local preview, and learns which volume to reconnect.
- [ ] Deleting a volume's derived cache removes no source file and no user tag.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add `OfflinePreviewStoreTests` for cache keys, content invalidation, budgets, eviction, unavailable search, volume identity, cache deletion, cloud placeholders, and crash recovery. Run `swift test --filter OfflinePreviewStoreTests` and then `swift test`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `k2.8-high` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Trunk hides missing files from search. Record that fact, run the same online search at both revisions, detach the test volume, and repeat at head. Save `offline-regression.png`. Pass when online results stay equivalent and the head returns an unavailable result with volume details.
- [ ] Lane 2. Index photos from a test DMG and detach it. Save `offline-photos.png`. Pass when thumbnails remain visible and the original-open action asks for that DMG.
- [ ] Lane 3. Index videos and inspect their offline contact sheets. Save `offline-videos.png`. Pass when each sheet represents the correct video and full playback requires reconnection.
- [ ] Lane 4. Index PDFs and inspect representative pages offline. Save `offline-documents.png`. Pass when the user can identify each document without reading the original volume.
- [ ] Lane 5. Remount a DMG at a different path and open a result. Save `offline-remount.png`. Pass when volume identity reconciles and the correct original opens without duplicate assets.
- [ ] Lane 6. Modify one source file while the volume is connected. Save `offline-invalidate.png`. Pass when the old preview is invalidated and only the changed content is regenerated.
- [ ] Lane 7. Set a 50 MB preview budget on a fixture that exceeds it. Save `offline-budget.png`. Pass when cache bytes stay within budget and the UI names assets without previews.
- [ ] Lane 8. Delete the derived cache for a disconnected volume. Save `offline-privacy.png`. Pass when previews and semantic data are removed while source files and user tags remain intact.
- [ ] Lane 9. Kill the app during preview generation and relaunch. Save `offline-crash.png`. Pass when partial previews are discarded or completed idempotently and the database passes integrity checks.
- [ ] Lane 10. Index a File Provider placeholder fixture while offline. Save `offline-placeholder.png`. Pass when no download starts and the asset is labeled as not stored locally.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Measure online semantic search latency at trunk and head. Also measure offline result latency, cache bytes, and preview generation duration at head.
- [ ] Probe. Record trunk online search latency first, then alternate trunk and head five times. Run the head-only offline probe three times on a 10,000-image DMG fixture.
- [ ] Baseline. Record trunk median and 95th-percentile online search latency before judging the head.
- [ ] Rule. Fail when head online 95th-percentile latency regresses by more than 10 percent, offline results exceed 2 seconds, standard previews exceed 500 MB, or preview generation exceeds 10 minutes.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2, lane 5, and lane 7 screenshots into `docs/media/D4-photos-review.png`, `docs/media/D4-remount-review.png`, and `docs/media/D4-budget-review.png`.
- [ ] Record a 30 to 60 second video of offline search, volume reconnection, and cache budgeting on a lane VM. Save it as `docs/media/D4-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at STACK-READY. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done where Bugbot exists.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends D4 after D3 and the operator lands it bottom-up.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with the report the execution playbook names.

## Appendix A. Prototype evidence

No pre-plan prototype ran because no empirical fork blocked writing this plan. There is no prototype branch or screenshot set. The source baseline is upstream SHA `dc2651ad8299160bbe91e972f857e1a1599a8419` in `.research/DigUp`.

The following questions remain unproven. D1 must measure asset identity collisions and remount behavior before fixing the production identity rules. D2 must prove that user decisions survive delete-and-reinsert paths. D3 must measure file-level suggestion quality and search cost at 100,000 or more segments. D4 must prove volume identity, File Provider behavior, and cache budgets on real macOS VMs. No build, test, or app run was performed during planning.

## Appendix B. Alternatives rejected

A direct rewrite of the existing search UI lost because inventory, user decisions, and derived suggestions need separate ownership. A separate vector database lost because the current SQLite store already provides transactions and migrations, and no measured scale failure justifies a new service. Path-keyed tags lost because moves and remounts change paths. Full re-clustering after every scan lost because it rewrites the user's organization. Destructive cleanup lost because the upstream has no trash, restore, or backup model. Removing Windows and Linux source lost because deletion adds divergence without improving the macOS user experience. Physical-drive-only tests lost because DMG mounts provide repeatable eject and remount scenarios on macOS VMs.

## Appendix C. Risks

D0 owns update-channel isolation and UI-driver reliability. Watch for upstream identifiers in packaged resources and Accessibility permission failures. D1 owns identity and sync correctness. Watch inode reuse, copy-versus-move ambiguity, dotted paths, Unicode normalization, missed FSEvents, and database writers. D2 owns durability of user work. Watch forced migrations, model resets, delete-and-reinsert paths, and concurrent writes. D3 owns suggestion quality and resource use. Watch segment-to-file aggregation, low-confidence labels, unconfirmed training data, and the existing brute-force vector ceiling. D4 owns privacy and availability. Watch stale previews, cache growth, volume UUID absence, cloud downloads, and the difference between unavailable and deleted content.

The repository has no native macOS control or verification skill. D0 must establish `scripts/ui/drive.sh` before later UI claims can pass. If the driver cannot operate a control reliably, stop the affected lane and fix the driver instead of replacing the live check with a unit test.

## Appendix D. Links and reading list

Read the upstream source at [the pinned DigUp revision](https://github.com/ARahim3/DigUp/tree/dc2651ad8299160bbe91e972f857e1a1599a8419). Start with `Package.swift`, `Sources/DigUpKit/IndexStore.swift`, `Sources/DigUpKit/Indexer.swift`, `Sources/DigUpApp/Engine.swift`, `Sources/DigUpApp/FolderWatcher.swift`, `LICENSE`, `Resources/Acknowledgements.txt`, and `CONTRIBUTING.md`.

Run `pstack/skills/how/SKILL.md` and `pstack/skills/architect/SKILL.md` before D1, D2, D3, and D4. Run `pstack/skills/interrogate/SKILL.md` on the D1 identity design and the D3 suggestion design before implementation. Run `pstack/skills/benchmark-checklist/SKILL.md` before reporting measured performance or evaluation results.

Keep the planning trail at `.audit/digup-atlas-plan.tsv` under `pstack/skills/show-me-your-work/SKILL.md`. Keep execution trails local unless a reviewer needs them committed. The attached research conversation informs scope but does not count as runtime evidence.
