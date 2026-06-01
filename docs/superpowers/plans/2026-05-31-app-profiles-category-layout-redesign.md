# App Profiles Category + Layout Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Consolidate the 11 seeded App Profiles into 7 purpose categories and replace the tab strip with a master-detail inner sidebar + split right pane (apps ~15% / prompt ~42% / side-by-side Try-it ~42%).

**Architecture:** Regenerate the gitignored seed to 7 categories; add a one-time **seed-version re-seed** to `AppProfileSeeder` that replaces the old set in the already-populated DB; rewrite `AppProfilesView` into master-detail. Model / repository / store / resolution / `AppProfilesViewModel` API are unchanged (the view reuses existing VM methods).

**Tech Stack:** Swift 6, SwiftUI, GRDB, XCTest. Work in `/Users/jnzn08/Developer/macparakeet` (local disk; never the iCloud copy). Build `swift build`; focused tests only (`swift test --filter …` — the full suite hangs). Commit per task. Spec: `docs/superpowers/specs/2026-05-31-app-profiles-category-layout-redesign.md`.

---

## File Structure

| File | Responsibility | Action |
|------|----------------|--------|
| `seeds/app-profiles.local.json` | Regenerated to the 7 categories (gitignored) | Regenerate |
| `Sources/MacParakeetCore/Services/AppProfileSeeder.swift` | `currentSeedVersion` + `reseedIfVersionOutdated` + version-recording in `seedIfEmpty` | Modify |
| `Sources/MacParakeet/App/AppEnvironment.swift` | Call `reseedIfVersionOutdated` after `seedIfEmpty` | Modify |
| `Sources/MacParakeet/Views/AppProfiles/AppProfilesView.swift` | Rewrite: master-detail + split + side-by-side Try-it | Rewrite |
| `Tests/MacParakeetTests/Services/AppProfileSeederTests.swift` | version-bump replace + no-op-when-current + records-version tests | Modify |
| Vault `🏡 projects/MacParakeet PDX Custom Prompts/` + Feature Inventory F4 | Archive 11, add 7, update index + F4 | Docs |

---

## Task 1: Regenerate the seed (11 → 7 categories)

**Files:** Regenerate `seeds/app-profiles.local.json` (gitignored — not committed).

- [ ] **Step 1: Write + run the regen script**

The current seed has the 11 real profiles (ids `email, obsidian, teams, messages, terminal, slack, notion, linear, calendar, things, ide`). Produce 7 categories by unioning `bundleIDs` per the mapping and keeping the primary prompt; drop `things`. Run:

```bash
cat > /tmp/regen_profiles.py <<'PY'
import json
SEED = "/Users/jnzn08/Developer/macparakeet/seeds/app-profiles.local.json"
src = {p["id"]: p for p in json.load(open(SEED))}

# (new id, displayName, [source ids: first = primary prompt], )
CATS = [
    ("cat-email",       "E-mail",      ["email"]),
    ("cat-notes",       "Notes",       ["obsidian", "notion", "linear"]),
    ("cat-messaging",   "Messaging",   ["messages", "slack"]),
    ("cat-teams",       "Teams",       ["teams"]),
    ("cat-calendar",    "Calendar",    ["calendar"]),
    ("cat-terminal",    "Terminal",    ["terminal"]),
    ("cat-development", "Development", ["ide"]),
]
out = []
for order, (cid, name, srcs) in enumerate(CATS):
    bundle, seen = [], set()
    for sid in srcs:
        for b in src[sid]["bundleIDs"]:
            if b not in seen:
                seen.add(b); bundle.append(b)
    out.append({
        "id": cid,
        "displayName": name,
        "bundleIDs": bundle,
        "promptOverride": src[srcs[0]]["promptOverride"],  # primary
        "enabled": True,
        "sortOrder": order,
    })
json.dump(out, open(SEED, "w"), indent=2, sort_keys=True)
print(f"Wrote {len(out)} categories:")
for c in out:
    print(f"  {c['sortOrder']} {c['displayName']:12} {len(c['bundleIDs'])} apps  ({', '.join(c['bundleIDs'])})")
PY
/usr/bin/python3 /tmp/regen_profiles.py
```

