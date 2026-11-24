import XCTest

/// What every UI test of the app needs: a launch in a known state, and a firm hand with system alerts.
@MainActor
class AppTestCase: XCTestCase {
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    /// Launches the app in French, in the state named by `state` (see `AppModel.applyUITestState`).
    func launch(state: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        app.launchEnvironment["NUZZLECAM_UI_TEST_STATE"] = state
        app.launch()
        return app
    }

    /// Accepts every system permission alert that shows up within `seconds`.
    ///
    /// In CI the permissions are granted before launch, so this returns after a short look.
    /// It matters when the tests run from Xcode on a fresh simulator.
    func acceptSystemAlerts(within seconds: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 1) {
                // The accepting button comes last.
                alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
            }
        } while Date() < deadline
    }

    /// Types `text` into `field`, however long the keyboard takes to come up.
    func type(_ text: String, into field: XCUIElement) {
        for _ in 0..<10 {
            acceptSystemAlerts(within: 1)
            field.tap()
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true {
                field.typeText(text)
                return
            }
        }
        XCTFail("The field never took keyboard focus")
    }

    func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Polls `condition` until it holds or `timeout` passes.
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }
}
