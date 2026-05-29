# FluidAudio ↔ Silero VAD Model Relationship

> Status: **ACTIVE**. How the meeting voice-activity-detection (VAD) model is
> provided, pinned, cached, and bundled — and the one maintenance coupling that
> bites if you forget it.

## Who owns what

| Concern | Owner |
|---|---|
| VAD engine (CoreML inference) | **FluidAudio** dependency (`VadManager`) |
| Which VAD model + version | **FluidAudio**, hardcoded — not us |
| Download + on-disk cache | **FluidAudio** (`DownloadUtils`) |
| App-side runtime use | `MeetingVADService` (MacParakeetCore) |
| Bundling the model in the app (PDX) | `MeetingVADService.seedBundledModel*` + `scripts/dist/build_app_bundle.sh` |

MacParakeet does **not** pick or version the VAD model. FluidAudio does.

## The pin (this is the crux)

FluidAudio hardcodes the model in `ModelNames.VAD`:

```swift
public static let sileroVad     = "silero-vad-unified-256ms-v6.0.0"
public static let sileroVadFile = sileroVad + ".mlmodelc"
public static let requiredModels: Set<String> = [ sileroVadFile ]
case vad = "FluidInference/silero-vad-coreml"   // HuggingFace repo
```

- The model name/version is **tied to the FluidAudio package version**. It changes only when FluidAudio is bumped — never on its own, never "latest at launch."
- Currently pinned: **FluidAudio 0.14.5** (`Package.swift`: `.upToNextMinor(from: "0.14.5")`). As of 2026-05-29, 0.14.7 is the latest; 0.14.6/0.14.7 did **not** change the VAD model.

## Cache + download behavior

- Cache dir: `~/Library/Application Support/FluidAudio/Models/silero-vad/`
  (contains `config.json` + `silero-vad-unified-256ms-v6.0.0.mlmodelc/`).
- FluidAudio's check is **existence-based, not version-aware**: "do the pinned
  files exist on disk?" → if yes, load; if no, download from HuggingFace.
- So it **downloads once and never re-downloads** (until the pinned name changes,
  which produces a *different* filename → a fresh download, leaving the old one
  orphaned).

## How MacParakeet uses it

- `MeetingVADService.makeIfModelCached()` — runtime entry; **cached-only**, never
  downloads (so meeting start never blocks on the network). Falls back to fixed
  chunking if the model is absent.
- `MeetingVADService.downloadModel()` — used by `MeetingVADModelPreparer`
  (onboarding / launch pre-warm) to fetch it up front.
- `isModelCached()` checks exactly `ModelNames.VAD.requiredModels` in
  `MLModelConfigurationUtils.defaultModelsDirectory(for: .vad)`.

## PDX bundling (F22) — and the coupling that matters

To avoid the HuggingFace download (and a per-binary Little Snitch prompt that
silently blocked it), the PDX edition **ships the model in the app**:

- `BundledModels/SileroVAD/silero-vad/` (committed, ~1 MB) →
  `scripts/dist/build_app_bundle.sh` copies it into
  `Contents/Resources/SileroVAD/silero-vad`.
- At runtime, `MeetingVADService.seedBundledModelIfNeeded()` copies it from the
  app bundle into FluidAudio's cache **if absent** (download stays the dev/test
  fallback).

### ⚠️ Upgrade coupling — read before bumping FluidAudio

The bundled model name is **frozen** at `silero-vad-unified-256ms-v6.0.0`. If a
FluidAudio upgrade changes `ModelNames.VAD.sileroVad`:

1. `isModelCached()` now looks for the **new** filename → the stale bundled copy
   no longer satisfies it → `seedBundledModelIfNeeded()` effectively no-ops and
   the app falls back to **downloading** the new model (reintroducing the network/
   firewall dependency we bundled to avoid).
2. **Fix:** after `swift package update`, diff `ModelNames.VAD.sileroVad`. If it
   changed:
   - run the app once (or the gated `MeetingVADModelDownloadIntegrationTests`) to
     download the new model into the cache,
   - re-copy `~/Library/Application Support/FluidAudio/Models/silero-vad/` →
     `BundledModels/SileroVAD/silero-vad/`,
   - commit the new model + delete the old `.mlmodelc`.

**Checklist when upgrading FluidAudio:** does `ModelNames.VAD.sileroVad` still
equal the directory name under `BundledModels/SileroVAD/silero-vad/`? If not,
re-bundle (above). (Same logic applies to Parakeet/diarization, but those are
download-only — not bundled — so they self-heal.)
