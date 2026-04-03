import XCTest
@testable import CLI
@testable import MacParakeetCore

final class HistoryCommandTests: XCTestCase {

    // MARK: - Delete Dictation

    func testDeleteDictationRemovesRecord() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)
        let d = Dictation(durationMs: 2000, rawTranscript: "Delete me")
        try repo.save(d)

        XCTAssertNotNil(try repo.fetch(id: d.id))
        _ = try repo.delete(id: d.id)
        XCTAssertNil(try repo.fetch(id: d.id))
    }

    // MARK: - Delete Transcription

    func testDeleteTranscriptionRemovesRecord() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let t = Transcription(fileName: "delete-me.mp3", rawTranscript: "Goodbye", status: .completed)
        try repo.save(t)

        XCTAssertNotNil(try repo.fetch(id: t.id))
        _ = try repo.delete(id: t.id)
        XCTAssertNil(try repo.fetch(id: t.id))
    }

    // MARK: - Favorites

    func testFavoriteAndUnfavoriteTranscription() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let t = Transcription(fileName: "fav-test.mp3", rawTranscript: "Star me", status: .completed)
        try repo.save(t)

        // Initially not favorited
        let initial = try repo.fetch(id: t.id)!
        XCTAssertFalse(initial.isFavorite)

        // Favorite it
        try repo.updateFavorite(id: t.id, isFavorite: true)
        let favorited = try repo.fetch(id: t.id)!
        XCTAssertTrue(favorited.isFavorite)

        // Verify it shows up in favorites list
        let favorites = try repo.fetchFavorites()
        XCTAssertTrue(favorites.contains(where: { $0.id == t.id }))

        // Unfavorite it
        try repo.updateFavorite(id: t.id, isFavorite: false)
        let unfavorited = try repo.fetch(id: t.id)!
        XCTAssertFalse(unfavorited.isFavorite)

        // Verify it's gone from favorites
        let favoritesAfter = try repo.fetchFavorites()
        XCTAssertFalse(favoritesAfter.contains(where: { $0.id == t.id }))
    }

    // MARK: - Search Transcriptions (client-side filter)

    func testSearchTranscriptionsFiltersByFileName() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        let t1 = Transcription(fileName: "meeting-notes.mp3", rawTranscript: "Budget discussion", status: .completed)
        let t2 = Transcription(fileName: "podcast-episode.mp3", rawTranscript: "Tech review", status: .completed)
        try repo.save(t1)
        try repo.save(t2)

        let all = try repo.fetchAll()
        let query = "meeting"
        let results = all.filter { t in
            t.fileName.lowercased().contains(query)
                || (t.rawTranscript?.lowercased().contains(query) ?? false)
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, t1.id)
    }

    func testSearchTranscriptionsFiltersByTranscriptContent() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        let t1 = Transcription(fileName: "file-a.mp3", rawTranscript: "The quick brown fox", status: .completed)
        let t2 = Transcription(fileName: "file-b.mp3", rawTranscript: "Lazy dog sleeps", status: .completed)
        try repo.save(t1)
        try repo.save(t2)

        let all = try repo.fetchAll()
        let query = "fox"
        let results = all.filter { t in
            t.fileName.lowercased().contains(query)
                || (t.rawTranscript?.lowercased().contains(query) ?? false)
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, t1.id)
    }
}
