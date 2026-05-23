import AppKit
import XCTest
@testable import MacParakeet
@testable import MacParakeetViewModels

@MainActor
final class MeetingRecordingPanelControllerTests: XCTestCase {
    func testMeetingPanelDoesNotHideWhenAppDeactivates() {
        let app = NSApplication.shared
        let existingWindows = Set(app.windows.map(ObjectIdentifier.init))
        let viewModel = MeetingRecordingPanelViewModel()
        let controller = MeetingRecordingPanelController(viewModel: viewModel)

        controller.show()
        defer { controller.close() }

        let panel = app.windows.first { window in
            window.title == "Meeting Recording"
                && !existingWindows.contains(ObjectIdentifier(window))
        }

        XCTAssertNotNil(panel)
        XCTAssertFalse(panel?.hidesOnDeactivate ?? true)
    }
}