- [ ] **Step 2: Verify**

Run: `/usr/bin/python3 -c "import json;d=json.load(open('/Users/jnzn08/Developer/macparakeet/seeds/app-profiles.local.json'));print(len(d),[p['id'] for p in d])"`
Expected: `7 ['cat-email', 'cat-notes', 'cat-messaging', 'cat-teams', 'cat-calendar', 'cat-terminal', 'cat-development']`
Confirm still gitignored: `git -C /Users/jnzn08/Developer/macparakeet check-ignore seeds/app-profiles.local.json` prints the path; `git status --short seeds/` shows it untracked/ignored (NOT staged).

- [ ] **Step 3: No commit** (the seed is gitignored). Done.

---

## Task 2: Seeder — one-time seed-version re-seed

**Files:**
- Modify: `Sources/MacParakeetCore/Services/AppProfileSeeder.swift`
- Test: `Tests/MacParakeetTests/Services/AppProfileSeederTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `AppProfileSeederTests.swift` (inside the class). Use an isolated `UserDefaults` suite per test:

```swift
    private func freshDefaults() -> UserDefaults {
        let suite = "appprofileseeder-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func bundleURL(_ profiles: [AppProfile]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID()).json")
        try JSONEncoder().encode(profiles).write(to: url)
        return url
    }

    func testSeedIfEmptyRecordsSeedVersion() throws {
        let repo = try makeRepo()
        let defaults = freshDefaults()
        try AppProfileSeeder.seedIfEmpty(repository: repo, bundledSeedURL: nil, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: AppProfileSeeder.seedVersionDefaultsKey), AppProfileSeeder.currentSeedVersion)
    }

    func testReseedReplacesWhenVersionOutdated() throws {
        let repo = try makeRepo()
        // Simulate an existing pre-versioning install: populated table, no marker.
        try repo.save(AppProfile(id: "old1", displayName: "Old", bundleIDs: ["com.old"], promptOverride: "OLD"))
        let defaults = freshDefaults()  // version 0 (missing)
        let newSet = [AppProfile(id: "cat-email", displayName: "E-mail", bundleIDs: ["com.apple.mail"], promptOverride: "NEW {{TRANSCRIPT}}", enabled: true, sortOrder: 0)]
        let url = try bundleURL(newSet)
        defer { try? FileManager.default.removeItem(at: url) }

        try AppProfileSeeder.reseedIfVersionOutdated(repository: repo, bundledSeedURL: url, defaults: defaults)

        XCTAssertEqual(try repo.fetchAll().map(\.id), ["cat-email"])
        XCTAssertEqual(defaults.integer(forKey: AppProfileSeeder.seedVersionDefaultsKey), AppProfileSeeder.currentSeedVersion)
    }

    func testReseedNoOpWhenVersionCurrent() throws {
        let repo = try makeRepo()
        try repo.save(AppProfile(id: "keep", displayName: "Keep", bundleIDs: [], promptOverride: nil))
        let defaults = freshDefaults()
        defaults.set(AppProfileSeeder.currentSeedVersion, forKey: AppProfileSeeder.seedVersionDefaultsKey)
        try AppProfileSeeder.reseedIfVersionOutdated(repository: repo, bundledSeedURL: nil, defaults: defaults)
        XCTAssertEqual(try repo.fetchAll().map(\.id), ["keep"])  // untouched
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppProfileSeederTests`
Expected: FAIL — `seedVersionDefaultsKey` / `currentSeedVersion` / `reseedIfVersionOutdated` / the `defaults:` param don't exist.

- [ ] **Step 3: Implement**

Replace the body of `Sources/MacParakeetCore/Services/AppProfileSeeder.swift` with:

```swift
import Foundation

/// First-run seeding + one-time version-bump re-seed of the `app_profile` table.
///
/// `seedIfEmpty`: seeds an empty table (bundled local seed wins over generics)
/// and records the seed version, so user edits are never clobbered on later runs.
///
/// `reseedIfVersionOutdated`: when the bundled seed set changes shape (e.g. the
/// 11→7 category reorg), bump `currentSeedVersion`. On launch, an already-populated
/// DB whose stored version is older is **replaced** with the current seed set. This
/// is a deliberate clobber tied to a version bump (the originals are archived in the
/// vault); it does not run on every launch.
public enum AppProfileSeeder {
    /// Bump whenever the bundled/generic seed set is intentionally reshaped.
    /// v2 = the 11→7 category consolidation.
    public static let currentSeedVersion = 2
    public static let seedVersionDefaultsKey = "appProfileSeedVersion"

    public static func seedIfEmpty(
        repository: AppProfileRepositoryProtocol,
        bundledSeedURL: URL?,
        defaults: UserDefaults = .standard
    ) throws {
        guard try repository.fetchAll().isEmpty else { return }
        for profile in resolveSeeds(bundledSeedURL) {
            try repository.save(profile)
        }
        defaults.set(currentSeedVersion, forKey: seedVersionDefaultsKey)
    }

    public static func reseedIfVersionOutdated(
        repository: AppProfileRepositoryProtocol,
        bundledSeedURL: URL?,
        defaults: UserDefaults = .standard
    ) throws {
        let stored = defaults.integer(forKey: seedVersionDefaultsKey)  // 0 if missing
        guard stored < currentSeedVersion else { return }
        let existing = try repository.fetchAll()
        guard !existing.isEmpty else { return }  // empty → seedIfEmpty already handled + set version
        for p in existing { _ = try repository.delete(id: p.id) }
        for profile in resolveSeeds(bundledSeedURL) {
            try repository.save(profile)
        }
        defaults.set(currentSeedVersion, forKey: seedVersionDefaultsKey)
    }

    /// Bundled local seed (the user's real prompts) wins; otherwise generic defaults.
    private static func resolveSeeds(_ bundledSeedURL: URL?) -> [AppProfile] {
        if let url = bundledSeedURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([AppProfile].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return AppProfile.defaults
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppProfileSeederTests`
Expected: PASS (original 3 + new 3 = 6). The original `seedIfEmpty` tests still compile (the new `defaults:` param is defaulted).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/Services/AppProfileSeeder.swift Tests/MacParakeetTests/Services/AppProfileSeederTests.swift
git commit -m "feat(pdx): AppProfileSeeder one-time seed-version re-seed (v2 = 7 categories)"
```

---

## Task 3: Wire the re-seed at startup

**Files:** Modify `Sources/MacParakeet/App/AppEnvironment.swift`

- [ ] **Step 1: Find the existing seed call**

Run: `grep -n "AppProfileSeeder.seedIfEmpty\|bundledProfileSeedURL\|AppProfileSeeder" Sources/MacParakeet/App/AppEnvironment.swift`

- [ ] **Step 2: Add the reseed call immediately after `seedIfEmpty`**

Right after the existing `try? AppProfileSeeder.seedIfEmpty(repository: appProfileRepository, bundledSeedURL: bundledProfileSeedURL)` line, add:

```swift
        try? AppProfileSeeder.reseedIfVersionOutdated(repository: appProfileRepository, bundledSeedURL: bundledProfileSeedURL)
```

(Both use `.standard` UserDefaults by default — correct for the app. Use the actual local variable names found in Step 1 if they differ.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacParakeet/App/AppEnvironment.swift
git commit -m "feat(pdx): run AppProfile re-seed on seed-version bump at startup"
```

---

## Task 4: Rewrite AppProfilesView (master-detail + split + side-by-side Try-it)

**Files:** Rewrite `Sources/MacParakeet/Views/AppProfiles/AppProfilesView.swift`

No unit test (SwiftUI view — project policy). Verified by `swift build`. Reuses existing VM API: `store.profiles`, `selectedID`, `select(id:)`, `newScript()`, `deleteSelected()`, `draft` (with `displayName`/`bundleIDs`/`promptOverride`/`enabled`), `addApp/removeApp`, `duplicateBundleIDs`, `previewInput`, `previewOutput`, `previewError`, `isPreviewing`, `runPreview(sample:)`, and `AppProfileAppPicker.pickBundleID()`.

- [ ] **Step 1: Replace the file contents**

```swift
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct AppProfilesView: View {
    @Bindable var viewModel: AppProfilesViewModel
    @State private var manualBundleID = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 180)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("App Profiles")
    }

    // MARK: Inner master sidebar (categories)

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { viewModel.selectedID },
                set: { if let id = $0 { viewModel.select(id: id) } }
            )) {
                ForEach(viewModel.store.profiles) { profile in
                    Text(profile.displayName.isEmpty ? "Untitled" : profile.displayName)
                        .opacity(profile.enabled ? 1 : 0.5)
                        .tag(profile.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                viewModel.select(id: profile.id)
                                showDeleteConfirm = true
                            } label: { Text("Delete") }
                        }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button { viewModel.newScript() } label: {
                Label("New", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    // MARK: Detail (apps ~15% / prompt ~42% / Try-it ~42%)

    @ViewBuilder
    private var detail: some View {
        if viewModel.draft != nil {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                TextField("Category name", text: Binding(
                    get: { viewModel.draft?.displayName ?? "" },
                    set: { viewModel.draft?.displayName = $0; viewModel.save() }
                ))
                .textFieldStyle(.roundedBorder)

                appsSection                                   // ~15% (natural height)
                Divider()
                promptSection.frame(maxHeight: .infinity)     // ~42%
                Divider()
                tryItSection.frame(maxHeight: .infinity)      // ~42%
                footer
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .confirmationDialog(
                "Delete \"\(viewModel.draft.map { $0.displayName.isEmpty ? "Untitled" : $0.displayName } ?? "Untitled")\"?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { viewModel.deleteSelected() }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            Text("No categories yet. Add one with \u{201C}New.\u{201D}")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Applies to").font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
            FlowChips(items: viewModel.draft?.bundleIDs ?? []) { bundleID in
                viewModel.removeApp(bundleID: bundleID); viewModel.save()
            }
            if !viewModel.duplicateBundleIDs.isEmpty {
                Text("⚠︎ Also used by another category: \(viewModel.duplicateBundleIDs.sorted().joined(separator: ", ")). The earlier one wins.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button {
                    if let id = AppProfileAppPicker.pickBundleID() { viewModel.addApp(bundleID: id); viewModel.save() }
                } label: { Label("Add app…", systemImage: "plus.app") }
                TextField("or paste bundle ID (e.g. com.apple.mail)", text: $manualBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.addApp(bundleID: manualBundleID); manualBundleID = ""; viewModel.save() }
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt").font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { viewModel.draft?.promptOverride ?? "" },
                set: { viewModel.draft?.promptOverride = $0.isEmpty ? nil : $0; viewModel.save() }
            ))
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .border(DesignSystem.Colors.border)
            if !(viewModel.draft?.promptOverride?.contains("{{TRANSCRIPT}}") ?? false) {
                Text("Tip: include {{TRANSCRIPT}} where the dictated text goes.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var tryItSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try it").font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                // Left: editable sample (as-is)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sample (as-is)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $viewModel.previewInput)
                        .font(.body).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .border(DesignSystem.Colors.border)
                    Button {
                        Task { await viewModel.runPreview(sample: viewModel.previewInput) }
                    } label: {
                        if viewModel.isPreviewing { ProgressView().controlSize(.small) } else { Label("Run", systemImage: "play.fill") }
                    }
                    .disabled(viewModel.previewInput.isEmpty || viewModel.isPreviewing)
                }
                // Right: cleaned output (read-only, live)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cleaned").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        if let err = viewModel.previewError {
                            Text(err).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(viewModel.previewOutput ?? "")
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(6)
                    .background(DesignSystem.Colors.surfaceElevated)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Enabled", isOn: Binding(
                get: { viewModel.draft?.enabled ?? true },
                set: { viewModel.draft?.enabled = $0; viewModel.save() }
            ))
            Spacer()
            Button(role: .destructive) { showDeleteConfirm = true } label: { Text("Delete category") }
        }
    }
}

/// Small horizontal wrap of removable chips.
private struct FlowChips: View {
    let items: [String]
    let onRemove: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 4) {
                        Text(item).font(.caption)
                        Button { onRemove(item) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds. (If a `DesignSystem` token name doesn't resolve, fix to the real one — `grep -nE "enum (Spacing|Typography|Colors)" Sources/MacParakeet/Views/Components/DesignSystem.swift`.)

- [ ] **Step 3: Commit**

```bash
git add Sources/MacParakeet/Views/AppProfiles/AppProfilesView.swift
git commit -m "feat(pdx): App Profiles master-detail sidebar + split pane + side-by-side Try-it"
```

---

## Task 5: Vault archive + 7 new notes + Feature Inventory F4

**Files (vault — NOT git):** `🏡 projects/MacParakeet PDX Custom Prompts/` + Feature Inventory.

- [ ] **Step 1: Archive the existing 11 notes**

```bash
VDIR="/Users/jnzn08/Library/Mobile Documents/iCloud~md~obsidian/Documents/notes/🏡 projects/MacParakeet PDX Custom Prompts"
mkdir -p "$VDIR/Archive"
# Move every existing per-app note (everything except _index.md and the Archive dir) into Archive/
find "$VDIR" -maxdepth 1 -name '*.md' ! -name '_index.md' -exec mv {} "$VDIR/Archive/" \;
ls "$VDIR/Archive/" | wc -l   # expect 11
```

- [ ] **Step 2: Generate 7 new category notes + update index**

Reuse the generator approach from the original feature (one note per profile, app + bundle IDs + full prompt in a fenced block), reading the regenerated `seeds/app-profiles.local.json` (7 categories) and writing into `$VDIR` (not Archive). Update `_index.md` to: list the 7 categories, and add a line linking `Archive/` ("Original 11 per-app prompts, superseded by the 7 categories on 2026-05-31"). (See `/tmp/gen_prompt_notes.py` from the prior task as the template; point its `VAULT` at `$VDIR` and its `SEED` at the regenerated file.)

- [ ] **Step 3: Update Feature Inventory F4**

In `🏡 projects/MacParakeet PDX Edition - Feature Inventory.md`, update the **F4** row to note the **7-category model** (was 11) + the **master-detail + split layout** + the **seed-version re-seed (v2)**, and link both `MacParakeet PDX Custom Prompts/_index` and its `Archive/`. Reference design `docs/superpowers/specs/2026-05-31-app-profiles-category-layout-redesign.md`.

- [ ] **Step 4: Confirm no real prompt text leaked into the repo**

Run: `git -C /Users/jnzn08/Developer/macparakeet grep -n "{{TRANSCRIPT}}" -- Sources/ | grep -iv sample`
Expected: only the 3 generic samples in `AppProfile.defaults` (no category/real prompt text committed).

---

## Self-Review

**Spec coverage:** category model 11→7 (T1), layout master-detail + 15/42/42 + side-by-side Try-it (T4), seed-version re-seed (T2) + startup wiring (T3), vault archive + 7 notes + F4 (T5). All spec sections covered.

**Placeholder scan:** logic + view code is complete; T5 step 2 references the prior `/tmp/gen_prompt_notes.py` template (its full code exists from the original feature) rather than re-pasting it — acceptable since it's a dev/doc script, not shipped code. T3 grep-confirms the real call-site variable names.

**Type consistency:** `AppProfileSeeder.{currentSeedVersion, seedVersionDefaultsKey, seedIfEmpty(repository:bundledSeedURL:defaults:), reseedIfVersionOutdated(repository:bundledSeedURL:defaults:)}`; view reuses the existing `AppProfilesViewModel` API verbatim (no new VM methods). Category ids `cat-*` consistent between T1 and the vault/seed.
