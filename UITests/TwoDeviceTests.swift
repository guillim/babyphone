import XCTest

/// Runs a whole session between two devices: this test drives the parent unit in
/// one simulator while a baby unit runs in another.
///
/// The baby unit has no test runner. Started with `NUZZLECAM_TEST_SHARED_DIR`, it
/// monitors by itself and reports its progress through files in that folder, where
/// this test also finds the pairing code. The test gets the same folder through
/// `NUZZLECAM_SHARED_DIR`. Without it the test is skipped. See the CI workflow.
final class TwoDeviceTests: AppTestCase {
    /// How long to wait for something on this screen.
    private let step: TimeInterval = 60
    /// How long to wait for the baby unit, which runs on a simulator that may still be busy starting.
    private let handover: TimeInterval = 150

    private func sharedFolder() throws -> URL {
        let path = ProcessInfo.processInfo.environment["NUZZLECAM_SHARED_DIR"]
        try XCTSkipIf(path == nil, "Needs a baby unit in a second simulator and a shared folder.")
        return URL(fileURLWithPath: path ?? "")
    }

    /// Waits for the baby unit to write `name`, and returns its content.
    private func waitForFile(_ name: String, in folder: URL) -> String? {
        let url = folder.appendingPathComponent(name)
        var content: String?
        _ = waitUntil(handover) {
            content = try? String(contentsOf: url, encoding: .utf8)
            return content != nil
        }
        return content
    }

    func testParentUnitWithALiveBabyUnit() throws {
        let folder = try sharedFolder()
        let app = launch(state: "parent")

        // Pairing: type the code shown on the baby unit.
        let field = app.textFields["pairing.codeField"]
        XCTAssertTrue(field.waitForExistence(timeout: step))
        let code = try XCTUnwrap(waitForFile("code", in: folder), "The baby unit never showed a code")
        type(code, into: field)

        // Paired: both sides move on, and the baby unit starts monitoring.
        XCTAssertTrue(
            waitUntil(step) { app.buttons["parent.talk"].exists || app.buttons["failure.retry"].exists },
            "Pairing failed"
        )
        XCTAssertNotNil(waitForFile("baby-monitoring", in: folder), "The baby unit did not start monitoring")

        // Live: this unit found the baby unit by itself and the direct link is up, as seen from both sides.
        let live = app.descendants(matching: .any)["parent.live"]
        XCTAssertTrue(live.waitForExistence(timeout: handover), "The live link never came up")
        XCTAssertNotNil(waitForFile("baby-connected", in: folder), "The baby unit never saw this parent unit")
        attachScreenshot(named: "parent-live")

        // Every control a parent needs is on screen without scrolling, on the smallest iPhone.
        let controls = [
            "parent.talk", "parent.nightLight", "parent.lullaby", "parent.whiteNoise",
            "parent.settings", "parent.journal",
        ]
        for control in controls {
            XCTAssertTrue(app.buttons[control].isHittable, "\(control) is not reachable")
        }

        // Commands travel to the baby unit, and its new state travels back.
        let nightLight = app.buttons["parent.nightLight"], lullaby = app.buttons["parent.lullaby"]
        let whiteNoise = app.buttons["parent.whiteNoise"]
        XCTAssertFalse(nightLight.isSelected)
        nightLight.tap()
        lullaby.tap()
        // White noise asks for how long before it starts.
        whiteNoise.tap()
        let quarterHour = app.buttons["15 min"]
        XCTAssertTrue(quarterHour.waitForExistence(timeout: step))
        quarterHour.tap()
        XCTAssertTrue(
            waitUntil(step) { nightLight.isSelected && lullaby.isSelected && whiteNoise.isSelected },
            "A command had no effect"
        )
        attachScreenshot(named: "parent-commands")
        for control in [nightLight, lullaby, whiteNoise] {
            control.tap()
        }
        XCTAssertTrue(waitUntil(step) { !nightLight.isSelected && !lullaby.isSelected && !whiteNoise.isSelected })

        // The journal kept by the baby unit reaches this unit.
        app.buttons["parent.journal"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["journal.event.monitoringStarted"].waitForExistence(timeout: step),
            "The baby unit's journal did not arrive"
        )
        attachScreenshot(named: "parent-journal")
        app.buttons["parent.tab.live"].tap()
        XCTAssertTrue(live.waitForExistence(timeout: step), "The live screen did not come back")

        // The baby unit stops on purpose: this unit says so, and raises no alarm.
        try "done".write(to: folder.appendingPathComponent("parent-done"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(waitForFile("baby-stopped", in: folder), "The baby unit did not stop")
        XCTAssertTrue(waitUntil(step) { !live.exists }, "The live badge stayed after the baby unit stopped")
        attachScreenshot(named: "parent-after-stop")
    }
}
