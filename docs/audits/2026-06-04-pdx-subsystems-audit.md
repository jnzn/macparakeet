# PDX Subsystems Audit — 2026-06-04

> **Status:** REPORT ONLY (discovery pass — nothing fixed). Two-pass independent
> audit of the **delta** added since the [2026-04-26 codebase audit](2026-04-26-codebase-audit.md),
> on branch `feature/pdx-next` (HEAD `d0d05a99`). The repo grew from ~249 source
> files to ~412 (+65%); this audit targets the newer subsystems that postdate the
> prior audit's coverage table and were therefore largely unaudited: PDX meeting
> **echo suppression** (native `liblocalvqe` via `dlopen`), **live VAD chunking +
> pair-joining**, the **AI Assistant / Ask / Discover / Ollama** network surfaces,
> **Transforms** (ADR-022), and **meeting activity auto-stop** (ADR-023).
>
> Finding IDs are `PDX-NNN` to avoid colliding with the locked `AUDIT-001..070`.
> Status legend: **OPEN** (confirmed defect, triage pending) · **REFUTED** (candidate
> or pre-identified lead checked and cleared, with the clearing line). Severity:
> **P0** data-loss/crash/security that will bite a normal user · **P1** likely-real
> reliability/perf/memory/privacy under realistic use · **P2** edge/hardening/polish.
> Where pass-2 verification changed a pass-1 severity, the note says so and why.

| | Count |
|---|---:|
| Total new findings | 18 |
| P0 | 0 |
| P1 | 2 |
| P2 | 16 |
| Finding status | 15 OPEN · 3 FIXED (PDX-001, PDX-002, PDX-014) |
| Pre-identified leads REFUTED on verification | 4 |
| Severities tempered down from pass-1 on verification | 5 |

The headline: **the new subsystems are, on the whole, well-built.** The team applied
bounded queues, graceful degradation, retain-cycle hygiene, and boundary-scrubbing
consistently — most pass-1 candidates were refuted with a guarding line (see
*Strengths preserved*). The real exposure is narrow: **one unbounded buffer at the
real-time-audio → async-consumer seam** (the exact pattern the dictation path already
guards), **one opt-in auto-stop that can discard a wanted recording**, and a cluster
of native-surface and data-retention **hardening** items.

---

## Methodology

### Pass 1 — broad scan

Four parallel read-only Explore agents, each scoped tight to avoid overlap. Combined
coverage: the ~165 new/changed Swift files under `Sources/`, plus the dist/signing
scripts and the shipped bundle's load commands.

| Scope | Coverage |
|---|---|
| Audio / echo / native DSP | `dlopen`/`dlsym` C boundary, per-frame `localvqe_process_frame_f32`, buffer bounds, graceful degradation, dylib signing/loading/validation, per-frame CPU |
| Concurrency + memory | live VAD chunkers, `MeetingAudioPairJoiner`, stream broadcasters, queue bounds & drop policy, AsyncStream continuation hygiene, actor isolation |
| Network + privacy | AI Assistant / Ollama / Discover URLSession surfaces, selection capture/replacement, `llm_runs` ledger, telemetry delta, SSRF/URL validation, payload privacy, local-first compliance |
| View-layer CPU + Transforms + auto-stop | `TimelineView` per-frame bodies, Transforms executor/hotkey/coordinator, ADR-023 meeting call-activity auto-stop |

### Pass 2 — independent verification

Every P0/P1 candidate was re-read against source by the orchestrator and anchored to
`file:line`. Five pass-1 severities were **tempered down** on evidence the pass-1 agents
had not fully chased:

- **The authoritative on-disk write is inside the lagging consumer loop**
  (`MeetingRecordingService.swift:860`/`:880`, before the `await` hop), so audio reaches
  disk under normal progress — the unbounded buffer (PDX-001) is a *memory-pressure*
  risk, not unconditional loss. → pass-1 P0 tempered to **P1**.
- **App Transport Security has no `NSAllowsArbitraryLoads`** (`build_app_bundle_pdx.sh:479-502`):
  plaintext http is permitted only to LAN / `.local` / `*.ts.net`, matching the canonical
  validator. The SSRF/exfil divergence (PDX-010) is blocked at the network layer for
  public hosts. → pass-1 P1 tempered to **P2**.
