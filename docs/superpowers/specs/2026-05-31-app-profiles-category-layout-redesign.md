# App Profiles — category model + master-detail layout redesign

> Status: **APPROVED** (brainstorm 2026-05-31). Follow-up to
> `2026-05-31-app-profiles-editor-design.md`. Reorganizes the 11 seeded scripts
> into 7 purpose categories and replaces the horizontal tab strip with a
> master-detail inner sidebar + a split right pane.

## Overview

The shipped App Profiles editor (F4) uses a horizontal scrollable **tab strip**
over 11 seeded scripts, with a stacked editor below. This redesign:

1. **Consolidates** the 11 scripts into **7 purpose categories** (one script each,
   apps unioned, one prompt each).
2. Replaces the tab strip with a vertical **inner sidebar** (master list of
   categories) + a **split right pane**.
3. Preserves the original 11 prompts in a vault **archive** and documents the 7
   new ones.

No change to the model / repository / store / resolution — only the seeded data,
the seeder (a one-time re-seed), and the view.

## Category model (11 → 7)

Each category is one `AppProfile`: the union of the source scripts' `bundleIDs`,
keeping the **primary** script's `promptOverride`. Bundle IDs come from the
current `seeds/app-profiles.local.json`.

| # | id | displayName | Source scripts (apps unioned) | Prompt kept from |
|---|----|-------------|-------------------------------|------------------|
| 0 | `cat-email` | E-mail | email | email |
| 1 | `cat-notes` | Notes | obsidian + notion + linear | obsidian |
| 2 | `cat-messaging` | Messaging | messages + slack | messages |
| 3 | `cat-teams` | Teams | teams | teams |
| 4 | `cat-calendar` | Calendar | calendar | calendar |
| 5 | `cat-terminal` | Terminal | terminal | terminal |
| 6 | `cat-development` | Development | ide | ide |

**Dropped:** `things` (Things 3) — removed entirely. The absorbed prompts
(`notion`, `linear`, `slack`) are dropped from the seed but preserved in the vault
archive.

## Layout

Main-window sidebar section "App Profiles" → master-detail:

```
┌──────────────┬───────────────────────────────────────────────┐
│ inner sidebar│  Applies to   (top ~15%)                        │
│ (categories) │  [Apple Mail ✕] [Outlook ✕]      [+ add app]   │
│ ▸ E-mail     ├───────────────────────────────────────────────┤
│   Notes      │  Prompt   (~42%, top half of the remainder)     │
│   Messaging  │  ┌─────────────────────────────────────────┐   │
│   Teams      │  │ …{{TRANSCRIPT}}                          │   │
│   Calendar   │  └─────────────────────────────────────────┘   │
│   Terminal   ├───────────────────────────────────────────────┤
│   Development│  Try it   (~42%, bottom half — two columns)     │
│              │  ┌─ Sample (as-is) ─┐  ┌─ Cleaned (live) ────┐ │
│ [+ New]      │  │ editable input   │→ │ read-only output    │ │
│              │  │        [Run ▶]   │  │                     │ │
└──────────────┴──┴──────────────────┴──┴─────────────────────┴─┘
```

- **Inner sidebar** (~170pt, `List`): the 7 categories ordered by `sortOrder`;
  selection drives the right pane. `+ New` at the bottom appends a category;
  delete via context menu or the detail pane (with confirmation).
- **Right pane**, vertical split:
  - **Apps (~15%):** the selected category's `bundleIDs` as removable chips +
    `add app` (NSOpenPanel picker or manual bundle-ID field). (Today's "Applies
    to", moved to the top.)
  - **Prompt (~42%):** the prompt `TextEditor` (`{{TRANSCRIPT}}` hint as today).
  - **Try it (~42%):** two side-by-side boxes — left = editable **Sample (as-is)**
    bound to `previewInput`; right = read-only **Cleaned** showing `previewOutput`
    (live via the configured AI provider) with a spinner/`previewError`; a **Run**
    button. The not-configured message ("Configure AI in Settings to test.") and
    stale-result guard from the prior spec are preserved.
- Proportions are guidance (use `GeometryReader` or `.layoutPriority`/fixed
  fractions); exact pixels are not contractual. Enabled toggle + Delete live in
  the detail pane (e.g. a small footer row).

## Re-seeding the running app

The seeder currently only seeds an empty table, so a new bundled seed would not
reach the user's already-populated DB. Add a **seed-version** marker:

- `AppProfileSeeder` gains `currentSeedVersion` (bump to `2`) and a
  `seedVersionDefaultsKey`. On launch: if the stored version `< currentSeedVersion`,
  **replace** all rows in `app_profile` with the bundled/generic seed set, then
  store the new version. This is a deliberate clobber (the user requested the
  reorg; the originals are archived in the vault). First-ever install still goes
  through the existing empty-table path and also records the version.
- Keep the empty-table `seedIfEmpty` behavior; the version-bump replace is a
  separate, explicit path (`reseedIfVersionOutdated`). Both are app-startup
  (need `Bundle.main`); unit-tested with an injected version + in-memory repo.
- Regenerate `seeds/app-profiles.local.json` to the 7 categories (a dev script
  reads the current 11, unions apps per the mapping, keeps the primary prompt,
  drops Things). The build bundles it as before.

## Vault documentation

In `🏡 projects/MacParakeet PDX Custom Prompts/`:
- Move the existing 11 notes into a new `Archive/` subfolder (preserve verbatim).
- Create 7 new notes (one per category) from the regenerated seed.
- Update `_index.md`: list the 7, link `Archive/` for the originals.

## Implementation surface

| File | Change |
|------|--------|
| `Sources/MacParakeet/Views/AppProfiles/AppProfilesView.swift` | Rewrite: master-detail inner sidebar + 15/42/42 split + side-by-side Try-it |
| `Sources/MacParakeetViewModels/AppProfilesViewModel.swift` | Minor: ensure `previewInput`/`previewOutput`/`previewError` drive the two boxes; selection from the sidebar (`select(id:)` already exists) |
| `Sources/MacParakeetCore/Services/AppProfileSeeder.swift` | Add `currentSeedVersion` + `reseedIfVersionOutdated(repository:bundledSeedURL:defaults:)` |
| `Sources/MacParakeet/App/AppEnvironment.swift` | Call `reseedIfVersionOutdated` at startup (after `seedIfEmpty`) |
| `seeds/app-profiles.local.json` | Regenerated to the 7 categories (gitignored) |
| `Tests/MacParakeetTests/Services/AppProfileSeederTests.swift` | Add version-bump replace + no-op-when-current tests |
| Vault + Feature Inventory F4 | Archive 11, add 7, update index + F4 |

## Out of scope
Reorder UI, per-category provider, import/export. Model/repository/store/resolution
unchanged.
