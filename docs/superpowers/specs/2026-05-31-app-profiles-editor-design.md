# App Profiles editor — design

> Status: **APPROVED** (brainstorm 2026-05-31). Productizes F4 (per-app dictation
> cleanup profiles) into a managed, DB-backed surface with a privacy split between
> generic samples (committed) and the user's real prompts (local + vault).

## Overview

Today F4 ("per-app LLM profiles + AX context injection") resolves a frontmost-app
**profile** at dictation start and uses its `promptOverride` to steer the LLM
cleanup. Profiles are a **hardcoded array** (`AppProfile.defaults`, ~13 entries
with full prompt text) checked into the public repo — there is no UI and no
persistence.

This feature:

1. Adds a first-class **"App Profiles"** section to the main-window sidebar (peer
   to Vocabulary and Transforms) with a **tab-per-script** editor and full CRUD.
2. Persists profiles to **GRDB** so they are user-editable and survive updates.
3. Splits **generic committed samples** from the user's **real prompts**, which
   load silently from a **gitignored local seed** and are documented in the vault.

### Terminology

A **script** is one `AppProfile`: a named prompt template that applies to a **set
of apps** (`bundleIDs`). One script → many apps (e.g. *Email* → Apple Mail +
Outlook). This matches the existing model; no conceptual change.

## Goals

- Manage per-app dictation scripts in-app: create, edit, delete, enable/disable,
  add/remove the apps a script applies to.
- Test a script live: type a sample sentence, see the cleaned output via the
  configured AI provider.
- Keep the user's real prompt text out of the public Git repo while still
  shipping a useful out-of-box experience and loading the user's own prompts
  silently on their machine.

## Non-goals

- Cloud sync / sharing of profiles.
- Per-script model or provider selection (scripts use the global AI provider).
- Changing how/when profiles are *resolved* at dictation time (frontmost-app
  bundle ID, first enabled match wins) — that logic is unchanged.

## Data model & persistence

**Model (`Sources/MacParakeetCore/Models/AppProfile.swift`)** — extend:

| Field | Type | Notes |
|-------|------|-------|
| `id` | `String` | stable id (existing) |
| `displayName` | `String` | script name = tab label (existing) |
| `bundleIDs` | `[String]` | apps the script applies to (existing) |
| `promptOverride` | `String?` | prompt template with `{{TRANSCRIPT}}` (existing) |
| `enabled` | `Bool` | existing |
| `sortOrder` | `Int` | **new** — stable tab order |

Add GRDB `Codable`/`FetchableRecord`/`PersistableRecord` conformance. `bundleIDs`
persists as a JSON-encoded text column.

**Repository (`Sources/MacParakeetCore/Database/AppProfileRepository.swift`, new)** —
one-per-table GRDB repository: `fetchAll()` (ordered by `sortOrder`), `fetch(id:)`,
`save(_:)` (insert/update), `delete(id:)`, `reorder(_:)`. Mirrors `PromptRepository`.

**Migration `v0.21-app-profiles`** (next after the auto-notes `v0.20`) — creates the
`app_profile` table only. **Does not seed** (seeding is app-startup; see below) so
Core/DB stay free of any `Bundle.main` dependency for tests/CLI.

## Resolution wiring (single source of truth)

Introduce **`AppProfileStore`** (in `MacParakeetViewModels`): loads profiles from
`AppProfileRepository` and is the single source consumed by **both** the editor and
dictation resolution. Because these two consumers have different isolation needs, the
store exposes two faces over the **same** loaded data:

- **UI face** — `@MainActor @Observable` cached `[AppProfile]` array the editor view
  model binds to.
- **Resolution face** — a **lock-guarded snapshot** (`[AppProfile]` behind an
  `OSAllocatedUnfairLock` / `Mutex`, `Sendable`) read by `AppEnvironment`'s
  `@Sendable resolveActiveProfile` closure (currently `AppProfile.resolve(bundleID:)`
  over the hardcoded `defaults`). Every write-through CRUD op updates both faces
  atomically, so a saved edit is visible to the next dictation without a MainActor
  hop. This mirrors how `UserDefaultsAppRuntimePreferences` is `@unchecked Sendable`
  for the dictation path.

The pure `AppProfile.resolve(bundleID:from:)` is unchanged (still takes an explicit
list, still first-enabled-match-wins). When no script matches, dictation falls back
to the user's default formatter template exactly as today.

## Seeding & privacy

**Repo (`AppProfile.defaults`)** is reduced to **3 generic, non-personal samples**
(Email / Notes / Chat) — safe to commit, gives other users a starting point.

**The user's real prompts** live in a **gitignored** local seed:
`seeds/app-profiles.local.json` (repo root). `.gitignore` gains `seeds/*.local.json`.

**Build** (`scripts/dist/build_app_bundle.sh`): when `seeds/app-profiles.local.json`
exists, copy it into the bundle as `Contents/Resources/ProfileSeeds/app-profiles.json`.
Public/CI builds (no local file) ship nothing extra. Same local-asset-at-build-time
pattern as the Silero (F22) and echo (F8) assets. The PDX wrapper
(`build_and_package_pdx.sh`) inherits this via the canonical script.

