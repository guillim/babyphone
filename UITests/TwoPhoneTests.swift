import XCTest

/// Runs the baby side and the parent side at the same time, in two simulators,
/// and takes them through a whole session: pairing with the six-digit code,
/// connecting over the local network, then commands and journal over the live link.
///
/// The two tests run in separate processes. They pass each other the pairing
/// code and their progress through files in a folder both can see, named by
/// the `NID_SHARED_DIR` environment variable. Without it the tests are skipped.
final class TwoPhoneTests: AppTestCase {
    /// How long one side waits for something on its own screen.
    private let step: TimeInterval = 120
    /// How long one side waits for the other. Two simulators on one build
    /// machine can start many minutes apart.
    private let handover: TimeInterval = 1200

    private func sharedFolder() throws -> URL {
        let path = ProcessInfo.processInfo.environment["NID_SHARED_DIR"]
        try XCTSkipIf(path == nil, "Needs two simulators and a shared folder. See the CI workflow.")
        return URL(fileURLWithPath: path ?? "")
    }

    /// Waits for the other side to write `name`, and returns its content.
    private func waitForFile(_ name: String, in folder: URL) -> String? {
        let url = folder.appendingPathComponent(name)
        var content: String?
        _ = waitUntil(handover) {
            content = try? String(contentsOf: url, encoding: .utf8)
            return content != nil
        }
        return content
    }

    private func write(_ content: String, to name: String, in folder: URL) throws {
        try content.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testBabySide() throws {
        let folder = try sharedFolder()
        let app = launch(state: "baby")

        // Pairing: show the code and let the parent side read it.
        let code = app.staticTexts["pairing.code"]
        XCTAssertTrue(code.waitForExistence(timeout: step))
        try write(String(code.label.filter(\.isNumber)), to: "code", in: folder)

        // Paired: the pairing screen gives way to the monitor.
        let start = app.buttons["baby.start"]
        XCTAssertTrue(start.waitForExistence(timeout: handover), "The parent side never completed pairing")
        start.tap()
        acceptSystemAlerts(within: 8)
        XCTAssertTrue(app.buttons["baby.stop"].waitForExistence(timeout: step), "Monitoring did not start")

        // Connected: the parent unit found this phone and the direct link is up.
        XCTAssertTrue(
            app.staticTexts["baby.parentConnected"].waitForExistence(timeout: handover),
            "The parent unit never connected"
        )
        attachScreenshot(named: "baby-connected")

        // Stay up while the parent side runs its checks, then stop on purpose.
        XCTAssertNotNil(waitForFile("parent-done", in: folder), "The parent side did not finish")
        app.swipeUp()
        attachScreenshot(named: "baby-after-commands")
        app.buttons["baby.stop"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: step))
        try write("stopped", to: "baby-stopped", in: folder)
    }

    func testParentSide() throws {
        let folder = try sharedFolder()
        let app = launch(state: "parent")

        // Pairing: type the code shown on the baby side.
        let field = app.textFields["pairing.codeField"]
        XCTAssertTrue(field.waitForExistence(timeout: step))
        let code = try XCTUnwrap(waitForFile("code", in: folder), "The baby side never showed a code")
        type(code, into: field)
        app.buttons["pairing.submit"].tap()

        // Paired: the monitor appears and looks for the baby unit by itself.
        acceptSystemAlerts(within: 8)
        let live = app.descendants(matching: .any)["parent.live"]
        XCTAssertTrue(
            waitUntil(step) { app.buttons["parent.talk"].exists || app.buttons["failure.retry"].exists },
            "Pairing failed"
        )

        // Live: the direct link is up and the baby unit reports its status.
        XCTAssertTrue(live.waitForExistence(timeout: handover), "The live link never came up")
        attachScreenshot(named: "parent-live")

        // Commands travel to the baby unit, and its new state travels back.
        let nightLight = app.buttons["parent.nightLight"], lullaby = app.buttons["parent.lullaby"]
        XCTAssertFalse(nightLight.isSelected)
        nightLight.tap()
        XCTAssertTrue(waitUntil(60) { nightLight.isSelected }, "The night light command had no effect")
        lullaby.tap()
        XCTAssertTrue(waitUntil(60) { lullaby.isSelected }, "The lullaby command had no effect")
        attachScreenshot(named: "parent-commands")
        nightLight.tap()
        lullaby.tap()
        XCTAssertTrue(waitUntil(60) { !nightLight.isSelected && !lullaby.isSelected })

        // The journal kept by the baby unit reaches this phone.
        app.buttons["parent.journal"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["journal.event.monitoringStarted"].waitForExistence(timeout: 60),
            "The baby unit's journal did not arrive"
        )
        attachScreenshot(named: "parent-journal")
        app.navigationBars.buttons.firstMatch.tap()

        // The baby side stops on purpose: this phone says so, and raises no alarm.
        try write("done", to: "parent-done", in: folder)
        XCTAssertNotNil(waitForFile("baby-stopped", in: folder), "The baby side did not stop")
        XCTAssertTrue(waitUntil(step) { !live.exists }, "The live badge stayed after the baby unit stopped")
        attachScreenshot(named: "parent-after-stop")
    }
}