- **The native-surface findings (PDX-004/005) require local environment or bundle-write
  access** — at which point an attacker already has user-level code execution. → pass-1
  P1 tempered to **P2** (defense-in-depth hardening).

Pass 2 also **refuted a pre-identified lead**: `MeetingAudioPairJoiner`'s mic/system
queues, which the audit brief flagged as a suspected unbounded-memory risk, are in fact
hard-bounded at 30 frames with an explicit oldest-drop policy, diagnostics, and
backing-storage compaction (see *Strengths preserved*). The real unbounded buffer is one
stage upstream.

### Static-analysis backstop

In lieu of the full Semgrep skill (thin Swift signal; the security-relevant new surfaces
were manually reviewed), targeted static checks were run: no `NSAllowsArbitraryLoads`,
no new `Process`/shell execution from untrusted input in the new services, and no
hardcoded secrets in the new surfaces. All clean.

---

## Findings — by area

### Live audio capture — concurrency & memory

| ID | Title | Severity | Status | Note |
|---|---|---|---|---|
| PDX-001 | Unbounded capture-event `AsyncStream` at the real-time→async seam | P1 | FIXED | `MeetingAudioCaptureService.swift:115` creates `AsyncStream(bufferingPolicy: .unbounded)`. Producers are the mic + system tap callbacks, which deep-copy each `AVAudioPCMBuffer` and `yield` (`:127`, `:160-196`) at real time (~12.5 buffers/s combined). The sole consumer is one `for await event` task (`MeetingRecordingService.swift:441-442`) whose body `await`s `ingestResampledSamples → captureOrchestrator.ingest` (`:974`, actor hop + CoreML VAD on `.cpuOnly`). The sibling **dictation** path deliberately uses `.bufferingNewest(200)` (`AudioRecorder.swift:164`); the **meeting** path — which runs for *hours* — has no bound and no drop policy. Pass-2 narrowing: the authoritative `writer?.write` happens earlier in the same consumer loop (`MeetingRecordingService.swift:860`/`:880`), so audio reaches disk under normal progress; the risk is **sustained consumer lag** (VAD/STT contention on a busy machine) growing the buffer until memory pressure, whose worst case is an OOM-kill losing the un-written in-memory tail of a long meeting (invariant 1). **Not a one-liner** (verified during a fix attempt): `testEventsStreamRetainsBurstSystemAudioBuffersWithoutDropping` (`MeetingAudioCaptureServiceTests.swift:97-128`) deliberately asserts a 2,100-buffer burst is retained with **zero drops**, so the unbounded policy is an intentional invariant-1 choice (don't drop authoritative recording audio), not an oversight — switching to `.bufferingNewest(N)` regresses it and breaks that test, and any memory-useful bound (≤~1024) is below the 2,100 the test demands. The safe fix decouples the fast `writer.write` from the slow `await ...ingest` (STT/VAD) so the consumer drains in real time and the stream can't accumulate (drop only STT chunks, which already have bounded backpressure), or is an explicit owner decision to trade recording-completeness for a memory bound. The `await ...ingest` hop runs CoreML VAD inference when live-chunking is active (recently enabled on `feature/pdx-next`), which makes sustained consumer lag — the trigger — more reachable. **Update (2026-06-04, FIXED):** decouple implemented — new `LiveIngestQueue` (bounded `.bufferingNewest(512)`, drop-oldest + counted) moves live STT/VAD ingest off the capture consumer. `MeetingRecordingService` now enqueues resampled samples and a dedicated drain task ingests them, so the consumer drains in real time and the unbounded capture stream can't accumulate; `writer.write` stays on the fast path (recording audio never dropped), and only STT chunks drop under sustained lag (counted as `ingest_queue_drops`). The deliberate burst test is untouched (the fix is consumer-side). Verified: `LiveIngestQueueTests` (3) green; no new failures in the meeting-service suite (3 pre-existing VAD-model env failures unchanged). |
| PDX-002 | No capture-stage backpressure or depth metric | P2 | FIXED | Because PDX-001's buffer is `.unbounded`, a chronically slow consumer never back-pressures the producer and never trips a drop counter at the capture stage; the first observable symptom is the *downstream* `STTScheduler` `backpressureDrop` (`MeetingRecordingService.swift:1045-1048`). So the app can be accumulating capture events in memory while telemetry still looks healthy. Direction: when bounding PDX-001, increment a `captureEventDrops` health counter so a lagging consumer is attributable to capture, not just STT. **Update (2026-06-04, FIXED):** `LiveIngestQueue.droppedCount` is surfaced as `captureHealthMetrics.ingestQueueDrops` and emitted in the capture-health summary (`ingest_queue_drops=`), so a chronically lagging consumer is now attributable to the capture/ingest stage rather than only the downstream STT scheduler. |
| PDX-003 | Per-buffer alloc + O(n) downmix/resample in the consumer hot path | P2 | OPEN | `MeetingRecordingService.swift:863`/`:884` call `AudioChunker.extractAndResample` per buffer, allocating a fresh `[Float]` (`AudioChunker.swift:146-147`) and doing a per-frame downmix + resample. This runs on the single consumer task and directly narrows its real-time margin (feeds PDX-001's trigger). Not a correctness bug. Direction: reuse a scratch buffer and fuse downmix+resample into one pass. |

### Meeting echo suppression — native C boundary

| ID | Title | Severity | Status | Note |
|---|---|---|---|---|
| PDX-004 | Env-var-overridable `dlopen` library path on the no-hardened-runtime PDX build | P2 | OPEN | Pass-1 P1, tempered. Production builds the echo config via `.fromEnvironment()` (`MeetingRecordingService.swift:242`), which reads `MACPARAKEET_MEETING_ECHO_LIBRARY` (`MeetingEchoSuppressionRuntime.swift:14`, `:51-52`) and makes it the first `dlopen(RTLD_NOW\|RTLD_LOCAL)` candidate (`:177-184`, `:309-311`). The PDX bundle is signed **without** hardened runtime — `build_and_package_pdx.sh:91` is `codesign --force --deep --sign` with no `--options runtime` (comment at `:12`: "no hardened runtime") — so library validation does not backstop the load. An attacker who controls the app's launch environment could inject an arbitrary dylib into the signed process. Tempered to P2 because that precondition implies pre-existing local code execution. (The Developer-ID path `sign_notarize.sh` *does* set `--options runtime`; there the differently-signed dylib would be rejected — fail-safe.) Direction: ignore the library/model env overrides in release builds, or constrain the resolved path to inside `bundle.bundleURL` before `dlopen`. |
| PDX-005 | No runtime integrity check of the dylib/model; SHA gate never armed in production | P2 | OPEN | Pass-1 P1, tempered. The SHA256 check runs only when `configuration.modelSHA256 != nil` (`MeetingEchoSuppressionRuntime.swift:216-221`), and that value comes *only* from `MACPARAKEET_MEETING_ECHO_MODEL_SHA256` (`:55-59`) — a build-time-only var the production `.fromEnvironment()` path never sets. So at runtime the dylib is never hashed and the model is verified only `fileExists`/`isReadable` before `dlopen`. A tampered on-disk `Contents/Frameworks/liblocalvqe.dylib` or `.gguf` loads silently (the self-signed PDX bundle has `flags=none`, so the OS does not re-validate on launch). Tempered to P2: needs local bundle-write. Direction: pin and verify a SHA for both the dylib and model at load in release builds; the passthrough fallback path already exists (`:219`). |
| PDX-006 | `localvqe_sample_rate` read into a dead property, never validated against 16 kHz capture | P2 | OPEN | `MeetingEchoSuppressionRuntime.swift:322-325`/`:350` read the lib's reported sample rate into `self.sampleRate`, but `processor.sampleRate` is consumed nowhere. Audio is hard-resampled to 16 kHz upstream (`AudioChunker`), and only frame/hop is reconciled at runtime (`:351`). If the bundled lib were ever built for another rate, 16 kHz frames would be pushed through a mismatched model; the only output check is `count == frameSize`, which still passes, so it would emit corrupted audio into the STT-bound copy. The on-disk recording keeps raw mic, so impact is degraded transcription, not lost audio. Direction: compare reported rate to capture rate at load; fall back to passthrough on mismatch. |
| PDX-007 | `cleanupFailedStart` cancels but does not drain the processing task before freeing the conditioner | P2 | OPEN | `MeetingRecordingService.swift:459-466` cancels `processingTask` and runs `cleanupState()` (which drops the last conditioner ref → `deinit` → `freeFunction(context)` + `dlclose`) **without** `await task.value`. The stop/cancel paths correctly `await drainProcessingTaskAfterCaptureStop()` first; `cleanupFailedStart` is the one cleanup path that skips the drain. Latent today (no throwing `try await` exists after the task is created at `:439`, so the task is effectively nil here), but adding one would make a free-while-C-call-in-flight race reachable. Direction: route `cleanupFailedStart` through the same drain. |
| PDX-008 | `deinit` frees the C context without taking the bridge lock | P2 | OPEN | `MeetingEchoSuppressionRuntime.swift:358-361` calls `freeFunction(context)`/`dlclose` in `deinit` without `lock`, while `processFrame`/`reset` both take it (`:381`, `:364`). Safety relies entirely on external ARC/drain ordering rather than an in-class barrier. Correct today; fragile. Direction: acquire `lock` in `deinit` (or set a freed-flag under lock that `processFrame` checks) so the bridge self-protects. |
| PDX-009 | `unsafeBitCast` of every `dlsym` result to a `@convention(c)` pointer with no ABI guard | P2 | OPEN | `MeetingEchoSuppressionRuntime.swift:408-426` bit-casts each resolved symbol to its expected function type. A *missing* symbol is handled (throws → passthrough), but a *present* symbol with a different real signature (tampered or version-skewed lib) is invoked with the wrong ABI — undefined behavior. Inherent to `dlsym`; pairs with PDX-005. Direction: pin the dylib by hash (PDX-005) and/or check a `localvqe_abi_version` symbol before first use. |

### Network & privacy

| ID | Title | Severity | Status | Note |
|---|---|---|---|---|
| PDX-010 | `LLMSettingsDraft` URL allowlist diverges from the canonical `OllamaURLValidator` | P2 | OPEN | Pass-1 P1, tempered. `OllamaURLValidator` documents itself as the single source of truth both Settings and onboarding consult "so the two surfaces never diverge" (`OllamaURLValidator.swift:3-6`), and restricts http to loopback/Tailscale/RFC1918/`.local`. But `LLMSettingsDraft.isAllowedBaseURLOverride` is a separate re-implementation that returns `true` for **any** http host when `providerID.isLocal` (`LLMSettingsDraft.swift:253-254`), never calling the validator. Pass-2 mitigation: ATS has no `NSAllowsArbitraryLoads` (`build_app_bundle_pdx.sh:479-502`), so a `http://public-host` request is blocked at the URLSession layer regardless — making this a code-level divergence / confusing-failure UX issue (a config the user can *save* but never connect to), not a live exfil path. (https-to-any-host is allowed by *both* validators by design, so it is not a divergence.) Direction: make `LLMSettingsDraft` delegate to `OllamaURLValidator.isAllowedBaseURL` — one allowlist. |
| PDX-011 | No request-time URL re-validation in the Core executor that transmits prompts | P2 | OPEN | `AIAssistantOllamaExecutor.swift:87`/`:109-120` and `OllamaReachability.swift:28` build the request URL straight from `providerConfig.baseURL` with no allowlist check; validation lives only in the ViewModel save path. Any path that writes a base URL to `LLMConfigStore` (import, migration, future caller) bypasses the gate. Defense-in-depth (ATS still backstops public http). Direction: re-assert `OllamaURLValidator.isAllowedBaseURL` in the executor before `session.data(for:)`, failing closed. |
| PDX-012 | `llm_runs` ledger grows unbounded — one row per LLM call, forever | P2 | OPEN | `LLMRunRepository.save` is an unconditional insert with a fresh UUID per run (`LLMRunRepository.swift:29-33`, `LLMRun.swift:67`), recorded on every dictation and transcription; the repo exposes only `count()`/`deleteAll()` — no prune, cap, or age-out. A heavy user accrues a row per LLM invocation indefinitely. Not a privacy leak (metadata only — provider/model names, token/char counts, latency, `errorType`; no prompt/transcript/output) and degrades gracefully (recorder swallows save failures), but the table is unbounded. Direction: bounded-retention sweep (cap N rows or age out) on insert or launch. |
| PDX-013 | Dormant remote free-text submitter wired to a hardcoded domain | P2 | OPEN | `DiscoverThoughtsService.submitThought` (`:28-47`) POSTs a free-text `message` plus a system-info fingerprint (`app_version`, `build_number`, `mac_os_version`, `chip_type`) to a hardcoded `https://macparakeet.com/api/discover-thoughts` (`:23`). Grep finds **no caller** — nothing user-dictated reaches it today. Flagged because once wired to a UI field the `message` is unscrubbed/unbounded and the system-info is finer-grained than telemetry's coarse buckets (AUDIT-022 class). Direction: keep it user-initiated-only; document that `message` is hand-typed feedback (never transcript); route system-info through telemetry's coarse buckets. |

### View-layer CPU + Transforms + meeting auto-stop

| ID | Title | Severity | Status | Note |
|---|---|---|---|---|
| PDX-014 | ADR-023 activity auto-stop can discard a wanted recording (opt-in) | P1 | FIXED (countdown) | `MeetingCallActivityMonitor.onAutoStop` sends `.stopRequested` directly with **no user confirmation or cancellable countdown** (`MeetingRecordingFlowCoordinator.swift:760-763`); the `delaySeconds` (default 5) is an internal debounce in `MeetingAutoStopDetector` (`:37`), surfaced only as a log line, not UI. The arm signal is `MicInputProbe.capturingInputBundleIDs()`, which reports *any* process running audio input with "No filtering" (`MicInputProbe.swift:9-14`), prefix-matched against a default allowlist that includes broad browser prefixes `com.apple.WebKit` and `com.google.Chrome` (`MeetingCallApp.swift:28-30`). So a browser tab that grabbed the mic for any non-call reason arms the detector; closing that tab (while the user is still in a different/in-person meeting) fires a stop after the delay. ADR-017 (2026-05) removed calendar auto-*stop* as unreliable; this reintroduces the "discard wanted recording" class via an activity heuristic. Already-captured audio is saved, so it loses the *remainder* the user wanted — still an invariant-1 violation of intent. **P1 not P0** because the feature is off by default (`AppRuntimePreferences.swift:254`, `?? false`). Direction: a brief user-cancellable undo/countdown on auto-stop, and only arm when the call app is also frontmost. **Update (2026-06-04, FIXED — countdown):** auto-stop no longer ends the recording silently — `onAutoStop` starts a cancellable grace countdown (`MeetingAutoStopCountdown`, TDD-tested) and tears the monitor down; the panel header swaps the live status for a red/pink countdown pill (`AutoStopCountdownPill`, mirroring `StopRecordingButton`'s confirm slider) — clicking it keeps recording (kills auto-stop for the session), and the slider running out stops the recording. Per owner direction the detection heuristic is unchanged: the frontmost-arming gate (PDX-015) was declined, so the browser-tab false-positive remains — now mitigated by the visible, cancellable undo rather than removed. |
| PDX-015 | Auto-stop "is a call active" heuristic ignores frontmost/foreground | P2 | OPEN | Detection is purely "does any capturing bundle ID prefix-match the allowlist" (`MeetingCallActivity` + `MicInputProbe`) — never checks frontmost. False-positive: a backgrounded Teams/Zoom/Slack or a lingering browser GPU helper that holds the mic keeps the detector armed so a genuinely-over meeting never auto-stops. False-negative: if a macOS build attributes browser capture to a helper bundle ID outside the seeded prefixes, a real call is never detected. Same "frontmost not verified" class as deferred AUDIT-050. Direction: AND the mic-capture signal with `NSWorkspace.frontmostApplication` membership before treating a sample as `isCallActive`. |
| PDX-016 | `RhodoneaScribeLoader` `TimelineView` body allocates ~280 `Path`s + ~320 trig calls/frame | P2 | OPEN | `RhodoneaScribeLoader.swift:13-73`: the `.animation(minimumInterval: 1/60)` body builds a fresh 240-segment base `Path` plus 42 trail `Path`s per tick, each via `sin`/`cos`/`pow` (~17k `Path`s/sec). **Not** the most-important `TimelineView` the brief feared — its only consumer is the transient transform-progress pill (`TransformSpikeProgressPanelController.swift:284`), shown only while `.working` and `paused:` is wired to `reduceMotion`. Cost is real but lasts only the seconds a transform is in flight. Direction: precompute the size-invariant base curve once; cache trail geometry or drop to ~30 fps. |
| PDX-017 | `TransformsHotkeyRegistry` keyUp swallow is keyed on bare `keyCode`, not the matched chord | P2 | OPEN | `pressedKeys` and the keyUp swallow track `keyCode` alone (`TransformsHotkeyRegistry.swift:182-190`) while the dispatch table is keyed on `KeyMatch(keyCode, modifierBits)`. If a transform's keyUp is ever missed without a tap-disable reset (the tap-disable path *does* clear the set, covering the common case), the keyCode lingers and a later unrelated keyUp of that physical key is swallowed (`return nil`) — the focused app sees a keyDown with no keyUp (stuck-key glitch). Self-healing on next tap-disable. Same family as deferred AUDIT-047 but a distinct keyUp-bookkeeping bug. Direction: track the full `KeyMatch` so keyUp only swallows the exact combo dispatched. |
| PDX-018 | `TransformsCoordinator` fires the `.failed` panel twice on one run | P2 | OPEN | The `onProgress` closure spawns a MainActor Task to call `panelController?.fail(...)` on any `.failed` event (`TransformsCoordinator.swift:227-236`), and the surrounding `catch` blocks *also* call `fail(...)` (`:298-326`). For a failed run both fire (both `activeRunID`-guarded, so cross-run is safe) — redundant work + possible pill flicker. No data loss (the executor restores the clipboard on failure). Direction: let the terminal `catch` own the fail state; drop `.failed` from the streaming callback. |

---

## Refuted / pre-identified leads cleared

The audit brief named four leads to verify-don't-assume. Three were already handled by
the code:

- **`MeetingAudioPairJoiner` queues are *bounded*, not the suspected unbounded risk.**
  Every `push` calls `trimQueueIfNeeded` (`MeetingAudioPairJoiner.swift:125`/`:135`),
  which drops oldest when `count > 30` and emits a `queueOverflow` diagnostic
  (`:275-280`). `prepend` (`:177`/`:185`) runs only after two `popFirst()` in the same
  branch, so net count is non-increasing. Backing storage is physically reclaimed via
  `compactIfNeeded` (`:86-92`), not just logically advanced. Stall/drift is handled by
  solo-drain (`:204-236`). The PairJoiner is genuinely bounded; the real gap is PDX-001,
  one stage upstream. **REFUTED.**
- **The "writing samples" store does not ship.** The `writing_samples` table was created
  in migration v0.15 then explicitly **dropped in v0.16** (`DatabaseManager.swift:749-756`)
  "so existing developer/prerelease databases [don't retain] writing samples after the
  feature was reverted." No `WritingSampleRepository`/`WritingSample` exists. **REFUTED.**
- **`TimelineView` per-frame bodies are mostly cheap or gated** (the brief's specific CPU
  lead). `AIStreamingIndicator` uses a single `.repeatForever` Bool with
  `onDisappear { breathing = false }` — no `TimelineView` (`:8-32`). `BreathWaveLogo`
  renders a process-lifetime-cached `NSImage`, zero per-frame cost (`:24-44`). The
  meeting panel's `BreathingSeedOfLifeView` (`MeetingRecordingPanelView.swift:472-516`)
  passes `paused: freeze \|\| reduceMotion` and its body is 6 fixed `cos/sin` offsets — no
  alloc. Only `RhodoneaScribeLoader` (PDX-016) is a real allocator, and it is transient.
  **REFUTED (as a systemic concern).**
- **`AppContextService` does not leak the foreground app to telemetry.** The invasive
  `captureWindowContent` OCR path has zero callers (dead code, `:361`); dictation context
  is bundleID + window title + focused field + selection passed only to the local prompt
  path, and the only telemetry mapping is `TelemetryAppCategory` — an 8-value coarse
  bucket, never the bundle ID (`TelemetryAppCategory.swift:14-55`). No AUDIT-022 class
  leak. **REFUTED.**

---

## Cross-cutting themes

1. **Bounded-vs-unbounded asymmetry at the real-time-audio → async-consumer seam.** The
   dictation path bounds its stream (`AudioRecorder` `.bufferingNewest(200)`); the
   *hours-long meeting* path does not (PDX-001), exactly where it matters most. Every
   downstream stage (PairJoiner, STT scheduler, chunk-result buffer, speech-boundary
   chunker) *is* bounded — the single gap is the capture-event stream. Apply the existing
   bounded pattern at every audio async boundary, with a drop metric.

2. **The new native echo surface widened the trust boundary on a self-signed build.**
   `dlopen`/`dlsym` of `liblocalvqe` (PDX-004/005/008/009) on a bundle with **no hardened
   runtime** (`build_and_package_pdx.sh:91`) means no library-validation backstop, no
   runtime integrity check, env-overridable paths, and `unsafeBitCast` symbols. None are
   remotely exploitable (all assume local access), but they are the right cluster to
   harden first: pin+verify the dylib/model, drop release env overrides, lock the load
   path to the bundle.

3. **Divergent re-implementations of a documented "single source of truth."**
   `OllamaURLValidator` declares itself canonical; `LLMSettingsDraft` re-implements the
   allowlist and diverges (PDX-010), and the transmitting executor re-validates nowhere
   (PDX-011). Same class as the prior audit's "sanitize at the boundary, not the call
   site" — centralize the rule and call it from every surface.

4. **Automatic recording-stop reintroduces a class ADR-017 removed.** ADR-017 dropped
   calendar auto-stop as unreliable; ADR-023's activity auto-stop (PDX-014/015) is
   off-by-default but, once enabled, can stop a wanted recording from a background browser
   tab with no undo. Any automatic stop needs (a) a user-cancellable affordance and (b) a
   tighter "is a call actually happening" signal (frontmost + capture, not capture alone).

5. **Unbounded local per-operation ledgers.** `llm_runs` (PDX-012) and `transform_history`
   grow one row per operation forever. Metadata-only, so not leaks — but the new ledgers
   need retention/caps the older tables were never stress-tested for.

6. **The per-frame-body discipline largely holds.** Contrary to the brief's worry, almost
   every `TimelineView`/animation body is cheap or paused-when-idle (three refutations);
   only one transient micro-indicator allocates (PDX-016). Worth preserving as the pattern
   for new animated surfaces.

---

## Strengths preserved (worth not regressing)

- **Echo suppression degrades gracefully on every failure** — load failure, missing
  symbol, null context, corrupt model, and per-frame C error all fall back to
  `PassthroughMicConditioner` / append the raw mic frame
  (`MeetingEchoSuppressionRuntime.swift:124/132/144/219/226/237`, `MicConditioner.swift:157-166`).
  The **raw mic is always written to disk before any conditioning**
  (`MeetingRecordingService.swift:860`) — invariant 1 holds even when DSP fails.
- **Free-after-in-flight ordering is correct on stop/cancel** — both `await
  drainProcessingTaskAfterCaptureStop()` before `cleanupState()`, and the drain
  `await task.value`s even on its 2 s timeout (`:819-838`). (The one un-drained path is
  the latent PDX-007.)
- **The primary `dlopen` uses an absolute in-bundle path** (not `@rpath`/`DYLD`-searchable)
  (`MeetingEchoSuppressionRuntime.swift:309-311`); dependent `libggml*.dylib` resolve via
  the dylib's own `@loader_path`; all are signed with the same identity.
- **`MeetingAudioPairJoiner` and the whole downstream chain are bounded** — joiner 30-frame
  cap + compaction; `STTScheduler` backlog 120 oldest-drop; `MeetingChunkResultBuffer`
  drains on a failed/dropped sequence; `SpeechBoundaryMeetingLiveAudioChunker` force-emits
  at 10 s. AsyncStream continuations are finished on teardown (`MeetingAudioCaptureService.swift:232/238`).
- **`SharedMicrophoneStream` fan-out is race-safe and alloc-free on the render thread** —
  precomputed handler snapshot under `OSAllocatedUnfairLock`, invoked off-lock
  (`:307-309/458-463`); subscriber mutation serialized on `engineQueue`.
- **The `llm_runs` ledger stores metadata only** (`LLMRun.swift:41-64`) — no prompt,
  transcript, or output text.
- **Local-first holds**: Ollama/LM Studio default to loopback (`LLMProvider.swift:159/180`);
  the LLM formatter is nil-until-configured (`LLMConfigStore.swift:38-39`) — no always-on
  phone-home; the Discover feed is a read-only GET with no body/identifiers
  (`DiscoverService.swift:71-110`).
- **ATS is correctly restrictive** — no `NSAllowsArbitraryLoads`; plaintext http limited to
  LAN / `.local` / `*.ts.net`, matching the canonical validator
  (`build_app_bundle_pdx.sh:479-502`).
- **Selection capture/replacement is local-only** — AX + clipboard with
  `ConcealedType`/`TransientType` hints and change-count-guarded restore
  (`SelectionReader.swift:138-139`, `SelectionReplacementService.swift:298-305`).
- **Telemetry is scrubbed at the boundary** (`TelemetryEvent.swift:1546-1549` →
  `TelemetryErrorClassifier.sanitize` strips `file://`, paths, `http(s)` URLs); custom
  Ask prompts collapse to a fixed `"custom"` identity and cannot carry free-text.
- **`TransformExecutor` never loses the user's clipboard/selection on failure** — every
  cancel/error/empty path calls `restoreClipboardCaptureIfCurrent` before throwing, and
  paste happens only after `.llmCompleted` (no partial-output replacement).
- **`TransformsHotkeyRegistry` retain is balanced** in `deinit`/`stop`/tap-create-failure;
  tap re-enable resets `pressedKeys` — the correct version of the AUDIT-047-adjacent
  re-enable.
- **`MeetingAutoStopDetector` is safe-by-construction** where it counts: it never stops a
  *paused* recording, fires at most once, and only arms after a call was actually seen — so
  a pure in-person recording (no call app ever capturing) never auto-stops.

---

## Recommended follow-up sequence

1. **PDX-001 — bound the meeting capture stream without dropping recording audio.**
   *Not* a one-liner: a deliberate no-drop test (`MeetingAudioCaptureServiceTests.swift:97`)
   and invariant 1 forbid naive `.bufferingNewest`. Decouple the fast disk-write from the
   slow STT/VAD `await` so the consumer drains in real time (drop only STT chunks, which are
   already bounded), then the stream can't accumulate — plus a drop metric (PDX-002). Highest
   reliability/memory payoff.
2. **PDX-014 — gate auto-stop behind a cancellable undo + frontmost check** (with PDX-015).
   The only opt-in path that can discard a wanted recording.
3. **Native-surface hardening sprint — PDX-004/005/009 (then 006/007/008).** Pin + verify
   the dylib and model SHA at load; drop release env overrides / lock the load path to the
   bundle; route `cleanupFailedStart` through the drain; lock `deinit`. Defense-in-depth on
   the flagship native surface.
3. **Validator reconciliation — PDX-010/011.** Make `LLMSettingsDraft` and the executor both
   call `OllamaURLValidator`; delete the divergent copy.
4. **Retention caps — PDX-012** (and `transform_history`). Bounded sweep on the new ledgers.
5. **Polish — PDX-003 (hot-path alloc), PDX-016 (Rhodonea Paths/frame), PDX-017/018
   (Transforms hotkey/coordinator), PDX-013 (document the Discover-thoughts contract).**

---

## Changelog

- **2026-06-04 Pass 1** — Four parallel Explore agents over the post-2026-04-26 delta
  (audio/echo/DSP · concurrency+memory · network/privacy · view-CPU+Transforms+auto-stop).
  18 candidate findings surfaced.
- **2026-06-04 Pass 2** — Orchestrator verified every P0/P1 against source. Tempered five
  severities (PDX-001 P0→P1 on the in-loop disk write; PDX-004/005 P1→P2 on local-access
  precondition; PDX-010 P1→P2 on the ATS backstop). Refuted four pre-identified leads
  (PairJoiner bounds, writing-samples store, systemic TimelineView cost, AppContext
  telemetry leak). Added the ATS / hardened-runtime / static-backstop checks.
- **2026-06-04** — Report only. No code changed. Triage and fix sprint to follow owner
  review.
- **2026-06-04 Fix** — PDX-001 / PDX-002 implemented (owner-approved): new
  `LiveIngestQueue` decouples live STT/VAD ingest from the real-time capture consumer
  (bounded `.bufferingNewest(512)`, drop-oldest, counted as `ingest_queue_drops`); the
  consumer now drains in real time so the unbounded capture stream can't accumulate, and
  recording audio stays on the undroppable fast path. TDD: `LiveIngestQueueTests` (3) green;
  meeting-service suite shows no new failures (3 pre-existing VAD-model env failures
  unrelated). PDX-015 and the P2s remain open.
- **2026-06-04 Fix** — PDX-014 cancellable auto-stop countdown landed (owner-approved):
  new `MeetingAutoStopCountdown` (TDD) + an `AutoStopCountdownPill` red/pink slider in the
  recording-panel header. Auto-stop now starts a cancellable countdown instead of stopping
  silently; clicking the pill keeps recording, the slider expiring stops it. Detection
  heuristic unchanged — the frontmost-arming gate (PDX-015) was declined. App builds;
  countdown unit tests green.
