import XCTest

/// Launches the app in a simulator and walks its screens.
///
/// A simulator has no camera, no second phone and no iCloud account, so these
/// tests check what can be checked there: the app starts, every screen shows
/// up, and the controls a parent needs are on screen, without scrolling, on
/// the smallest supported iPhone.
@MainActor
final class SmokeTests: AppTestCase {
    private let timeout: TimeInterval = 60

    func testRoleChoiceLeadsToBothPairingScreens() {
        let app = launch(state: "fresh")
        let baby = app.buttons["role.baby"], parent = app.buttons["role.parent"]
        XCTAssertTrue(baby.waitForExistence(timeout: timeout))
        XCTAssertTrue(baby.isHittable)
        XCTAssertTrue(parent.isHittable)
        attachScreenshot(named: "1-role")

        baby.tap()
        let code = app.staticTexts["pairing.code"]
        XCTAssertTrue(code.waitForExistence(timeout: timeout))
        // Read out digit by digit: "1 2 3 4 5 6".
        XCTAssertEqual(code.label.filter(\.isNumber).count, 6)
        attachScreenshot(named: "2-pairing-baby")

        app.swipeUp()
        app.buttons["pairing.changeRole"].tap()
        XCTAssertTrue(parent.waitForExistence(timeout: timeout))
        parent.tap()
        acceptSystemAlerts()
        let field = app.textFields["pairing.codeField"], submit = app.buttons["pairing.submit"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        XCTAssertFalse(submit.isEnabled)
        type("123456", into: field)
        attachScreenshot(named: "3-pairing-parent")
        // Six digits start pairing by themselves. No baby unit exists here, and the app says so.
        XCTAssertTrue(app.staticTexts["pairing.failure"].waitForExistence(timeout: timeout))
        XCTAssertTrue(submit.isEnabled)
    }

    func testBabyUnitStartsOrExplainsWhyItCannot() {
        let app = launch(state: "baby-paired")
        let start = app.buttons["baby.start"]
        XCTAssertTrue(start.waitForExistence(timeout: timeout))
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(app.buttons["baby.settings"].isHittable)
        attachScreenshot(named: "4-baby-idle")

        start.tap()
        acceptSystemAlerts()
        // A machine without a microphone cannot monitor: the app must say so instead of failing silently.
        let stop = app.buttons["baby.stop"], failure = app.staticTexts["baby.startFailure"]
        let outcome = expectation(for: NSPredicate { _, _ in stop.exists || failure.exists }, evaluatedWith: nil)
        wait(for: [outcome], timeout: timeout)
        attachScreenshot(named: "5-baby-monitoring")
        if stop.exists {
            stop.tap()
            XCTAssertTrue(start.waitForExistence(timeout: timeout))
        }
    }

    func testParentUnitShowsTheLiveScreenThenExplainsTheFailure() {
        let app = launch(state: "parent-paired")
        // Notifications, then the microphone.
        acceptSystemAlerts()

        // The live screen shows while the app searches. It only lasts a few seconds here,
        // so it is captured when seen. The two-device test checks it for real.
        let talk = app.buttons["parent.talk"]
        if talk.waitForExistence(timeout: 2) {
            attachScreenshot(named: "6-parent-searching")
        }

        // No baby unit exists here, so the search ends on the failure screen.
        let journal = app.buttons["failure.journal"]
        XCTAssertTrue(journal.waitForExistence(timeout: 90))
        XCTAssertTrue(app.buttons["parent.settings"].isHittable)
        XCTAssertTrue(app.buttons["failure.retry"].isHittable)
        attachScreenshot(named: "7-parent-failure")

        journal.tap()
        XCTAssertTrue(app.descendants(matching: .any)["journal"].waitForExistence(timeout: timeout))
        attachScreenshot(named: "8-journal")

        // The bar under every screen leads to the settings.
        let settings = app.buttons["parent.settings"]
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        // The parent's own choices about alerts come first, with the noise sensitivity that feeds them.
        XCTAssertTrue(app.descendants(matching: .any)["settings.alerts.trigger"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["journal.sensitivity"].exists)
        attachScreenshot(named: "9-settings")
        // On a small screen the rest of the list is further down.
        let diagnostics = app.buttons["settings.diagnostics"]
        if !diagnostics.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(diagnostics.waitForExistence(timeout: timeout))
        diagnostics.tap()
        XCTAssertTrue(app.descendants(matching: .any)["diagnostics.icloud"].waitForExistence(timeout: timeout))
        attachScreenshot(named: "10-diagnostics")
    }
}
