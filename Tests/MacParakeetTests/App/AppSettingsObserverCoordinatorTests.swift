import XCTest
import MacParakeetCore
@testable import MacParakeet

@MainActor
final class AppSettingsObserverCoordinatorTests: XCTestCase {

    // MARK: - Fixture

    /// Bundles a coordinator with an isolated NotificationCenter and counters
    /// for each callback, so tests don't bleed into `.default` and can assert
    /// per-notification routing without timing races on shared state.
    @MainActor
    private final class Fixture {
        let center = NotificationCenter()
        var onboardingCount = 0
        var settingsCount = 0
        var hotkeyTriggerCount = 0
        var meetingHotkeyTriggerCount = 0
        var menuBarOnlyCount = 0
        var showIdlePillCount = 0

        lazy var coordinator: AppSettingsObserverCoordinator = AppSettingsObserverCoordinator(
            notificationCenter: center,
            onOpenOnboarding: { [unowned self] in self.onboardingCount += 1 },
            onOpenSettings: { [unowned self] in self.settingsCount += 1 },
            onHotkeyTriggerChanged: { [unowned self] in self.hotkeyTriggerCount += 1 },
            onMeetingHotkeyTriggerChanged: { [unowned self] in self.meetingHotkeyTriggerCount += 1 },
            onMenuBarOnlyModeChanged: { [unowned self] in self.menuBarOnlyCount += 1 },
            onShowIdlePillChanged: { [unowned self] in self.showIdlePillCount += 1 }
        )
    }

    /// Observer handlers dispatch via `Task { @MainActor in ... }`, so tests
    /// must yield to let the main actor drain pending work before asserting.
    private func drainMainActor() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    // MARK: - Tests

    func test_startObserving_routesEachNotificationToItsCallback() async {
        let fx = Fixture()
        fx.coordinator.startObserving()

        fx.center.post(name: .macParakeetOpenOnboarding, object: nil)
        fx.center.post(name: .macParakeetOpenSettings, object: nil)
        fx.center.post(name: .macParakeetHotkeyTriggerDidChange, object: nil)
        fx.center.post(name: .macParakeetMeetingHotkeyTriggerDidChange, object: nil)
        fx.center.post(name: .macParakeetMenuBarOnlyModeDidChange, object: nil)
        fx.center.post(name: .macParakeetShowIdlePillDidChange, object: nil)

        await drainMainActor()

        XCTAssertEqual(fx.onboardingCount, 1)
        XCTAssertEqual(fx.settingsCount, 1)
        XCTAssertEqual(fx.hotkeyTriggerCount, 1)
        XCTAssertEqual(fx.meetingHotkeyTriggerCount, 1)
        XCTAssertEqual(fx.menuBarOnlyCount, 1)
        XCTAssertEqual(fx.showIdlePillCount, 1)
    }

    func test_stopObserving_removesAllObservers() async {
        let fx = Fixture()
        fx.coordinator.startObserving()
        fx.coordinator.stopObserving()

        fx.center.post(name: .macParakeetOpenOnboarding, object: nil)
        fx.center.post(name: .macParakeetOpenSettings, object: nil)
        fx.center.post(name: .macParakeetHotkeyTriggerDidChange, object: nil)
        fx.center.post(name: .macParakeetMeetingHotkeyTriggerDidChange, object: nil)
        fx.center.post(name: .macParakeetMenuBarOnlyModeDidChange, object: nil)
        fx.center.post(name: .macParakeetShowIdlePillDidChange, object: nil)

        await drainMainActor()

        XCTAssertEqual(fx.onboardingCount, 0)
        XCTAssertEqual(fx.settingsCount, 0)
        XCTAssertEqual(fx.hotkeyTriggerCount, 0)
        XCTAssertEqual(fx.meetingHotkeyTriggerCount, 0)
        XCTAssertEqual(fx.menuBarOnlyCount, 0)
        XCTAssertEqual(fx.showIdlePillCount, 0)
    }

    func test_startObserving_isIdempotent_doesNotDoubleFire() async {
        // startObserving() defensively calls stopObserving() first. Calling it
        // twice must not leave two observers on the same notification.
        let fx = Fixture()
        fx.coordinator.startObserving()
        fx.coordinator.startObserving()

        fx.center.post(name: .macParakeetHotkeyTriggerDidChange, object: nil)
        await drainMainActor()

        XCTAssertEqual(fx.hotkeyTriggerCount, 1)
    }

    func test_stopObserving_isIdempotent_whenNeverStarted() {
        let fx = Fixture()
        // Calling stop on a fresh coordinator must not crash or throw.
        fx.coordinator.stopObserving()
        fx.coordinator.stopObserving()
    }

    func test_restart_afterStop_reattachesAllObservers() async {
        let fx = Fixture()
        fx.coordinator.startObserving()
        fx.coordinator.stopObserving()
        fx.coordinator.startObserving()

        fx.center.post(name: .macParakeetShowIdlePillDidChange, object: nil)
        fx.center.post(name: .macParakeetMenuBarOnlyModeDidChange, object: nil)
        await drainMainActor()

        XCTAssertEqual(fx.showIdlePillCount, 1)
        XCTAssertEqual(fx.menuBarOnlyCount, 1)
    }

    func test_callbacksAreIsolated_perNotificationName() async {
        // Posting one notification must not fire unrelated callbacks.
        let fx = Fixture()
        fx.coordinator.startObserving()

        fx.center.post(name: .macParakeetOpenOnboarding, object: nil)
        await drainMainActor()

        XCTAssertEqual(fx.onboardingCount, 1)
        XCTAssertEqual(fx.settingsCount, 0)
        XCTAssertEqual(fx.hotkeyTriggerCount, 0)
        XCTAssertEqual(fx.meetingHotkeyTriggerCount, 0)
        XCTAssertEqual(fx.menuBarOnlyCount, 0)
        XCTAssertEqual(fx.showIdlePillCount, 0)
    }
}
