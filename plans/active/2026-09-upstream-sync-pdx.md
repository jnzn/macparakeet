# Upstream Sync — PDX Fork Reconciliation

> Status: ACTIVE PLAN
> Date: 2026-09-21
> Scope: reconcile `feature/pdx-next` (branched off local `main`, frozen at
> `ff48f33f` / 2026-05-29) with upstream `moona3k/macparakeet` (`upstream/main`
> at `bbae9e0e` / 2026-09-21, 3670 commits ahead of local `main`).

## Problem

Local `main` has not synced with upstream in ~4 months. `feature/pdx-next`
carries ~50 PDX-specific commits on top of that stale base. Upstream has
shipped a large amount of independent work in the same window, including two
areas where PDX built its own solution to a problem upstream also solved.

## Inventory

### A. Pure upside — safe to bring in, no PDX overlap
- ADR-026 — capability-registry ASR engine selection (adds Nemotron 3.5 Beta,
  Cohere Transcribe alongside Parakeet v2/v3/Unified and WhisperKit)
- ADR-027 — product north star (doc only)
- ADR-029 — encrypted share snapshots
- ADR-030 — external meeting import
- ADR-031 — segment-timed transcript corrections
- ADR-033 — explicit voice control
- App-aware AI Formatter toggles (#428, #856) — different layer than PDX's
  `SpokenTextFormatter` chain, no collision

### B. Conflicting — needs a deliberate decision, not auto-resolved
1. **Meeting auto-stop.** ADR-023 exists on both sides with genuinely
   different implementations.
   - PDX: mic-acquired-by-other-process detection + configurable call-app
     allowlist (Phase 1.5, 2026-06-02)
   - Upstream: sustained dual-channel silence + app-quit fast path + veto
     countdown, backed by a new ADR-024 activity-signal layer (CoreAudio
     process attribution + camera detection); shipped v0.7.0–v0.7.2
   - Direction: adopt upstream's detector; port PDX's call-app allowlist as a
     refinement on top rather than keeping both designs.
2. **Meeting echo/AEC cancellation.**
   - PDX: small echo conditioner (PDX-005/006/009 — sample-rate validation,
     dlsym ABI workaround; PDX-005's integrity-verification piece was
     reverted by owner)
   - Upstream: full ADR-028 pipeline (`MeetingCleanedMicRenderer`,
     delay-aligned system-audio reference, checksum-verified echo model)
   - Direction: retire PDX's conditioner in favor of ADR-028.

### C. PDX-unique — no upstream equivalent, preserve as-is
- Bounded, drop-counted meeting live-ingest queue (PDX-001/002)
- `llm_runs` ledger retention sweep (PDX-012)
- Transforms fail-pill double-fire fix (PDX-018)
- `SpokenTextFormatter` normalizer chain (currency/unit/date/time/phone/
  email/ordinal/year/symbol/punctuation)
- Voice Return Send/Hold mode
- Recording-deletion Trash flow, parakeet-motif recording animations,
  Meetings Intelligence badge fix, and other remaining PDX commits not
  otherwise noted above

## Execution plan (this pass)

1. Do not touch `main` or `feature/pdx-next` directly.
2. Create scratch branch `pdx-next-upstream-sync` from `feature/pdx-next`.
3. `git rebase --onto upstream/main main` — replays only the ~50 PDX-specific
   commits (`main..feature/pdx-next`) on top of upstream's full history. The
   46 commits by which local `main` led upstream are excluded from the range
   on purpose: their content is presumed already folded into upstream under
   different hashes.
4. Resolve conflicts:
   - Known hard zones (auto-stop, echo/AEC files) → skip, log as deferred,
     do not attempt automatic resolution.
   - Everything else → resolve directly if mechanical/non-semantic (doc
     drift, ADR table churn); escalate anything non-obvious instead of
     guessing.
5. Report what replayed cleanly, what was skipped, and what remains for
   manual reconciliation.

## Progress log (2026-09-21)

Scratch branch `pdx-next-upstream-sync` created from `feature/pdx-next`, then
`git rebase --onto upstream/main main` started (107 PDX-only commits to
replay). Status so far, in commit order:

1. `e4c93674` (auto-export raw text only) — **resolved and applied.**
   Upstream had independently added an `AutoSaveResult` enum + telemetry
   around the same code; kept upstream's addition, wired the PDX commit's
   forced-raw `contentOptions` into the actual export calls (git's conflict
   markers left it computed but unused), removed the three now-dead
   per-scope include-toggle properties/UI/tests the commit was meant to
   remove. New commit: `9d2edb59`.
2. (clean) — applied without conflict.
3. `ce750c1b` (docs: ADR-023 proposal) — **skipped.** Add/add conflict on
   `spec/adr/023-activity-based-meeting-auto-stop.md`: both sides created a
   different ADR-023. This is the known auto-stop hard zone from the
   inventory above (section B.1) — needs a deliberate decision, not a merge.
4. (clean) — applied without conflict.
5. `59e8aa9e` (movable AI bubble) — **skipped.** Modify/delete conflict:
   upstream removed the entire "AI Assistant bubble" feature (no trace of it
   anywhere in `upstream/main`, not renamed). This is a **new decision
   point** not in the original inventory: does PDX want to keep an
   AI-Assistant-bubble UI as a PDX-exclusive feature (there may be more
   commits on it later in the sequence), or follow upstream's removal?
6. `1c20664a` (bash 3.2 compat fix) — **skipped/moot.** Patches
   `build_cli_swiftpm()`/`swiftpm_release_bin_dir()`'s handling of
   `${build_path_args[@]}` for bash 3.2's `set -u`. Upstream refactored both
   into a generic `build_swiftpm_helper()` that never references
   `build_path_args` at all — the `SWIFT_CLI_BUILD_PATH` override feature
   this guarded is gone from upstream's own script entirely. Took upstream's
   version as-is.
7. (clean) — applied without conflict.
8. **Paused here.** `16d64b75` (deterministic spoken-number → digit
   normalization in dictation) conflicts across 5 core files at once
   (`AppEnvironment.swift`, `AppRuntimePreferences.swift`,
   `DictationService.swift`, `TextProcessingPipeline.swift`,
   `TextRefinementService.swift`). This is the first of roughly 15-20
   sequential commits building the entire `SpokenTextFormatter` chain
   (section C in the inventory) — a real feature integration into core
   pipeline files, not a quick conflict resolution. Left the rebase paused
   mid-conflict on `pdx-next-upstream-sync` rather than rushing it; resume
   with `git rebase --continue` (or `--abort` to bail) once ready to review
   this chunk properly.

### Side finding: exposed private key

Checking out upstream's `.gitignore` (via the rebase) revealed
`scripts/dev/MacParakeetPDX.p12` and `seeds/app-profiles.local.json` are
untracked *and not covered by any current ignore rule* — they were
presumably hidden before by patterns in the old `.gitignore` that upstream's
version dropped. Do not run `git add -A` on this branch until ignore rules
are restored for these paths.

## Progress log (2026-09-21, session 2 — corrected range)

**Root cause found and fixed:** the original range (`main..feature/pdx-next`,
107 commits) was wrong. Local `main` carries 46 commits ahead of
`upstream/main` that the original plan assumed were "already folded into
upstream" — verified false for 36 of them (all `(pdx)`-tagged, genuinely
unreplayed PDX work: the `AppProfile` foundation, terminal symbol expansion,
Voice Memo, AI Assistant bubble, streaming overlay, Tailscale/LAN networking,
forest-green rebrand, telemetry/entitlements/Sparkle/Discover customizations).
The other 10 are genuine upstream PRs (#385/#387/#390/#391/#394) already
merged upstream under different hashes — correctly excludable.

**Corrected range:** `ad96ba11` (actual merge-base of `upstream/main` and
`main`) → `feature/pdx-next` = **153 commits**, rebased onto `upstream/main`.
First rebase attempt (107-commit range) was aborted; scratch branch
`pdx-next-upstream-sync` redone from scratch with the corrected range.

**1Password signing gotcha:** `git rebase --continue`'s internal commit step
sometimes fails with `error: 1Password: failed to fill whole buffer` /
`fatal: failed to write commit object` (SSH-agent signing flake). **Do not
work around this by manually running `git commit` outside `--continue`** —
that desyncs the rebase sequencer's bookkeeping in a way that never recovers
(confirmed twice; only fix was `git rebase --abort` + redo from scratch).
The reliable fix is simply to retry `git rebase --continue` itself (no
manual commit) — it eventually succeeds. Needs `dangerouslyDisableSandbox:
true` in this harness for the retry loop to see the real exit code (sandboxed
Bash + `| tail` masks it as exit 0).

**Commits replayed and verified (build succeeds, diffed against
`upstream/main` pristine to confirm no accidental HEAD/theirs inversion),
in order:**
1. `a3465879` chore(pdx): remove Sparkle auto-update — also fully removes
   Discover (the commit's real diff does more than its message says).
   6 files: Package.swift, AppWindowCoordinator.swift, AppDelegate.swift,
   MainWindowView.swift, SettingsView.swift, build_app_bundle.sh (incl.
   dropping the now-orphaned SUPublicEDKey release-gate upstream added since).
2. `6f8a7aab` chore(pdx): remove Discover sidebar — applied with zero
   conflict (commit 1 already did the real work).
3. `7d682411` feat(pdx): feedback mailto card — FeedbackView.swift rewritten
   to a mailto card, dropping upstream's in-app form + new diagnostic-log
   additions that lived in the same View.
4. `60059129` chore(pdx): hard-disable telemetry — AppPreferences.swift +
   SettingsView.swift privacyCard removal.
5. `d0daf385` chore(pdx): entitlements bootstrap no-ops — EntitlementsService
   bootstrap/refresh become no-ops; Package.resolved re-synced via
   `swift package resolve` (don't hand-edit lockfiles).
6. `5e13bf44` feat(pdx): forest-green rebrand + PDX strings — DesignSystem
   accent colors + "(PDX Edition)" window/menu titles across 3 files + 2
   binary icon assets (auto-merged clean).
7. `1657b92f` feat(pdx): LAN/Tailscale networking + CLI PATH detection — new
   OllamaReachability/OllamaURLValidator files; LocalCLIExecutor merged with
   upstream's own independently-added `pathDiscoveryLock` double-checked
   locking (kept upstream's structure, folded in PDX's `userBinDirsPATH`).
8. `0c9c7eb6` feat(pdx): meeting auto-save content options — **mostly
   redundant**: upstream had already convergently built the same
   `TranscriptExportOptions` feature. ExportService.swift ended up
   byte-identical to upstream after resolution (verified via diff).
   **Caught and fixed a real mistake here**: misread which side was HEAD on
   the very first hunk (added a stray `@MainActor` to the protocol that
   belonged to PDX's stale snapshot, not HEAD) — broke `ExportCommand.swift`
   CLI actor-isolation. Caught via `swift build`, fixed by diffing the whole
   file against `git show upstream/main:<path>`. **Lesson: for any file
   where the conflict looks like "mostly redundant/convergent," diff the
   resolved file against upstream/main pristine before moving on — don't
   trust visual "which side looks more evolved" judgment alone.**
9. `9588c261` feat(pdx): AI title generation for library cards — genuinely
   new feature (TitleSanitizer.swift, LLMService.generateTitle,
   TranscriptionLibraryViewModel title generation + UI). Verified clean via
   upstream diff (pure additive, no reverted upstream content).
10. (clean) — applied without conflict.

**Currently paused mid-conflict, commit 11 of 152:**
`ead77d04` test(pdx): adapt upstream tests to PDX behavior (telemetry off,
Tailscale URL message). Progress:
- `Tests/CLITests/ConfigCommandTests.swift` — applied clean.
- `Tests/MacParakeetTests/TelemetryServiceTests.swift` — **resolved**, kept
  HEAD's `defer { removePersistentDomain }` cleanup + PDX's
  `XCTAssertFalse`/comment. Not yet staged.
- `Tests/MacParakeetTests/ViewModels/LLMSettingsViewModelTests.swift` —
  **NOT YET RESOLVED**, still has 11 conflict-marker blocks. Diffed the
  original commit's before/after (CRLF-stripped) and confirmed **only one
  genuine semantic change exists in the whole 929-line diff**: the
  `.invalidBaseURL` validation-message assertion (already correctly
  auto-merged at line ~403, matching commit 7's wording — nothing to do
  there). All 11 remaining conflict hunks checked so far are upstream simply
  being more current than PDX's old test snapshot (e.g. hunk at line
  ~305: HEAD expects `"claude-sonnet-5"`, PDX's stale snapshot expected
  `"claude-sonnet-4-6"` — take HEAD). **Resume plan: take HEAD's side for
  every remaining hunk in this file** (verified safe via the before/after
  diff — PDX's side contributes nothing new here), then verify with
  `diff <(git show upstream/main:Tests/MacParakeetTests/ViewModels/LLMSettingsViewModelTests.swift) Tests/MacParakeetTests/ViewModels/LLMSettingsViewModelTests.swift`
  before staging.

### Decision: App Profiles — merge into upstream's `AIFormatterProfile`, drop PDX's parallel editor

Resolving commit 13 (`b26b5e29` feat(pdx): wire per-app profile + AX context
into dictation pipeline) surfaced a large duplicate-feature discovery:
upstream independently built a complete, GRDB-persisted, UI-editable
per-app/per-category AI-formatter-prompt system (`AIFormatterProfile` +
`AIFormatterProfileMatcher`, editor already live in Settings → AI) that does
the same job as PDX's own in-progress "App Profiles" feature.

**Compared:**
- Upstream: matches by specific app **or app category** (8 built-in
  categories with smart-default prompts), fallback chain app→category→smart
  default→global prompt, full CRUD editor in Settings → AI. No live test/
  preview. No privacy split (n/a — it's the public repo itself).
- PDX's plan (spec `docs/superpowers/specs/2026-05-31-app-profiles-editor-design.md`,
  ~22 unreplayed commits): bundle-only matching (no categories), dedicated
  top-level sidebar section, live **"Try it"** preview tester, and a
  **privacy split** — 3 generic prompts committed publicly, the user's real
  prompts load silently from a gitignored local seed
  (`seeds/app-profiles.local.json` → bundled at build time via
  `scripts/dist/build_app_bundle.sh`), documented in the private vault.

**Decision (user, 2026-09-21):** merge — keep upstream's `AIFormatterProfile`
as the system of record (superior matching model, already shipped, already
integrated into Settings → AI). Do NOT replay PDX's parallel editor/sidebar/
seeding commits. Instead, port PDX's two genuinely-missing capabilities as
new work **on top of** `AIFormatterProfile`:
1. A live "Try it" preview in the `AIFormatterProfile` editor (adapt the
   design from `4648cd49`'s tester, wire to the existing LLM service).
2. The privacy-split seed mechanism (adapt `fd53bac0` /
   `c8798d6d` / `63230e8f`'s generic-committed-samples + gitignored-local-seed
   pattern onto `AIFormatterProfile`'s own seeding/defaults, not
   `AppProfile`'s).

This is separate follow-up work, not part of the mechanical rebase — it
needs real design/adaptation, not a conflict resolution. **Not started yet.**

**Commits skipped as superseded** (removed from `git-rebase-todo` via
`git rebase --edit-todo` rather than resolved) — all verified scoped
purely to PDX's own App Profiles model/editor/sidebar, no unrelated files:
`a7268d9b`, `e702b6e3`, `0747da27`, `c05c6359`, `b715335f`, `fd53bac0`,
`c8798d6d`, `b117201b`, `b01fd8f6`, `fbafe7ed`, `4648cd49`, `09eec442`,
`63230e8f`, `110c642c`, `d9f3199a`, `c9b64e6a`, `2d05c7ed`, `05bf160c`,
`093124a0`, `2027b182`, `c4971c47`, `6cfe6e36`.

Note: `b26b5e29` itself (currently being resolved, wires `AppProfile` +
`AppContext` into `DictationService`) was kept but adapted — it does NOT
wire `AppProfile.promptOverride` into the AI-formatter prompt path (upstream's
`aiFormatterPromptResolver` owns that now); it DOES keep the genuinely novel
AX-context-injection piece (`AIFormatter.injectContextIntoPrompt`, layered on
top of whichever template `aiFormatterPromptResolver` picks) since upstream
has no equivalent. `AppProfile.swift` (the model) and `activeProfile` stay
wired up on `DictationService` since a later, not-yet-reached PDX commit
(terminal-profile detection in the deterministic pipeline) depends on
`AppProfile`, not `AIFormatterProfile` — separate concern, unaffected by
this decision.

### Decision: streaming dictation preview — keep upstream's, port two pieces later

Same pattern as App Profiles, hit at commit 15 (`beb363c7` feat(pdx):
streaming dictation transcriber core + broadcaster). Upstream already ships
a complete, **default-on** live dictation preview: true streaming ASR
(`STTLiveDictationTranscribing` protocol, partial-result callback, session +
degradation handling, `liveTranscriptStabilizer`) feeding a word/character-
budgeted preview panel in the dictation overlay bubble
(`DictationOverlayView.liveTranscriptPreviewPanel`). PDX's "streaming
dictation overlay" (this commit + 5 follow-ups: `4aab5487`, `19e83be3`,
`ecc6ade3`, `11e01c48`, `1e1a81a7`) builds the same end-user feature
independently (FluidAudio `StreamingAsrManager` backend instead of
`STTLiveDictationTranscribing`).

Checked the 5 follow-ups for anything genuinely missing from upstream's
version (same due-diligence as App Profiles' Try-it/privacy-split): most are
moot (notification-key bugfix and AI-bubble integration reference the
now-dropped AI Assistant bubble; "default ON" is redundant, upstream's is
already default-on; paste-delay removal is a general latency fix, not
streaming-specific). Two are genuinely new:
1. **Live LLM cleanup of the preview** (`4aab5487`) — debounces 250ms after
   speech pauses, runs the partial text through `llmService.formatTranscript`
   (the SAME formatter service as end-of-dictation polish — **not**
   Ollama-specific, whatever provider is configured) to show cleaned text
   mid-dictation instead of raw ASR partials. Upstream's preview shows raw
   partial text only, no cleanup pass.
2. **Mic name shown in the overlay bubble** (`11e01c48`) — cosmetic.

**Decision (user, 2026-09-21):** keep upstream's streaming/live-preview
system as-is (skip `beb363c7` + all 5 follow-ups as superseded — same
`git rebase --edit-todo` removal as the App Profiles list). Port both extras
as **follow-up work on top of upstream's system**, not during the mechanical
rebase:
1. Mic name in the overlay bubble — straightforward UI addition, port as-is.
2. Live cleanup, **modified**: gate it to fire only when the active LLM
   provider is genuinely on-device (Ollama, local CLI, or Apple on-device
   Foundation Models) — never a cloud provider, since the original PDX
   version would otherwise send partial dictation text to a cloud API every
   ~250ms while the user is still speaking. When the active provider isn't
   local, skip the cleanup pass silently and show the raw partial (same
   graceful-fallback behavior the feature already has for "formatter
   unavailable"). **Needs a way to identify "is the current provider
   local," which doesn't obviously exist yet — check `LLMProviderID` /
   `RoutingLLMClient` when doing this work.**

**Not started yet.** Both are separate follow-up tasks, not part of the
mechanical rebase — they need real design/implementation work.

**Commits to skip as superseded** (remove via `git rebase --edit-todo`,
same as App Profiles): `beb363c7`, `4aab5487`, `19e83be3`, `ecc6ade3`,
`11e01c48`, `1e1a81a7`.

Note: Voice Memo commits (`f9c4eef5`, `6a262da8`, `f5bd0d9b`) appear nearby
in the todo but are a **different, unrelated feature** (standalone voice
memo recording, not dictation streaming) — not part of this decision, handle
normally when reached.

**To resume:** `cd /Users/jnzn08/Developer/macparakeet && git status` should
show branch `pdx-next-upstream-sync`, mid-rebase, at commit 11/152 (confirm
via `cat .git/rebase-merge/msgnum` / `.git/rebase-merge/end`). Finish
resolving `LLMSettingsViewModelTests.swift` as above, `git add` all 3 files,
then `git rebase --continue` (retry a few times if it hits the 1Password
flake — never fall back to manual `git commit`). 141 commits remain after
that. Known upcoming hard zones needing a product decision, not just
mechanical resolution: ADR-023 auto-stop (already decided — adopt
`feature/pdx-adr023-hybrid-autostop`, skip/replace PDX's original
auto-stop commits when hit), ADR-028 echo/AEC (retire PDX's conditioner),
AI Assistant bubble commits (skip entirely, already decided).

## Progress log (2026-09-22, session 3)

Resumed at commit 54/152, mid-conflict on `299fe07d` (source-scoped
auto-run + meeting auto-notes card). All source files for that commit had
already been resolved in an earlier part of this session (no conflict
markers), but were unstaged and **unverified** — a `swift build` surfaced
two real bugs left over from that earlier resolution:
1. `PromptRepository.setAutoRun` was defined **twice** (verbatim duplicate,
   Swift redeclaration error) — one copy used a bare `Prompt.fetchOne(db,
   key:)` that skips the soft-delete filter, the other used the file's
   established `PromptQuery.fetch(id:includingDeleted:db:)` convention.
   Kept the convention-consistent one, deleted the other.
2. `PromptRepository.toggleAutoRun` called `prompt.update(db)`, but `Prompt`
   only conforms to `FetchableRecord`/`TableRecord`, not `PersistableRecord`
   — no `.update(db)` member exists. Fixed to call `updateMetadata(prompt,
   db:)`, matching `toggleVisibility` right above it.

Finished resolving the remaining test-file conflicts for `299fe07d`
(`PromptsCommandTests`, `PromptRepositoryTests`, `MeetingsWorkspaceViewModelTests`,
`PromptResultsViewModelTests`, `ViewModelMocks`, `spec/01-data-model.md`).
Found a second real gap while doing this: several already-resolved/HEAD-side
test assertions computed "all sources except meeting" as `[.file, .youtube,
.podcast]` (upstream's set, missing the fork's `.voiceMemo`) while others
used `[.file, .youtube, .voiceMemo]` (the fork's original 4-source world,
predating upstream's `.podcast`). The current merged `Transcription.SourceType`
has **five** cases (file/youtube/podcast/meeting/voiceMemo), so the correct
set is `[.file, .youtube, .podcast, .voiceMemo]` — fixed every occurrence,
including one in `PromptsCommandTests.swift` that had no conflict marker at
all (a stale assertion nobody had touched). Verified via `swift build
--build-tests` + focused `swift test` runs (all green) before staging and
running `git rebase --continue`.

**App Profiles skip-list correction:** the interactive rebase then walked
into the ~22-commit App Profiles editor sequence the plan already decided
(2026-09-21) to drop in favor of upstream's `AIFormatterProfile`. Skipping
one-by-one as each conflicted worked for the commits that *did* conflict,
but several in that list are pure new-file additions with nothing to
conflict against, so they silently **applied** instead of being dropped —
defeating the decision. Caught this via a `swift build` failure
(`AppProfileSeeder.swift` referencing the never-applied `AppProfileRepository`
type) after the sequence finished. Fixed by deleting the leaked files
(`AppProfilesView.swift`, `AppProfileAppPicker.swift`, `AppProfileStore.swift`,
`AppProfilesViewModel.swift`, `AppProfileSeeder.swift` + their 3 test files)
and the leaked `seeds/app-profiles.local.json` bundling block in
`scripts/dist/build_app_bundle.sh`. **Left alone, correctly:** `AppProfile.swift`
(the model) and its test — that one is unrelated foundation work from
`b26b5e29`, wired into `DictationService`/`AppContextService`/
`TextRefinementService`, per the plan's own note that it's a separate
concern from the abandoned editor.
**Lesson for the rest of this rebase: when dropping a whole commit range
per a skip decision, use `git rebase --edit-todo` to mark them all `drop`
up front — don't rely on skip-as-you-hit-conflicts, since clean-applying
commits in the range won't stop the rebase at all.**

Resolved `cec3089b` (fix: don't run AI formatter on meeting/voice-memo
transcripts). The source-file conflict required real judgment: HEAD's tree
already had upstream's newer `TranscriptFormatter` abstraction in place of
the old `formatTranscriptIfNeeded` this PDX commit's patch assumed, and the
PDX diff's own meeting-check (`transcription.sourceType == .meeting`) would
have missed voice memos — the file's own established convention two lines
above (`source != .meeting`, where `source: TelemetryTranscriptionSource`
has no separate voiceMemo case) is what actually covers "meeting or voice
memo." Ported the skip onto `TranscriptFormatter` using that existing
`source == .meeting` check. The test-file side of this conflict was a large
interleaving of ~11 unrelated HEAD-only tests with fragments of PDX's one
new test (`testMeetingTranscriptIsNotRunThroughAIFormatter`) scattered
across 5 conflict markers — reconstructed by pulling git's own conflict
stage blobs (`git show :2:<path>` / `:3:<path>`, unaffected by working-tree
edits) as ground truth rather than hand-splicing fragments, after a manual
splice attempt orphaned a marker pair and had to be redone properly.
Verified via build + `swift test --filter testMeetingTranscriptIsNotRunThroughAIFormatter`
(passes) before staging.

Resolved `2e4f4dfe` (menu shows "Start Recording" during post-stop
finalize) — purely additive, HEAD's `canPresentLiveMeetingPanel` /
`isCapturingMeetingAudioForAutoStop` plus PDX's new `isMeetingCaptureActive`
all coexist; the menu-label wiring in `AppDelegate.swift` auto-merged clean.
Verified: 22/22 `MeetingRecordingFlowStateMachineTests` pass (matches the
commit's own stated count).

**ADR-023 auto-stop — executed the drop decision properly this time.**
Applying the correction-lesson above: used `git rebase --edit-todo` to mark
all 16 remaining old-design auto-stop commits (`49c1cbd8` through
`3bcc3ebd` — Settings toggle, ADR-023-accepted docs, CFString fix, call-app
allowlist plan/impl/model/API/prefs/monitor/Settings-UI, docs) as `drop` in
one batch, leaving the 3 interleaved-but-unrelated smart-formatting planning
docs (`25f4b4c9`, `11475bdf`, `372d2989`) as `pick`. Also skipped `fd8ea3d4`,
`226215dd`, and `ef552ec0` individually (the ones that had already stopped
the rebase in conflict before the batch edit). This confirmed `feature/pdx-adr023-hybrid-autostop`
exists locally with exactly one commit (`25cd0e50` "hybrid auto-stop —
instant app-quit/mic-release + mute-safe silence fallback") on top of
`upstream/main`'s tip — **adopting it is separate follow-up work, not yet
started.**

**Currently paused mid-conflict, commit 119/152:** `b867a02d` "wire
SpokenTextFormatter into pipeline behind smartFormattingEnabled (with
legacy migration)" — real conflicts in `Sources/MacParakeet/App/AppEnvironment.swift`
and `Sources/MacParakeetCore/Services/Dictation/DictationService.swift`
(both need actual review, not mechanical resolution); `AppRuntimePreferences.swift`,
`TextProcessingPipeline.swift`, `TextRefinementService.swift`,
`SettingsViewModel.swift`, and a new `SmartFormattingPreferenceTests.swift`
auto-merged clean. Not yet investigated — paused here deliberately rather
than rushing it, per this plan's own resolution rule.

**To resume:** `git status` should show branch `pdx-next-upstream-sync`,
mid-rebase, at commit 119/152. Read `AppEnvironment.swift` and
`DictationService.swift`'s conflict markers, resolve for real (this is core
dictation-pipeline wiring, not boilerplate), verify with `swift build
--build-tests` + focused tests, stage, `git rebase --continue`. ~33 commits
remain after that, including the ADR-028 echo/AEC hard zone (not yet
reached) and the AI Assistant bubble commits (plan says skip, not yet
verified whether those are still ahead or already passed through — check
before assuming). After the mechanical rebase finishes: (1) integrate
`feature/pdx-adr023-hybrid-autostop`'s single commit `25cd0e50` as the
ADR-023 replacement, (2) the App Profiles "Try it" preview + privacy-split
seed follow-ups, (3) the streaming-dictation mic-name + gated-live-cleanup
follow-ups — all previously deferred, none started.

## Progress log (2026-09-22, session 4)

Resumed at commit 119/152 per the prior checkpoint; user chose "keep going
now" when asked. Resolved through commit 139/152 (`55f48391`, PDX-001/002
live-ingest queue). Notable finds along the way:

- `f5cb5464`/`44c1d50f` (Parakeet v2 model selection + review feedback):
  confirmed this whole feature is already-superseded — upstream/HEAD
  already ships Parakeet v2/Unified plus Nemotron/Cohere via a dedicated
  `EngineSettingsViewModel` (`SettingsViewModel.engine`), not the flat
  properties PDX's old commits assumed. Took HEAD wholesale for
  `SettingsViewModel.swift`, `SettingsView.swift`, `spec/06-stt-engine.md`,
  `spec/02-features.md`, `spec/03-architecture.md`, `AGENTS.md`, `CLAUDE.md`
  (all HEAD-superset "diff3 misaligned against a doc that moved on"
  cases). Fixed several more duplicate-declaration leftovers from earlier
  sessions along the way (`TranscribeCommand.swift`'s duplicate
  `TranscribeParakeetModel`, `ConfigCommandTests.swift`'s duplicate
  `testWriteParakeetModelPersistsAndCanonicalizesAliases`/
  `testWriteParakeetModelRejectsInvalidValue`, `ModelLifecycleCommandTests.swift`'s
  duplicate `testParakeetDownloadVariantRecognizesParakeetIDs` — a case where
  the duplicate was split across ~180 lines rather than adjacent, found only
  by grepping for repeated function names file-wide,
  `SpeechEnginePreferenceTests.swift`'s duplicate Parakeet-variant test
  block, `MockSTTClient.swift`'s duplicate `setParakeetModelVariant`,
  `SettingsViewModelTests.swift`'s duplicate `testParakeetModelVariantChange*`
  trio still calling the stale flat `viewModel.parakeetModelVariant` API).
  **Lesson reinforced:** after resolving a commit's marked conflicts, grep
  the touched files for repeated `func`/`struct` names before trusting
  `swift build` alone to catch it — several of these duplicates were far
  enough apart that a quick skim wouldn't surface them.
- `045f03e3` (CLI speaker diarization constraints): mechanical, HEAD
  superset throughout.
- `c2055c4b` (Trash-move on delete): real merge needed in
  `TranscriptionAssetCleanup.swift` — PDX's diff silently orphaned the
  `removeItem` helper (renamed to `moveToTrash` by the patch, but one caller
  added later by HEAD, `removeMeetingAudioFiles`, wasn't in PDX's diff and
  still called the old name). Restored `removeItem` as a distinct
  permanent-delete helper alongside the new `moveToTrash`, and switched
  `removeMeetingFolder`'s whole-folder removal to `moveToTrash` (keeping
  HEAD's `assertMeetingFolderUnlocked` safety check) to match this commit's
  intent.
- `e1d3c354` (flower → parakeet motif): **near-miss.** The sync ledger says
  this fork commit supersedes upstream's animation half of `80aeb9e3`, so
  I initially `git rm`'d the modify/delete conflict on `MerkabaPillIcon.swift`
  without reading HEAD's side first. HEAD's version turned out to be an
  unrelated, actively-wired-up 1021-line CALayer reimplementation (still
  flower-themed) that the *floating pill window* actually renders in
  production (`MeetingRecordingPillController` → `MeetingRecordingFlowCoordinator`).
  The SwiftUI `MeetingRecordingPillView` PDX's commit touches is dead in
  production — only kept alive by `MeetingRecordingTileTests` unit-testing
  its `visibleSourceHealthWarning` logic. Restored the file via
  `git checkout HEAD --`; ledger's "supersedes" framing is about the
  *isolation-slice* half of `80aeb9e3` only, not this CALayer file. Applied
  the parakeet-icon swap only to the two files that are actually live:
  `MeetingRecordingTile.swift` (Transcribe/Meetings tab card — live) and
  `MeetingRecordingPillView.swift` (dead in UI, kept compiling for its
  tested logic). Also found and fixed a duplicate `MeetingsLiveStatusChip`
  in `MeetingsView.swift` (stale copy missing the `.starting` case).
- `55f48391` (PDX-001/002 live-ingest queue): wired the missing
  `liveIngestQueue = LiveIngestQueue(...)` instantiation into
  `startRecording` (HEAD's drain/cleanup helpers already referenced the
  queue but nothing ever created one). **Found a pre-existing, latent bug
  this exposes for the first time:** `testAsymmetricSourceCadenceDoesNotInflateSystemChunkTimeline`
  fails because `updateProcessedMicrophoneRms`'s EMA
  (`recentProcessedMicRms`, alpha 0.3) only gets one update for the entire
  test (one long-buffered mic segment vs. 500 tiny system buffers), so it
  never converges away from its `0` cold-start baseline while
  `recentSystemRms` converges almost immediately from hundreds of updates —
  `shouldSuppressMicrophoneChunkTranscription()`'s dominance ratio then
  false-positives and silently drops every microphone chunk for the rest of
  the recording. Traced with temporary `FileHandle.standardError` tracing
  (removed before committing) down to `MeetingRecordingService.swift`'s
  `updateProcessedMicrophoneRms`/`shouldSuppressMicrophoneChunkTranscription`;
  did not fix it — the fix needs a decision (bypass EMA on the first sample?
  track "has ever been set" separately? something in `CaptureOrchestrator`'s
  pairing instead?) that's outside this rebase's scope. **This is the one
  known-red test at commit 139/152** (124 run, 1 failure, otherwise green).
  Needs a dedicated follow-up before this branch ships.

**To resume:** `git status` should show branch `pdx-next-upstream-sync`,
mid-rebase, at commit 140/152. 13 commits remain (see
`.git/rebase-merge/git-rebase-todo`); none of their titles suggest they
touch the RMS-dominance code, so the known-red test above will very likely
still be red when the rebase finishes — do not assume a later commit fixes
it. After the mechanical rebase finishes, in addition to the three
follow-ups listed in the prior session's resume note: (4) fix or
knowingly-accept the `testAsymmetricSourceCadenceDoesNotInflateSystemChunkTimeline`
regression documented above.

## Non-goals (this pass)

- Deciding the final ADR-023 / echo-AEC reconciliation design — separate
  follow-up once both are read side by side.
- Force-pushing over `feature/pdx-next` or touching `main` — the scratch
  branch stays local and unpushed until reviewed.
- Upstreaming PDX-unique work as PRs back to moona3k — separate future task.
