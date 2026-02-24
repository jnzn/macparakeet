# MEMORY

Last updated: 2026-02-24

## Current Baseline
- Branch strategy: direct commits to `main` are in use; keep commits small and reversible.
- STT runtime is FluidAudio/CoreML/ANE (native Swift). Python runtime is fully removed from tracked files.
- CLI executable name is `macparakeet-cli` (not `macparakeet`).

## Runtime Guardrails
- Onboarding performance copy is aligned to FluidAudio numbers:
  - `155x realtime`
  - `~23 seconds for 60 minutes`
- Do not allow normal startup from a mounted DMG (`/Volumes/...`) in production app runs; macOS TCC may not register microphone/accessibility permissions correctly from translocated/DMG launches, leading to silent dictation failure despite onboarding success. (2026-02-24)
- FFmpeg portability validation for bundled release binaries should reject both:
  - non-system absolute dylib paths, and
  - `@rpath` / `@loader_path` / `@executable_path` references.
  This prevents Homebrew-linked or otherwise non-portable FFmpeg builds from slipping into the app bundle. (2026-02-24)

## CI / Verification
- CI workflow now prints toolchain versions (`xcodebuild -version`, `swift --version`).
- Local CI-parity helper exists: `scripts/dev/ci_local.sh`
  - Runs: `swift package clean && swift test --parallel`
- CI is configured to skip docs/spec-only changes:
  - `docs/**`, `spec/**`, `**/*.md`
  - Manual trigger remains available via `workflow_dispatch`.

## Test Stability Pattern
- Avoid shared-state test flakiness from `UserDefaults.standard`.
- Preferred pattern:
  - add injectable defaults API in production code where needed.
  - use `UserDefaults(suiteName:)` per test + teardown cleanup.
- TriggerKey tests were stabilized using this pattern.

## Docs/Spec Consistency Rules
- Keep runnable command examples aligned with actual binary names (`macparakeet-cli`).
- Historical mentions of Python/daemon are acceptable only when clearly labeled as historical/migration context.