**First-run seed (`AppProfileSeeder`, app startup)** — runs once after migration,
only when `app_profile` is empty:
1. If `Resources/ProfileSeeds/app-profiles.json` is present in the bundle → seed
   from it (the user's real scripts).
2. Else → seed from the 3 generic `AppProfile.defaults`.
Idempotent (guarded by table emptiness). Lives in the app layer (needs
`Bundle.main`); tests seed repositories explicitly.

**One-time migration of the current set:** before genericizing `AppProfile.defaults`,
generate `seeds/app-profiles.local.json` from the current 13 entries. On the user's
machine they load silently; the repo keeps only the 3 generics.

**Caveat (documented):** the bundled seed ships inside the user's signed `.app`
(not in Git). Keep that in mind before distributing the `.app` publicly — the
concern addressed here is *GitHub* exposure.

## UI — sidebar section "App Profiles"

New main-window sidebar case `appProfiles` ("App Profiles", icon e.g.
`person.crop.rectangle.stack`), placed near Vocabulary/Transforms in
`MainWindowView`. Views in `Sources/MacParakeet/Views/AppProfiles/`.

Layout — **scrollable tab strip, one tab per script**, with a detail editor below:

```
[Email][Notes][Chat][Terminal][Code]  ◂▸ (horizontal scroll)   [+ New script]
─────────────────────────────────────────────────────────────────────────────
Name:        [ Email ]
Applies to:  [Apple Mail ✕] [Outlook ✕]   [+ add app]
Prompt:
  ┌───────────────────────────────────────────────────────────┐
  │ Clean up ASR speech for a business email…  {{TRANSCRIPT}}  │
  └───────────────────────────────────────────────────────────┘
Try it:   in [ hey can u send me the deck ]   → out: "Hi — can you send me the deck?"
[ enabled ◉ ]                                              [ Delete script ]
```

- **Tab strip:** horizontal `ScrollView` of script pills (handles any count; keeps
  the tab feel the user wants). `[+ New script]` appends a script.
- **Applies-to:** chips of bundle IDs with per-chip remove. **`[+ add app]`** opens
  an `NSOpenPanel` rooted at `/Applications`; the chosen `.app`'s
  `CFBundleIdentifier` is read and added. A manual "type bundle ID" field is also
  offered. **Duplicate detection:** if a bundle ID already belongs to another
  script, show an inline warning (resolution is first-match-by-`sortOrder`, so the
  earlier script wins) — non-blocking.
- **Prompt:** multiline editor; must contain `{{TRANSCRIPT}}` (inline hint if
  missing). Empty `promptOverride` = fall back to the global formatter for those
  apps.
- **Try it:** sample input → live cleaned output through the configured AI provider
  (reuses the dictation refine path with this script's prompt). Runs off-main, shows
  a spinner, surfaces errors. When no provider is configured, shows "Configure AI in
  Settings to test."
- **Delete script** with confirmation; **enabled** toggle disables the script
  without deleting.

A one-line pointer in **Settings → AI** ("Per-app dictation scripts → App Profiles")
links here for discoverability.

## Components (isolation)

| Unit | Responsibility | Depends on |
|------|----------------|-----------|
| `AppProfile` (model) | data + pure `resolve`; GRDB conformance | Foundation, GRDB |
| `AppProfileRepository` | CRUD over `app_profile` | GRDB |
| `AppProfileStore` | dual face: `@MainActor @Observable` array for the editor + lock-guarded `Sendable` snapshot for the `@Sendable` resolve closure; write-through CRUD updates both | repository |
| `AppProfileSeeder` | one-time first-run seed (bundled JSON ▸ generic defaults) | repository, Bundle |
| `AppProfilesViewModel` | editor state: selection, edit buffers, add/remove app, save, delete, new, live-preview | store, LLM service (injected) |
| `AppProfilesView` (+ subviews) | sidebar section UI: tab strip, editor, app-picker, try-it | view model |
| build script change | bundle local seed when present | — |

## Testing

- `AppProfileRepository`: CRUD + ordering + JSON `bundleIDs` round-trip (in-memory SQLite).
- Migration `v0.21`: table exists, existing DBs upgrade cleanly.
- `AppProfileSeeder`: seeds generics when no bundle file; seeds bundle file when
  present; **no-op when table already populated** (idempotent).
- `AppProfilesViewModel`: add/remove app, save, delete, new script, duplicate-bundle
  warning, live-preview success/error (mocked LLM service).
- Existing `AppProfile.resolve(...)` tests stay; add one asserting resolution reads
  the store's array.

## Vault documentation

New folder **`🏡 projects/MacParakeet PDX Custom Prompts/`** (beside the Feature
Inventory), one note per script: app name, bundle IDs, full prompt text. These are
the canonical private copies (the vault is not Git). The Feature Inventory's **F4**
row gains a link to this folder. The repo itself ships only the 3 generic samples.

## Rollout / follow-ups

- Inventory: update **F4** (now productized — editor + DB + privacy split) and add a
  short pointer to the vault prompt folder. Note the migration `v0.21` and the new
  sidebar section.
- The generated `seeds/app-profiles.local.json` is a personal artifact; regenerate
  it if the user edits scripts and wants the build to re-bundle the latest.
- Out of scope but natural next steps: profile import/export UI, per-script provider.
