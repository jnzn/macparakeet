import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TranscriptionDateGroupingTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h
        return calendar.date(from: comps)!
    }

    // MARK: - Bucket logic

    func testTodayBucket() {
        let now = date(2026, 4, 28, 15)
        let bucket = TranscriptionDateGroup.bucket(for: date(2026, 4, 28, 9), now: now, calendar: calendar)
        XCTAssertEqual(bucket, .today)
    }

    func testYesterdayBucket() {
        let now = date(2026, 4, 28, 15)
        let bucket = TranscriptionDateGroup.bucket(for: date(2026, 4, 27, 22), now: now, calendar: calendar)
        XCTAssertEqual(bucket, .yesterday)
    }

    func testPrevious7DaysBucket() {
        let now = date(2026, 4, 28, 15)
        let bucket = TranscriptionDateGroup.bucket(for: date(2026, 4, 24, 10), now: now, calendar: calendar)
        XCTAssertEqual(bucket, .previous7Days)
    }

    func testPrevious30DaysBucket() {
        let now = date(2026, 4, 28, 15)
        let bucket = TranscriptionDateGroup.bucket(for: date(2026, 4, 10, 10), now: now, calendar: calendar)
        XCTAssertEqual(bucket, .previous30Days)
    }

    func testMonthBucketForOlderEntries() {
        let now = date(2026, 4, 28, 15)
        let bucket = TranscriptionDateGroup.bucket(for: date(2026, 1, 12, 10), now: now, calendar: calendar)
        XCTAssertEqual(bucket, .month(year: 2026, month: 1))
    }

    func testCrossYearMonthBucket() {
        let now = date(2026, 1, 5, 15)
        let bucket = TranscriptionDateGroup.bucket(for: date(2025, 12, 4, 10), now: now, calendar: calendar)
        XCTAssertEqual(bucket, .month(year: 2025, month: 12))
    }

    // MARK: - View model integration

    func testViewModelGroupsAcrossDateBuckets() throws {
        let manager = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let now = date(2026, 4, 28, 15)
        let vm = TranscriptionLibraryViewModel()
        vm.configure(transcriptionRepo: repo)
        vm.calendar = calendar
        vm.nowProvider = { now }

        try repo.save(Transcription(createdAt: date(2026, 4, 28, 10), fileName: "today.m4a", status: .completed))
        try repo.save(Transcription(createdAt: date(2026, 4, 27, 10), fileName: "yesterday.m4a", status: .completed))
        try repo.save(Transcription(createdAt: date(2026, 4, 25, 10), fileName: "earlier_week.m4a", status: .completed))
        try repo.save(Transcription(createdAt: date(2026, 4, 10, 10), fileName: "earlier_month.m4a", status: .completed))
        try repo.save(Transcription(createdAt: date(2026, 1, 12, 10), fileName: "january.m4a", status: .completed))

        vm.loadTranscriptions()

        let groups = vm.groupedTranscriptions.map(\.group)
        XCTAssertEqual(groups, [
            .today,
            .yesterday,
            .previous7Days,
            .previous30Days,
            .month(year: 2026, month: 1),
        ])
        XCTAssertEqual(vm.groupedTranscriptions.map { $0.items.count }, [1, 1, 1, 1, 1])
    }

    func testEmptyGroupsAreOmitted() throws {
        let manager = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let now = date(2026, 4, 28, 15)
        let vm = TranscriptionLibraryViewModel()
        vm.configure(transcriptionRepo: repo)
        vm.calendar = calendar
        vm.nowProvider = { now }

        try repo.save(Transcription(createdAt: date(2026, 4, 28, 10), fileName: "today.m4a", status: .completed))
        vm.loadTranscriptions()

        XCTAssertEqual(vm.groupedTranscriptions.count, 1)
        XCTAssertEqual(vm.groupedTranscriptions.first?.group, .today)
    }
}
