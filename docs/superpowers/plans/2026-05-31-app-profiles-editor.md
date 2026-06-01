# App Profiles Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Productize F4 into a DB-backed, sidebar-managed "App Profiles" editor (tab-per-script, add/remove apps, live "Try it" preview), splitting committed generic samples from the user's real prompts (gitignored local seed + vault).

**Architecture:** `AppProfile` becomes a GRDB record persisted in a new `app_profile` table via `AppProfileRepository`. An `AppProfileStore` is the single source of truth with two faces — an `@Observable` array for the editor and a lock-guarded `Sendable` snapshot for the `@Sendable` dictation resolve closure. A first-run `AppProfileSeeder` populates the table from a build-bundled JSON (the user's real prompts, gitignored) or falls back to 3 generic committed samples. The editor is a new main-window sidebar section.

**Tech Stack:** Swift 6, SwiftUI, GRDB (SQLite), `@MainActor @Observable` view models, XCTest. Builds/tests run from `~/Developer/macparakeet`.

---

## File Structure

| File | Responsibility | Create/Modify |
|------|----------------|---------------|
| `Sources/MacParakeetCore/Models/AppProfile.swift` | model + `sortOrder` + Codable/GRDB conformance; 3 generic `defaults` | Modify |
| `Sources/MacParakeetCore/Database/DatabaseManager.swift` | `v0.21-app-profiles` migration | Modify |
| `Sources/MacParakeetCore/Database/AppProfileRepository.swift` | CRUD over `app_profile` | Create |
| `Sources/MacParakeetCore/Services/AppProfileSeeder.swift` | one-time first-run seed (bundled JSON ▸ generics) | Create |
| `Sources/MacParakeetViewModels/AppProfileStore.swift` | dual-face cache (Observable + Sendable snapshot) + write-through CRUD | Create |
| `Sources/MacParakeetViewModels/AppProfilesViewModel.swift` | editor state, CRUD, add/remove app, live preview | Create |
| `Sources/MacParakeet/Views/AppProfiles/AppProfilesView.swift` | sidebar section: tab strip + editor | Create |
| `Sources/MacParakeet/Views/AppProfiles/AppProfileAppPicker.swift` | NSOpenPanel app picker helper | Create |
| `Sources/MacParakeet/Views/MainWindowView.swift` | `appProfiles` sidebar case + wiring | Modify |
| `Sources/MacParakeet/App/AppEnvironment.swift` | build store/seeder/VM; rewire `resolveActiveProfile` | Modify |
| `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift` | one-line pointer to App Profiles | Modify |
| `scripts/dist/build_app_bundle.sh` | bundle `seeds/app-profiles.local.json` | Modify |
| `.gitignore` | ignore `seeds/*.local.json` | Modify |
| `Tests/MacParakeetTests/Models/AppProfileTests.swift` | model + resolve tests | Create |
| `Tests/MacParakeetTests/Database/AppProfileRepositoryTests.swift` | CRUD + JSON round-trip + migration | Create |
| `Tests/MacParakeetTests/Services/AppProfileSeederTests.swift` | seed precedence + idempotency | Create |
| `Tests/MacParakeetTests/ViewModels/AppProfileStoreTests.swift` | dual-face consistency | Create |
| `Tests/MacParakeetTests/ViewModels/AppProfilesViewModelTests.swift` | editor behaviors + preview | Create |

**Conventions:** focused tests via `swift test --filter <Suite>` (the full suite has a known cross-test hang). Build via `swift build`. Commit after each task. SwiftUI views are verified by build only (project policy: test ViewModels, skip view tests).

---

## Task 1: AppProfile model — sortOrder + Codable/GRDB

**Files:**
- Modify: `Sources/MacParakeetCore/Models/AppProfile.swift`
- Test: `Tests/MacParakeetTests/Models/AppProfileTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MacParakeetTests/Models/AppProfileTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

final class AppProfileTests: XCTestCase {
    func testResolveReturnsFirstEnabledMatchBySortOrder() {
        let a = AppProfile(id: "a", displayName: "A", bundleIDs: ["com.x"], promptOverride: "PA", enabled: true, sortOrder: 0)
        let b = AppProfile(id: "b", displayName: "B", bundleIDs: ["com.x"], promptOverride: "PB", enabled: true, sortOrder: 1)
        let resolved = AppProfile.resolve(bundleID: "com.x", from: [a, b])
        XCTAssertEqual(resolved?.id, "a")
    }

    func testResolveSkipsDisabled() {
        let a = AppProfile(id: "a", displayName: "A", bundleIDs: ["com.x"], promptOverride: "PA", enabled: false, sortOrder: 0)
        let b = AppProfile(id: "b", displayName: "B", bundleIDs: ["com.x"], promptOverride: "PB", enabled: true, sortOrder: 1)
        XCTAssertEqual(AppProfile.resolve(bundleID: "com.x", from: [a, b])?.id, "b")
    }

    func testCodableRoundTripPreservesBundleIDs() throws {
        let p = AppProfile(id: "email", displayName: "Email", bundleIDs: ["com.apple.mail", "com.microsoft.Outlook"], promptOverride: "X {{TRANSCRIPT}}", enabled: true, sortOrder: 3)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(AppProfile.self, from: data)
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.bundleIDs, ["com.apple.mail", "com.microsoft.Outlook"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppProfileTests`
Expected: FAIL — `AppProfile` init has no `sortOrder:` argument; `AppProfile` is not `Codable`.

- [ ] **Step 3: Modify the model**

In `Sources/MacParakeetCore/Models/AppProfile.swift`, change the struct declaration and stored properties so editable fields are `var`, add `sortOrder`, conform to `Codable`, and update the init. Replace the struct's property/init block with:

```swift
public struct AppProfile: Equatable, Sendable, Identifiable, Codable {
    public let id: String
    public var displayName: String
    /// Bundle identifiers this profile applies to. First profile with a match wins.
    public var bundleIDs: [String]
    /// Full LLM prompt template (uses `{{TRANSCRIPT}}` placeholder) to use instead
    /// of the user-configured default. Nil falls back to the default formatter prompt.
    public var promptOverride: String?
    public var enabled: Bool
    /// Stable ordering for the editor tab strip and first-match resolution.
    public var sortOrder: Int

    public init(
        id: String,
        displayName: String,
        bundleIDs: [String],
        promptOverride: String?,
        enabled: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIDs = bundleIDs
        self.promptOverride = promptOverride
        self.enabled = enabled
        self.sortOrder = sortOrder
    }
```

Leave the existing `static func resolve(bundleID:from:)` unchanged.

- [ ] **Step 4: Add GRDB conformance**

At the bottom of `AppProfile.swift`, add:

```swift
import GRDB

extension AppProfile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "app_profile"

    public enum Columns: String, ColumnExpression {
        case id, displayName, bundleIDs, promptOverride, enabled, sortOrder
    }
}
```

GRDB maps `bundleIDs: [String]` to a JSON text column via Codable (same as `Prompt.appliesToSources`).

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter AppProfileTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/MacParakeetCore/Models/AppProfile.swift Tests/MacParakeetTests/Models/AppProfileTests.swift
git commit -m "feat(pdx): AppProfile gains sortOrder + Codable/GRDB conformance"
```

---

## Task 2: Migration `v0.21-app-profiles`

**Files:**
- Modify: `Sources/MacParakeetCore/Database/DatabaseManager.swift`
- Test: `Tests/MacParakeetTests/Database/AppProfileRepositoryTests.swift` (migration assertion first)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacParakeetTests/Database/AppProfileRepositoryTests.swift`:

```swift
import XCTest
import GRDB
@testable import MacParakeetCore

final class AppProfileRepositoryTests: XCTestCase {
    private func makeDB() throws -> DatabaseManager {
        try DatabaseManager(path: ":memory:")
    }

    func testMigrationCreatesAppProfileTable() throws {
        let db = try makeDB()
        let exists = try db.dbQueue.read { try $0.tableExists("app_profile") }
        XCTAssertTrue(exists)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppProfileRepositoryTests`
Expected: FAIL — `app_profile` table does not exist.

- [ ] **Step 3: Register the migration**

In `Sources/MacParakeetCore/Database/DatabaseManager.swift`, inside `migrate()`, add a new migration **after** the last registered one (`v0.20-prompt-applies-to-sources`):

```swift
        migrator.registerMigration("v0.21-app-profiles") { db in
            try db.create(table: "app_profile", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("displayName", .text).notNull()
                t.column("bundleIDs", .text).notNull()       // JSON array
                t.column("promptOverride", .text)            // nullable
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppProfileRepositoryTests`
Expected: PASS (`testMigrationCreatesAppProfileTable`).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/Database/DatabaseManager.swift Tests/MacParakeetTests/Database/AppProfileRepositoryTests.swift
git commit -m "feat(pdx): add v0.21-app-profiles migration (app_profile table)"
```

---

## Task 3: AppProfileRepository (CRUD)

**Files:**
- Create: `Sources/MacParakeetCore/Database/AppProfileRepository.swift`
- Test: `Tests/MacParakeetTests/Database/AppProfileRepositoryTests.swift` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `AppProfileRepositoryTests.swift` (inside the class):

```swift
    private func makeRepo(_ db: DatabaseManager) -> AppProfileRepository {
        AppProfileRepository(dbQueue: db.dbQueue)
    }

    func testSaveFetchRoundTripWithBundleIDs() throws {
        let repo = makeRepo(try makeDB())
        let p = AppProfile(id: "email", displayName: "Email", bundleIDs: ["com.apple.mail", "com.microsoft.Outlook"], promptOverride: "X {{TRANSCRIPT}}", enabled: true, sortOrder: 2)
        try repo.save(p)
        let back = try XCTUnwrap(repo.fetch(id: "email"))
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.bundleIDs, ["com.apple.mail", "com.microsoft.Outlook"])
    }

    func testFetchAllOrdersBySortOrder() throws {
        let repo = makeRepo(try makeDB())
        try repo.save(AppProfile(id: "b", displayName: "B", bundleIDs: [], promptOverride: nil, enabled: true, sortOrder: 5))
        try repo.save(AppProfile(id: "a", displayName: "A", bundleIDs: [], promptOverride: nil, enabled: true, sortOrder: 1))
        XCTAssertEqual(try repo.fetchAll().map(\.id), ["a", "b"])
    }

    func testDeleteRemovesRow() throws {
        let repo = makeRepo(try makeDB())
        try repo.save(AppProfile(id: "a", displayName: "A", bundleIDs: [], promptOverride: nil))
        XCTAssertTrue(try repo.delete(id: "a"))
        XCTAssertNil(try repo.fetch(id: "a"))
        XCTAssertFalse(try repo.delete(id: "a"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppProfileRepositoryTests`
Expected: FAIL — `AppProfileRepository` not found.

- [ ] **Step 3: Implement the repository**

Create `Sources/MacParakeetCore/Database/AppProfileRepository.swift`:

```swift
import Foundation
import GRDB

public protocol AppProfileRepositoryProtocol: Sendable {
    func save(_ profile: AppProfile) throws
    func fetch(id: String) throws -> AppProfile?
    func fetchAll() throws -> [AppProfile]
    @discardableResult func delete(id: String) throws -> Bool
}

public final class AppProfileRepository: AppProfileRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ profile: AppProfile) throws {
        try dbQueue.write { db in try profile.save(db) }
    }

    public func fetch(id: String) throws -> AppProfile? {
        try dbQueue.read { db in try AppProfile.fetchOne(db, key: id) }
    }

    public func fetchAll() throws -> [AppProfile] {
        try dbQueue.read { db in
            try AppProfile
                .order(AppProfile.Columns.sortOrder.asc, AppProfile.Columns.displayName.asc)
                .fetchAll(db)
        }
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        try dbQueue.write { db in try AppProfile.deleteOne(db, key: id) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppProfileRepositoryTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/Database/AppProfileRepository.swift Tests/MacParakeetTests/Database/AppProfileRepositoryTests.swift
git commit -m "feat(pdx): AppProfileRepository CRUD over app_profile"
```

---

## Task 4: Genericize committed defaults + extract real prompts to gitignored seed

**Files:**
- Modify: `Sources/MacParakeetCore/Models/AppProfile.swift` (replace `defaults`)
- Create: `seeds/app-profiles.local.json` (gitignored — holds the real prompts)
- Modify: `.gitignore`

- [ ] **Step 1: Capture the current real profiles to the gitignored seed (before genericizing)**

Run this to serialize the current 13 hardcoded profiles to JSON (a tiny throwaway exec target is overkill — instead extract by hand or via a one-off script). Use this one-off script:

```bash
mkdir -p seeds
cat > /tmp/extract_profiles.swift <<'SWIFT'
import Foundation
@testable import MacParakeetCore
let withOrder = AppProfile.defaults.enumerated().map { i, p in
    AppProfile(id: p.id, displayName: p.displayName, bundleIDs: p.bundleIDs, promptOverride: p.promptOverride, enabled: p.enabled, sortOrder: i)
}
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try! enc.encode(withOrder))
SWIFT
swift run --package-path . 2>/dev/null || true
```

If a throwaway runner is inconvenient, instead add a temporary `XCTest` that encodes `AppProfile.defaults` (with `sortOrder` set to the array index) and writes to `seeds/app-profiles.local.json`, run it once with `swift test --filter <thatTest>`, then delete the test. Either way the result is:

`seeds/app-profiles.local.json` = a JSON array of the current 13 profiles, each with `sortOrder` = its index. Verify:

```bash
test -s seeds/app-profiles.local.json && echo "OK $(wc -c < seeds/app-profiles.local.json) bytes"
```
Expected: a non-empty file (several KB).

- [ ] **Step 2: Gitignore the local seed**

Add to `.gitignore`:

```
# Local-only profile seed (user's real per-app prompts; bundled at build, never committed)
seeds/*.local.json
```

Verify it's ignored: `git check-ignore seeds/app-profiles.local.json` → prints the path.

- [ ] **Step 3: Replace `AppProfile.defaults` with 3 generic samples**

In `AppProfile.swift`, replace the entire `extension AppProfile { public static let defaults: [AppProfile] = [ ... ] }` block with:

```swift
extension AppProfile {
    /// Generic, non-personal starter samples shipped in the public repo. The
    /// user's real per-app prompts are seeded from a gitignored local file
    /// bundled at build time (see AppProfileSeeder); these are the fallback.
    public static let defaults: [AppProfile] = [
        AppProfile(
            id: "sample-email",
            displayName: "Email",
            bundleIDs: ["com.apple.mail", "com.microsoft.Outlook"],
            promptOverride: """
                Clean up ASR-transcribed speech for a business email. Output ONLY the corrected text — no preamble, no markdown. Split into sentences, capitalize correctly, fix obvious homophones, remove filler words, and write spoken numbers as digits. Preserve the speaker's wording and intent.

                Input: {{TRANSCRIPT}}
                """,
            enabled: true,
            sortOrder: 0
        ),
        AppProfile(
            id: "sample-notes",
            displayName: "Notes",
            bundleIDs: ["md.obsidian", "com.apple.Notes"],
            promptOverride: """
                Clean up ASR-transcribed speech for a personal note. Output ONLY the corrected text. Light touch: fix obvious errors and capitalization; keep short fragments and bullet-style phrasing. Preserve wording and intent.

                Input: {{TRANSCRIPT}}
                """,
            enabled: true,
            sortOrder: 1
        ),
        AppProfile(
            id: "sample-chat",
            displayName: "Chat",
            bundleIDs: ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS"],
            promptOverride: """
                Clean up ASR-transcribed speech for a casual chat message. Output ONLY the corrected text. Keep it conversational; fix obvious errors only. Preserve wording and intent.

                Input: {{TRANSCRIPT}}
                """,
            enabled: true,
            sortOrder: 2
        ),
    ]
}
```

- [ ] **Step 4: Build + run model tests**

Run: `swift build && swift test --filter AppProfileTests`
Expected: build succeeds; tests pass.

- [ ] **Step 5: Confirm no real prompt text remains staged**

Run: `git status --short seeds/ ; git grep -n "business email" -- Sources/ | head`
Expected: `seeds/app-profiles.local.json` is **untracked/ignored** (not staged); the only "business email" hit in `Sources/` is the bland generic sample.

- [ ] **Step 6: Commit (generic samples + gitignore only — NOT the seed)**

```bash
git add Sources/MacParakeetCore/Models/AppProfile.swift .gitignore
git commit -m "feat(pdx): genericize committed AppProfile.defaults; gitignore local seed"
```

---

## Task 5: AppProfileSeeder (first-run seed)

**Files:**
- Create: `Sources/MacParakeetCore/Services/AppProfileSeeder.swift`
- Test: `Tests/MacParakeetTests/Services/AppProfileSeederTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MacParakeetTests/Services/AppProfileSeederTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

final class AppProfileSeederTests: XCTestCase {
    private func makeRepo() throws -> AppProfileRepository {
        AppProfileRepository(dbQueue: try DatabaseManager(path: ":memory:").dbQueue)
    }

    func testSeedsGenericDefaultsWhenNoBundledFile() throws {
        let repo = try makeRepo()
        try AppProfileSeeder.seedIfEmpty(repository: repo, bundledSeedURL: nil)
        XCTAssertEqual(try repo.fetchAll().map(\.id), AppProfile.defaults.map(\.id))
    }

    func testSeedsFromBundledFileWhenPresent() throws {
        let repo = try makeRepo()
        let custom = [AppProfile(id: "real-email", displayName: "My Email", bundleIDs: ["com.apple.mail"], promptOverride: "REAL {{TRANSCRIPT}}", enabled: true, sortOrder: 0)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID()).json")
        try JSONEncoder().encode(custom).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try AppProfileSeeder.seedIfEmpty(repository: repo, bundledSeedURL: url)
        XCTAssertEqual(try repo.fetchAll().map(\.id), ["real-email"])
    }

    func testNoOpWhenAlreadyPopulated() throws {
        let repo = try makeRepo()
        try repo.save(AppProfile(id: "existing", displayName: "X", bundleIDs: [], promptOverride: nil))
        try AppProfileSeeder.seedIfEmpty(repository: repo, bundledSeedURL: nil)
        XCTAssertEqual(try repo.fetchAll().map(\.id), ["existing"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppProfileSeederTests`
Expected: FAIL — `AppProfileSeeder` not found.

- [ ] **Step 3: Implement the seeder**

Create `Sources/MacParakeetCore/Services/AppProfileSeeder.swift`:

```swift
import Foundation

/// One-time first-run seeding of the `app_profile` table.
///
/// Precedence: a build-bundled local seed (the user's real prompts, gitignored
/// in-repo and copied into Resources/ProfileSeeds at build time) wins; otherwise
/// the generic `AppProfile.defaults` shipped in the repo are used. No-op once the
/// table has any rows, so user edits are never clobbered.
public enum AppProfileSeeder {
    /// URL of the bundled seed inside the app, or nil. Computed by the app layer:
    /// `Bundle.main.url(forResource: "app-profiles", withExtension: "json", subdirectory: "ProfileSeeds")`.
    public static func seedIfEmpty(
        repository: AppProfileRepositoryProtocol,
        bundledSeedURL: URL?
    ) throws {
        guard try repository.fetchAll().isEmpty else { return }

        let seeds: [AppProfile]
        if let url = bundledSeedURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([AppProfile].self, from: data),
           !decoded.isEmpty {
            seeds = decoded
        } else {
            seeds = AppProfile.defaults
        }

        for profile in seeds {
            try repository.save(profile)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppProfileSeederTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/Services/AppProfileSeeder.swift Tests/MacParakeetTests/Services/AppProfileSeederTests.swift
git commit -m "feat(pdx): AppProfileSeeder first-run seed (bundled JSON > generics)"
```

---

## Task 6: AppProfileStore (dual-face cache)

**Files:**
- Create: `Sources/MacParakeetViewModels/AppProfileStore.swift`
- Test: `Tests/MacParakeetTests/ViewModels/AppProfileStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MacParakeetTests/ViewModels/AppProfileStoreTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class AppProfileStoreTests: XCTestCase {
    private func makeStore() throws -> AppProfileStore {
        let repo = AppProfileRepository(dbQueue: try DatabaseManager(path: ":memory:").dbQueue)
        try repo.save(AppProfile(id: "a", displayName: "A", bundleIDs: ["com.x"], promptOverride: "PA", enabled: true, sortOrder: 0))
        let store = AppProfileStore(repository: repo)
        store.load()
        return store
    }

    func testLoadPopulatesBothFaces() throws {
        let store = try makeStore()
        XCTAssertEqual(store.profiles.map(\.id), ["a"])
        XCTAssertEqual(store.snapshot.resolve(bundleID: "com.x")?.id, "a")
    }

    func testUpsertUpdatesObservableAndSnapshot() throws {
        let store = try makeStore()
        store.upsert(AppProfile(id: "b", displayName: "B", bundleIDs: ["com.y"], promptOverride: "PB", enabled: true, sortOrder: 1))
        XCTAssertEqual(store.profiles.map(\.id), ["a", "b"])
        XCTAssertEqual(store.snapshot.resolve(bundleID: "com.y")?.id, "b")
    }

    func testDeleteUpdatesBothFaces() throws {
        let store = try makeStore()
        store.delete(id: "a")
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.snapshot.resolve(bundleID: "com.x"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppProfileStoreTests`
Expected: FAIL — `AppProfileStore` not found.

- [ ] **Step 3: Implement the store + snapshot**

Create `Sources/MacParakeetViewModels/AppProfileStore.swift`:

```swift
import Foundation
import os
import MacParakeetCore

/// Thread-safe snapshot of the resolved profile list for the `@Sendable`
/// dictation resolve closure (which runs off the main actor).
public final class AppProfileSnapshot: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [AppProfile]())

    func set(_ profiles: [AppProfile]) {
        lock.withLock { $0 = profiles }
    }

    public func resolve(bundleID: String?) -> AppProfile? {
        lock.withLock { AppProfile.resolve(bundleID: bundleID, from: $0) }
    }
}

/// Single source of truth for per-app profiles. The `@Observable` `profiles`
/// array drives the editor; `snapshot` feeds dictation resolution. Every
/// write-through CRUD op updates both atomically.
@MainActor
@Observable
public final class AppProfileStore {
    public private(set) var profiles: [AppProfile] = []
    public let snapshot = AppProfileSnapshot()

    private let repository: AppProfileRepositoryProtocol

    public init(repository: AppProfileRepositoryProtocol) {
        self.repository = repository
    }

    public func load() {
        do {
            profiles = try repository.fetchAll()
        } catch {
            profiles = []
        }
        snapshot.set(profiles)
    }

    /// Insert or update, then re-sort by sortOrder and refresh both faces.
    public func upsert(_ profile: AppProfile) {
        try? repository.save(profile)
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { ($0.sortOrder, $0.displayName) < ($1.sortOrder, $1.displayName) }
        snapshot.set(profiles)
    }

    public func delete(id: String) {
        try? repository.delete(id: id)
        profiles.removeAll { $0.id == id }
        snapshot.set(profiles)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppProfileStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetViewModels/AppProfileStore.swift Tests/MacParakeetTests/ViewModels/AppProfileStoreTests.swift
git commit -m "feat(pdx): AppProfileStore dual-face cache (Observable + Sendable snapshot)"
```

---

## Task 7: Wire store + seeder into AppEnvironment; rewire resolveActiveProfile

**Files:**
- Modify: `Sources/MacParakeet/App/AppEnvironment.swift`

This task has no unit test (app composition); verified by build + the existing dictation tests still passing.

- [ ] **Step 1: Build the repository, store, and seed at startup**

In `AppEnvironment.swift`, where other repositories/services are constructed (near the `DatabaseManager`/repository setup), add:

```swift
        let appProfileRepository = AppProfileRepository(dbQueue: databaseManager.dbQueue)
        let bundledProfileSeedURL = Bundle.main.url(
            forResource: "app-profiles", withExtension: "json", subdirectory: "ProfileSeeds"
        )
        try? AppProfileSeeder.seedIfEmpty(repository: appProfileRepository, bundledSeedURL: bundledProfileSeedURL)
        let appProfileStore = AppProfileStore(repository: appProfileRepository)
        appProfileStore.load()
```

(Use the actual local name of the `DatabaseManager` instance in this file — search for `dbQueue` usage to confirm. Run `grep -n "dbQueue" Sources/MacParakeet/App/AppEnvironment.swift` first.)

- [ ] **Step 2: Rewire `resolveActiveProfile`**

Replace the existing closure (currently `AppProfile.resolve(bundleID: AppContextService.frontmostBundleID())`):

```swift
            resolveActiveProfile: { [snapshot = appProfileStore.snapshot] in
                snapshot.resolve(bundleID: AppContextService.frontmostBundleID())
            },
```

- [ ] **Step 3: Expose the store for the view layer**

Store `appProfileStore` on the environment so `MainWindowView` can pass it to the editor (mirror how `vocabularyBackupViewModel` etc. are exposed — add a stored `let appProfileStore: AppProfileStore` to the environment/holder type and assign it). Confirm the exact holder by `grep -n "vocabularyBackupViewModel" Sources/MacParakeet/App/AppEnvironment.swift`.

- [ ] **Step 4: Build + run dictation tests**

Run: `swift build && swift test --filter DictationServiceTests`
Expected: build succeeds; existing dictation tests pass (resolution behavior unchanged when a profile matches).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeet/App/AppEnvironment.swift
git commit -m "feat(pdx): resolve per-app profile from AppProfileStore snapshot; seed on launch"
```

---

## Task 8: AppProfilesViewModel (editor logic + live preview)

**Files:**
- Create: `Sources/MacParakeetViewModels/AppProfilesViewModel.swift`
- Test: `Tests/MacParakeetTests/ViewModels/AppProfilesViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MacParakeetTests/ViewModels/AppProfilesViewModelTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class AppProfilesViewModelTests: XCTestCase {
    private func makeVM(preview: @escaping @Sendable (String, String) async throws -> String = { _, _ in "OUT" }) throws -> AppProfilesViewModel {
        let repo = AppProfileRepository(dbQueue: try DatabaseManager(path: ":memory:").dbQueue)
        try repo.save(AppProfile(id: "a", displayName: "A", bundleIDs: ["com.x"], promptOverride: "PA {{TRANSCRIPT}}", enabled: true, sortOrder: 0))
        let store = AppProfileStore(repository: repo)
        store.load()
        return AppProfilesViewModel(store: store, runPreview: preview)
    }

    func testNewScriptAddsAndSelects() throws {
        let vm = try makeVM()
        vm.newScript()
        XCTAssertEqual(vm.store.profiles.count, 2)
        XCTAssertEqual(vm.selectedID, vm.store.profiles.last?.id)
    }

    func testAddAndRemoveApp() throws {
        let vm = try makeVM()
        vm.select(id: "a")
        vm.addApp(bundleID: "com.y")
        XCTAssertEqual(vm.draft?.bundleIDs, ["com.x", "com.y"])
        vm.removeApp(bundleID: "com.x")
        XCTAssertEqual(vm.draft?.bundleIDs, ["com.y"])
    }

    func testAddDuplicateAppIsIgnored() throws {
        let vm = try makeVM()
        vm.select(id: "a")
        vm.addApp(bundleID: "com.x")
        XCTAssertEqual(vm.draft?.bundleIDs, ["com.x"])
    }

    func testSavePersistsDraftToStore() throws {
        let vm = try makeVM()
        vm.select(id: "a")
        vm.draft?.displayName = "Renamed"
        vm.save()
        XCTAssertEqual(vm.store.profiles.first(where: { $0.id == "a" })?.displayName, "Renamed")
    }

    func testDeleteSelectedRemovesFromStore() throws {
        let vm = try makeVM()
        vm.select(id: "a")
        vm.deleteSelected()
        XCTAssertTrue(vm.store.profiles.isEmpty)
        XCTAssertNil(vm.selectedID)
    }

    func testRunPreviewSetsOutput() async throws {
        let vm = try makeVM(preview: { _, _ in "Hi — can you send me the deck?" })
        vm.select(id: "a")
        await vm.runPreview(sample: "hey can u send me the deck")
        XCTAssertEqual(vm.previewOutput, "Hi — can you send me the deck?")
        XCTAssertNil(vm.previewError)
    }

    func testRunPreviewSurfacesError() async throws {
        struct Boom: Error {}
        let vm = try makeVM(preview: { _, _ in throw Boom() })
        vm.select(id: "a")
        await vm.runPreview(sample: "x")
        XCTAssertNil(vm.previewOutput)
        XCTAssertNotNil(vm.previewError)
    }

    func testDuplicateBundleWarningAcrossScripts() throws {
        let vm = try makeVM()
        vm.newScript()                              // selects the new empty script
        vm.addApp(bundleID: "com.x")                // already owned by "a"
        XCTAssertTrue(vm.duplicateBundleIDs.contains("com.x"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppProfilesViewModelTests`
Expected: FAIL — `AppProfilesViewModel` not found.

- [ ] **Step 3: Implement the view model**

Create `Sources/MacParakeetViewModels/AppProfilesViewModel.swift`:

```swift
import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class AppProfilesViewModel {
    public let store: AppProfileStore

    /// Currently selected script id (tab). Nil when there are no scripts.
    public private(set) var selectedID: String?
    /// Editable working copy of the selected script. Bind editor fields to this.
    public var draft: AppProfile?

    public var previewInput: String = ""
    public private(set) var previewOutput: String?
    public private(set) var previewError: String?
    public private(set) var isPreviewing: Bool = false

    /// Injected so tests can stub the LLM. App passes a closure that calls
    /// `LLMService.formatTranscript`. Args: (sampleTranscript, promptTemplate).
    private let runPreviewClosure: @Sendable (String, String) async throws -> String

    public init(
        store: AppProfileStore,
        runPreview: @escaping @Sendable (String, String) async throws -> String
    ) {
        self.store = store
        self.runPreviewClosure = runPreview
        self.selectedID = store.profiles.first?.id
        self.draft = store.profiles.first
    }

    public func select(id: String) {
        selectedID = id
        draft = store.profiles.first { $0.id == id }
        previewOutput = nil
        previewError = nil
    }

    public func newScript() {
        let nextOrder = (store.profiles.map(\.sortOrder).max() ?? -1) + 1
        let new = AppProfile(
            id: "script-\(UUID().uuidString.prefix(8))",
            displayName: "New Script",
            bundleIDs: [],
            promptOverride: "Clean up ASR-transcribed speech. Output ONLY the corrected text.\n\nInput: {{TRANSCRIPT}}",
            enabled: true,
            sortOrder: nextOrder
        )
        store.upsert(new)
        select(id: new.id)
    }

    public func addApp(bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, var d = draft, !d.bundleIDs.contains(id) else { return }
        d.bundleIDs.append(id)
        draft = d
    }

    public func removeApp(bundleID: String) {
        draft?.bundleIDs.removeAll { $0 == bundleID }
    }

    public func save() {
        guard let d = draft else { return }
        store.upsert(d)
    }

    public func deleteSelected() {
        guard let id = selectedID else { return }
        store.delete(id: id)
        selectedID = store.profiles.first?.id
        draft = store.profiles.first
    }

    /// Bundle IDs in the draft that also appear in another script (resolution is
    /// first-match-by-sortOrder, so the earlier script wins). Drives the warning.
    public var duplicateBundleIDs: Set<String> {
        guard let d = draft else { return [] }
        let others = store.profiles.filter { $0.id != d.id }.flatMap(\.bundleIDs)
        return Set(d.bundleIDs).intersection(others)
    }

    public func runPreview(sample: String) async {
        guard let template = draft?.promptOverride, !template.isEmpty else {
            previewError = "Add a prompt to test."
            return
        }
        isPreviewing = true
        previewError = nil
        previewOutput = nil
        defer { isPreviewing = false }
        do {
            previewOutput = try await runPreviewClosure(sample, template)
        } catch {
            previewError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppProfilesViewModelTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetViewModels/AppProfilesViewModel.swift Tests/MacParakeetTests/ViewModels/AppProfilesViewModelTests.swift
git commit -m "feat(pdx): AppProfilesViewModel — editor logic, CRUD, live preview"
```

---

## Task 9: AppProfilesView (sidebar section UI)

**Files:**
- Create: `Sources/MacParakeet/Views/AppProfiles/AppProfilesView.swift`
- Create: `Sources/MacParakeet/Views/AppProfiles/AppProfileAppPicker.swift`

No unit test (SwiftUI view — project policy tests ViewModels, not views). Verified by build.

- [ ] **Step 1: App-picker helper**

Create `Sources/MacParakeet/Views/AppProfiles/AppProfileAppPicker.swift`:

```swift
import AppKit
import UniformTypeIdentifiers

/// Opens an NSOpenPanel rooted at /Applications and returns the chosen app's
/// CFBundleIdentifier, or nil if cancelled / unreadable.
enum AppProfileAppPicker {
    static func pickBundleID() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
```

- [ ] **Step 2: The editor view**

Create `Sources/MacParakeet/Views/AppProfiles/AppProfilesView.swift`:

```swift
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct AppProfilesView: View {
    @Bindable var viewModel: AppProfilesViewModel
    @State private var manualBundleID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            Divider()
            if viewModel.draft != nil {
                editor
            } else {
                emptyState
            }
            Spacer()
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("App Profiles")
    }

    // Scrollable tab strip, one pill per script, + New.
    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.store.profiles) { profile in
                    Button {
                        viewModel.select(id: profile.id)
                    } label: {
                        Text(profile.displayName.isEmpty ? "Untitled" : profile.displayName)
                            .font(DesignSystem.Typography.bodySmall.weight(.medium))
                            .opacity(profile.enabled ? 1 : 0.5)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(
                                Capsule().fill(profile.id == viewModel.selectedID
                                    ? DesignSystem.Colors.surfaceElevated
                                    : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    viewModel.newScript()
                } label: {
                    Label("New script", systemImage: "plus")
                        .font(DesignSystem.Typography.bodySmall)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        Text("No scripts yet. Add one with “New script.”")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var editor: some View {
        if let draftBinding = Binding($viewModel.draft) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                TextField("Script name", text: draftBinding.displayName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: viewModel.draft?.displayName) { _, _ in viewModel.save() }

                appsRow(draftBinding)

                Text("Prompt")
                    .font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
                TextEditor(text: draftBinding.promptOverride.replacingNil(with: ""))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .border(DesignSystem.Colors.border)
                    .onChange(of: viewModel.draft?.promptOverride) { _, _ in viewModel.save() }
                if !(viewModel.draft?.promptOverride?.contains("{{TRANSCRIPT}}") ?? false) {
                    Text("Tip: include {{TRANSCRIPT}} where the dictated text goes.")
                        .font(.caption).foregroundStyle(.orange)
                }

                tryItBox

                HStack {
                    Toggle("Enabled", isOn: draftBinding.enabled)
                        .onChange(of: viewModel.draft?.enabled) { _, _ in viewModel.save() }
                    Spacer()
                    Button(role: .destructive) {
                        viewModel.deleteSelected()
                    } label: { Text("Delete script") }
                }
            }
        }
    }

    private func appsRow(_ draft: Binding<AppProfile>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Applies to")
                .font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
            FlowChips(items: draft.wrappedValue.bundleIDs) { bundleID in
                viewModel.removeApp(bundleID: bundleID)
                viewModel.save()
            }
            if !viewModel.duplicateBundleIDs.isEmpty {
                Text("⚠︎ Also used by another script: \(viewModel.duplicateBundleIDs.sorted().joined(separator: ", ")). The earlier script wins.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button {
                    if let id = AppProfileAppPicker.pickBundleID() {
                        viewModel.addApp(bundleID: id); viewModel.save()
                    }
                } label: { Label("Add app…", systemImage: "plus.app") }
                TextField("or paste bundle ID (e.g. com.apple.mail)", text: $manualBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.addApp(bundleID: manualBundleID); manualBundleID = ""; viewModel.save()
                    }
            }
        }
    }

    private var tryItBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try it").font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
            HStack {
                TextField("Sample dictation…", text: $viewModel.previewInput)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await viewModel.runPreview(sample: viewModel.previewInput) }
                } label: {
                    if viewModel.isPreviewing { ProgressView().controlSize(.small) }
                    else { Text("Run") }
                }
                .disabled(viewModel.previewInput.isEmpty || viewModel.isPreviewing)
            }
            if let out = viewModel.previewOutput {
                Text(out).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignSystem.Colors.surfaceElevated)
            }
            if let err = viewModel.previewError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
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
                        Button { onRemove(item) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                }
            }
        }
    }
}

private extension Binding where Value == String? {
    func replacingNil(with fallback: String) -> Binding<String> {
        Binding<String>(
            get: { self.wrappedValue ?? fallback },
            set: { self.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds. (If `DesignSystem.Spacing.*`/`Typography.*`/`Colors.*` token names differ, fix to the real names — `grep -n "enum Spacing\|enum Typography\|enum Colors" Sources/MacParakeet/Views/Components/DesignSystem.swift`.)

- [ ] **Step 4: Commit**

```bash
git add Sources/MacParakeet/Views/AppProfiles/
git commit -m "feat(pdx): App Profiles editor view (tab strip, apps, prompt, Try it)"
```

---

## Task 10: Add the sidebar section + wire the view model

**Files:**
- Modify: `Sources/MacParakeet/Views/MainWindowView.swift`
- Modify: `Sources/MacParakeet/App/AppEnvironment.swift` (construct `AppProfilesViewModel`, pass to `MainWindowView`)

- [ ] **Step 1: Add the enum case + icon + grouping**

In `MainWindowView.swift`, add to `SidebarItem`:

```swift
    case appProfiles = "App Profiles"
```

In the `icon` computed property add:

```swift
        case .appProfiles: return "person.crop.rectangle.stack"
```

In `static var primaryItems` add `.appProfiles` next to `.vocabulary` (confirm the exact array literal first with `grep -n "primaryItems" -A6 Sources/MacParakeet/Views/MainWindowView.swift`).

- [ ] **Step 2: Construct the view model in AppEnvironment**

In `AppEnvironment.swift`, after `appProfileStore` is created (Task 7), build the VM with a preview closure that calls the real LLM service:

```swift
        let appProfilesViewModel = AppProfilesViewModel(
            store: appProfileStore,
            runPreview: { [llmService] sample, template in
                try await llmService.formatTranscript(
                    transcript: sample,
                    promptTemplate: template,
                    source: .dictation,
                    defaultPromptUsed: false
                )
            }
        )
```

Expose `appProfilesViewModel` from the environment holder (same place `vocabularyBackupViewModel` is exposed). Confirm `llmService`'s local name with `grep -n "llmService" Sources/MacParakeet/App/AppEnvironment.swift`.

- [ ] **Step 3: Pass it into MainWindowView and add the switch case**

Add a `let appProfilesViewModel: AppProfilesViewModel` stored property to `MainWindowView` (mirror `feedbackViewModel`), pass it at the construction site, then add the switch case alongside `.vocabulary`:

```swift
                    case .appProfiles:
                        AppProfilesView(viewModel: appProfilesViewModel)
```

- [ ] **Step 4: Build + run app**

Run: `swift build`
Expected: build succeeds.
Then: `scripts/dev/run_app.sh` — confirm an "App Profiles" item appears in the sidebar; selecting it shows the tab strip + editor; the 3 generic samples (or your real seed) are listed.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeet/Views/MainWindowView.swift Sources/MacParakeet/App/AppEnvironment.swift
git commit -m "feat(pdx): add App Profiles sidebar section + wire view model"
```

---

## Task 11: Bundle the local seed at build time

**Files:**
- Modify: `scripts/dist/build_app_bundle.sh`

- [ ] **Step 1: Add the bundling block**

In `scripts/dist/build_app_bundle.sh`, after the Silero VAD bundling block (`SILERO_SRC=…`), add:

```bash
# Bundle the local-only per-app profile seed (the user's real prompts) when
# present. Gitignored (seeds/*.local.json), so public/CI builds ship nothing
# here and the app falls back to the 3 generic AppProfile.defaults.
PROFILE_SEED_SRC="$ROOT_DIR/seeds/app-profiles.local.json"
if [[ -f "$PROFILE_SEED_SRC" ]]; then
  mkdir -p "$RESOURCES_DIR/ProfileSeeds"
  cp "$PROFILE_SEED_SRC" "$RESOURCES_DIR/ProfileSeeds/app-profiles.json"
  echo "Bundled app-profile seed: $RESOURCES_DIR/ProfileSeeds/app-profiles.json"
else
  echo "No local app-profile seed ($PROFILE_SEED_SRC); shipping generic samples only."
fi
```

- [ ] **Step 2: Verify the build picks it up**

Run: `VERSION=0.0.0-dev SKIP_BUILD=0 bash scripts/dist/build_app_bundle.sh 2>&1 | grep -i "profile seed"`
Expected: prints "Bundled app-profile seed: …/ProfileSeeds/app-profiles.json" (since the local seed exists on your machine).
Then: `ls "dist/MacParakeet.app/Contents/Resources/ProfileSeeds/"` → `app-profiles.json` present.

(If you only build via the PDX wrapper, it calls this canonical script, so it inherits the block automatically.)

- [ ] **Step 3: Commit**

```bash
git add scripts/dist/build_app_bundle.sh
git commit -m "build(pdx): bundle local app-profile seed when present"
```

---

## Task 12: Settings → AI pointer

**Files:**
- Modify: `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`

- [ ] **Step 1: Add a one-line pointer**

In `LLMSettingsView.swift`, inside `aiFormatterSection` (after the formatter controls), add a static informational row:

```swift
            Text("Per-app dictation scripts live in the App Profiles section (sidebar).")
                .font(.caption)
                .foregroundStyle(.secondary)
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacParakeet/Views/Settings/LLMSettingsView.swift
git commit -m "feat(pdx): point Settings → AI at the App Profiles section"
```

---

## Task 13: Vault documentation + Feature Inventory update

**Files (vault — NOT git):**
- Create folder: `🏡 projects/MacParakeet PDX Custom Prompts/` (under the user's Obsidian notes path)
- One note per real script
- Modify: `🏡 projects/MacParakeet PDX Edition - Feature Inventory.md`

- [ ] **Step 1: Generate one vault note per real script**

From `seeds/app-profiles.local.json`, write one Markdown note per profile into the vault folder
`/Users/jnzn08/Library/Mobile Documents/iCloud~md~obsidian/Documents/notes/🏡 projects/MacParakeet PDX Custom Prompts/`,
named `<displayName>.md`, each containing: display name, the `bundleIDs` list, and the full `promptOverride` in a fenced block. (These are the canonical private copies; the vault is not Git.)

- [ ] **Step 2: Add a folder README/index note**

Create `…/MacParakeet PDX Custom Prompts/_index.md` explaining: these are the real per-app dictation prompts, mirrored by `seeds/app-profiles.local.json` (gitignored) and bundled into the user's build; the repo ships only 3 generic samples.

- [ ] **Step 3: Update the Feature Inventory F4 row**

In the Feature Inventory, update **F4** to note it's now productized (DB-backed editor + App Profiles sidebar section + privacy split) and link to the `MacParakeet PDX Custom Prompts/` folder. Add the `v0.21` migration + new sidebar section to the relevant notes.

- [ ] **Step 4: (No commit — vault is outside the repo.)** Confirm the repo has no real prompt text: `git grep -n "{{TRANSCRIPT}}" -- Sources/ | grep -iv sample` → only generic samples.

---

## Self-Review

**Spec coverage:** persistence (T1–3), seeding/privacy (T4,5,11), resolution rewire (T7), store dual-face (T6), editor UI incl. tab-per-script + multi-app + app picker + live preview (T8,9), sidebar section (T10), Settings pointer (T12), vault docs + F4 (T13), testing (T1,3,5,6,8). All spec sections map to a task.

**Placeholder scan:** every code step contains complete code; UI token names flagged with a `grep` fallback (Task 9 Step 3) since `DesignSystem` token names must be confirmed against the file.

**Type consistency:** `AppProfile(id:displayName:bundleIDs:promptOverride:enabled:sortOrder:)`, `AppProfileRepository.{save,fetch(id:String),fetchAll,delete(id:String)}`, `AppProfileStore.{profiles,snapshot,load,upsert,delete}`, `AppProfileSnapshot.resolve(bundleID:)`, `AppProfilesViewModel.{store,selectedID,draft,select,newScript,addApp,removeApp,save,deleteSelected,duplicateBundleIDs,runPreview,previewInput/Output/Error,isPreviewing}`, `AppProfileSeeder.seedIfEmpty(repository:bundledSeedURL:)` — used consistently across tasks.

**Known confirmations the implementer must do (grep-first, noted inline):** the `DatabaseManager` instance name and `llmService`/`vocabularyBackupViewModel` exposure in `AppEnvironment.swift`; `SidebarItem.primaryItems` literal; `DesignSystem` token names. These are environment-coupling details, not design gaps.
