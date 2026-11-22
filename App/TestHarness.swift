#if DEBUG
import Foundation

/// Lets a UI test follow a baby unit that runs in another simulator.
///
/// A two-device session needs both apps running at once, and a UI test can only
/// drive one simulator. So in that session the baby unit runs without a test
/// runner: it starts monitoring by itself and tells the test what happens through
/// small files in a folder both simulators can see, named by `NUZZLECAM_TEST_SHARED_DIR`.
/// None of this exists in a release build.
@MainActor
enum TestHarness {
    private static let folder = ProcessInfo.processInfo.environment["NUZZLECAM_TEST_SHARED_DIR"].map { URL(fileURLWithPath: $0) }

    /// Whether this launch is the baby side of a two-device session.
    static var isActive: Bool { folder != nil }

    /// Tells the test that `milestone` was reached.
    static func report(_ milestone: String, _ content: String = "") {
        guard let folder else { return }
        try? content.write(to: folder.appendingPathComponent(milestone), atomically: true, encoding: .utf8)
    }

    /// Plays the part of the person next to the baby unit: starts monitoring,
    /// waits for the parent unit, and stops when the test says it is done.
    static func runBabySession(with model: BabyMonitorModel) async {
        guard let folder else { return }
        await model.start()
        report(model.isMonitoring ? "baby-monitoring" : "baby-failed")
        await wait { !model.connectedRoutes.isEmpty }
        report("baby-connected")
        await wait { FileManager.default.fileExists(atPath: folder.appendingPathComponent("parent-done").path) }
        await model.stop()
        report("baby-stopped")
    }

    private static func wait(until condition: () -> Bool) async {
        while !condition(), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
#endif
