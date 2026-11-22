import SwiftUI

@main
struct BabyphoneApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    // Quitting the app on purpose must not be reported later as an interrupted night.
                    AlertNotifier.clear()
                }
        }
    }
}
