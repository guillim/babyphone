import XCTest

/// Runs the baby side and the parent side at the same time, in two simulators,
/// and takes them through a whole session: pairing with the six-digit code,
/// connecting over the local network, then commands and journal over the live link.
///
/// The two tests run in separate processes. They pass each other the pairing
/// code and their progress through files in a folder both can see, named by
/// the `NID_SHARED_DIR` environment variable. Without it the tests are skipped.
@MainActor
final class TwoPhoneTests: XCTestCase {
    private let step: TimeInterval = 120

    private func sharedFolder() throws -> URL {
        let path = ProcessInfo.processInfo.environment["NID_SHARED_DIR"]
        try XCTSkipIf(path == nil, "Needs two simulators and a shared folder. See the CI workflow.")
        return URL(fileURLWithPath: path ?? "")
    }

    private func launch(state: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        app.launchEnvironment["NID_UI_TEST_STATE"] = state
        app.launch()
        return app
    }

    private func allowSystemAlertIfAny() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
        }
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for the other side to write `name`, and returns its content.
    private func waitForFile(_ name: String, in folder: URL) -> String? {
        let url = folder.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(step)
        while Date() < deadline {
            if let content = try? String(contentsOf: url, encoding: .utf8) { return content }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    func testBabySide() throws {
        let folder = try sharedFolder()
        let app = launch(state: "baby")

        // Pairing: show the code and let the parent side read it.
        let code = app.staticTexts["pairing.code"]
        XCTAssertTrue(code.waitForExistence(timeout: step))
        try String(code.label.filter(\.isNumber)).write(
            to: folder.appendingPathComponent("code"), atomically: true, encoding: .utf8
        )

        // Paired: the pairing screen gives way to the monitor.
        let start = app.buttons["baby.start"]
        XCTAssertTrue(start.waitForExistence(timeout: step), "The parent side never completed pairing")
        start.tap()
        allowSystemAlertIfAny()
        allowSystemAlertIfAny()
        XCTAssertTrue(app.buttons["baby.stop"].waitForExistence(timeout: step), "Monitoring did not start")

        // Connected: the parent unit found this phone and the direct link is up.
        XCTAssertTrue(app.staticTexts["baby.parentConnected"].waitForExistence(timeout: step), "The parent unit never connected")
        app.tap()
        attachScreenshot(named: "baby-connected")

        // Stay up while the parent side runs its checks, then stop on purpose.
        XCTAssertNotNil(waitForFile("parent-done", in: folder), "The parent side did not finish")
        attachScreenshot(named: "baby-after-commands")
        app.tap()
        app.swipeUp()
        app.buttons["baby.stop"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: step))
        try "stopped".write(to: folder.appendingPathComponent("baby-stopped"), atomically: true, encoding: .utf8)
    }

    func testParentSide() throws {
        let folder = try sharedFolder()
        let app = launch(state: "parent")
        allowSystemAlertIfAny()

        // Pairing: type the code shown on the baby side.
        let field = app.textFields["pairing.codeField"]
        XCTAssertTrue(field.waitForExistence(timeout: step))
        let code = try XCTUnwrap(waitForFile("code", in: folder), "The baby side never showed a code")
        field.tap()
        field.typeText(code)
        app.buttons["pairing.submit"].tap()

        // Paired: the monitor appears and looks for the baby unit by itself.
        let talk = app.buttons["parent.talk"]
        XCTAssertTrue(talk.waitForExistence(timeout: step), "Pairing failed")
        allowSystemAlertIfAny()
        allowSystemAlertIfAny()

        // Live: the direct link is up and the baby unit reports its status.
        let live = app.descendants(matching: .any)["parent.live"]
        XCTAssertTrue(live.waitForExistence(timeout: step * 2), "The live link never came up")
        attachScreenshot(named: "parent-live")

        // Commands travel to the baby unit, and its new state travels back.
        let nightLight = app.buttons["parent.nightLight"], lullaby = app.buttons["parent.lullaby"]
        XCTAssertFalse(nightLight.isSelected)
        nightLight.tap()
        XCTAssertTrue(waitUntil(30) { nightLight.isSelected }, "The night light command had no effect")
        lullaby.tap()
        XCTAssertTrue(waitUntil(30) { lullaby.isSelected }, "The lullaby command had no effect")
        attachScreenshot(named: "parent-commands")
        nightLight.tap()
        lullaby.tap()
        XCTAssertTrue(waitUntil(30) { !nightLight.isSelected && !lullaby.isSelected })

        // The journal kept by the baby unit reaches this phone.
        app.buttons["parent.journal"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["journal.event.monitoringStarted"].waitForExistence(timeout: 30),
            "The baby unit's journal did not arrive"
        )
        attachScreenshot(named: "parent-journal")
        app.navigationBars.buttons.firstMatch.tap()

        // The baby side stops on purpose: this phone says so, and raises no alarm.
        try "done".write(to: folder.appendingPathComponent("parent-done"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(waitForFile("baby-stopped", in: folder), "The baby side did not stop")
        XCTAssertTrue(waitUntil(60) { !live.exists }, "The live badge stayed after the baby unit stopped")
        attachScreenshot(named: "parent-after-stop")
    }
}
