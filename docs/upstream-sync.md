# Upstream Sync Ledger

> Decisions about which `upstream` (moona3k/macparakeet) commits the PDX fork
> ports, skips, or defers — so we never re-evaluate the same commit twice.
> **When checking upstream for new work, read this first**, then only triage
> commits newer than the "evaluated through" marker below.

## Remotes & topology

| Remote | URL | Role |
|--------|-----|------|
| `origin` | github.com/jnzn/macparakeet | the PDX fork (push here) |
| `upstream` | github.com/moona3k/macparakeet | source project (read-only) |

The fork **rewrote history on 2026-05-31** (scrubbed author emails; all SHAs
changed) and carries its own `feat(pdx)` work, so `merge-base`/`HEAD..upstream`
are meaningless for sync — they report ~1500 false "missing" commits. **Compare
by commit *subject*, not SHA reachability.** The fork preserves upstream subjects
verbatim when it ports, so subject-matching is reliable.

## How to run a sync check

```bash
D=~/Developer/macparakeet
git -C "$D" fetch upstream
# subjects the fork doesn't have yet, newest first, since the last marker date:
git -C "$D" log HEAD --format='%s' > /tmp/fork_subjects.txt
git -C "$D" log upstream/main --since=<EVALUATED_THROUGH_DATE> --format='%s' --no-merges \
  | while IFS= read -r s; do grep -Fxq "$s" /tmp/fork_subjects.txt && echo "have | $s" || echo "MISSING | $s"; done
```
Feasibility of a `MISSING` commit = cherry-pick it onto a throwaway worktree and
see if it conflicts (never touch the working tree):
```bash
git -C "$D" worktree add --detach /tmp/feas HEAD
git -C /tmp/feas cherry-pick -n <sha>; git -C /tmp/feas diff --name-only --diff-filter=U
git -C /tmp/feas reset --hard HEAD; git -C /tmp/feas clean -fd
git -C "$D" worktree remove --force /tmp/feas
```
`CHANGELOG.md` and `plans/**` conflicts are trivial and expected on nearly every
CLI/feature commit — discount them when judging effort.

---

## Evaluated through

- **upstream/main `1fe66143` (2026-06-03)** — triaged 2026-06-04.
- Fork was tracking upstream to ~PR #390 before this pass.
- Next check: only consider upstream commits **after `1fe66143`**.

## Ported (2026-06-04, branch `feature/pdx-next`)

| Upstream | Subject | Local commit | Notes |
|----------|---------|--------------|-------|
| `b25eb0a4` | Decouple media pause from dictation capture (#383/#384) | `7bd22cbe` | clean |
| `193fcc21` | Guard undoCancel against reentrant session takeover | `5165d04b` | clean |
| `af285abd` | Fix YouTube hotkey from background app (#406) | `aebd5a51` | clean |
| `641cf6ab` | reduce Meetings workspace resize jank (#420) | `bf0b33d3` | clean |
| `88d4f436` | Universal launch-time VAD model prep (#394) | `3f7ee6c7` | merged: kept fork-only streaming pre-warm + adopted upstream `MeetingVADLaunchPrep` helper/telemetry in `AppDelegate` |
| `4cdd6f86` | Batch file transcription + completion notification (#401) | `86ad78f5` | `AppRuntimePreferences` key union; CHANGELOG hand-merged |
| `6ae4a51c` | Expose Parakeet v2 (English-only) model selection (#399) | `f5cb5464` | kept fork CLI version `2.3.1` (did **not** take upstream `2.5.0`) |
| `1fe66143` | Add CLI speaker diarization constraints | `045f03e3` | CHANGELOG hand-merged |
| `8ee82d36` | Parakeet model selection review feedback (#400) | `44c1d50f` | clean once #399 (its prerequisite) was already applied |
| `077fbb9a` | stop Meetings Intelligence badge wrapping vertically | `1db3e453` | adapted `IntelligenceReadyRow` reflow to the fork's diverged view; kept non-optional `detail` (fork uses `String`, not `String?`) |
| `80aeb9e3` *(partial)* | Meeting recording: richer pill animation, lower CPU (#396) — **isolation slice only** | `d0d05a99` | Ported **only** the per-second elapsed-read isolation: extracted a `MeetingsLiveStatusChip` leaf so the 1 Hz timer tick no longer relayouts the whole meetings tab. The pill/tile **animation-rewrite** half is superseded by the fork's parakeet motif — see Superseded. |

## Deferred (revisit later)

_None currently._ The two prior deferrals (#396 `80aeb9e3`, `f70c3467`) were
resolved on 2026-06-04 — the relayout-isolation slice was ported (`d0d05a99`)
and both animation halves are superseded by the fork's parakeet work — see
Superseded.

## Superseded by fork work (do not port)

Upstream commits the fork has since solved its own way. Porting them now would
fight the fork's implementation — do not re-evaluate.

| Upstream | Subject | Superseded by | Notes |
|----------|---------|---------------|-------|
| `80aeb9e3` *(animation half)* | Meeting recording: richer pill animation, lower CPU (#396) | `e1d3c354` (parakeet motif) | The fork deleted `MerkabaPillIcon` entirely and replaced it with a Canvas-drawn parakeet (`ParakeetPillIcon` full-bird tiles + `ParakeetHeadPillIcon` head-only recording pill) animated via SwiftUI render-server transforms (`.offset`/`.scaleEffect`/`.rotationEffect`). That reaches the same ~0 app-CPU goal as #396's CALayer/CABasicAnimation rewrite — measured ~13% total CPU during a live recording with everything running — without adopting the CALayer bridge or the upstream pill controller. Only #396's relayout-isolation slice was taken (see Ported, `d0d05a99`). |
| `f70c3467` | Reduce meeting tile recording render churn | `e1d3c354` (parakeet tile) | Premised on #396 re-adding tile animations via leaf isolation. The fork's `MeetingRecordingTile` is now a transform-driven parakeet that is already cheap (static `Canvas` cached + transform-only motion), so the upstream deletion no longer applies. |

## Skipped (permanent — do not re-evaluate)

| Upstream | Subject | Why skipped |
|----------|---------|-------------|
| `05055bc8` | [codex] Default Parakeet when English is preferred | **Breaks the owner's EN+ES bilingual workflow** — would default English to Parakeet and bypass Whisper. Intentional fork divergence. |
| `d6e9ba2f` (+#405 series) | Add per-model delete for downloaded speech models | Manual deletion from the app's model folder is sufficient. 7-commit series, heavy CLI/Settings conflicts. Not worth the integration cost. |
| `503347c1` / `95bc9a20` / `b84443f9` | App-aware AI formatter profiles (#419/#426/#428) | Conflicts with the fork's own `SpokenTextFormatter` / smart-formatting direction. Divergent product philosophy — the fork went its own way on AI formatting. |
| `20f4daac` + `cd335310` | Pin system default microphone + its revert | Net-zero upstream (added then reverted). Nothing to port. |
| docs / screenshots / telemetry-KPI notes | (various) | Not applicable to the fork, or fork-divergent docs. |

## Not yet evaluated in depth (skip for now)

- `d3e4c070` refactor(settings): focus Capture tab around workflows — UI refactor; revisit only if the fork reworks Settings.
- `#382` / `#386` / `#388` / `#389` Meetings-page UI features — depends on how far the fork's Meetings UI has diverged.
