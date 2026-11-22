import Foundation
#if canImport(os)
import os
#endif

/// A trace of what happens to the link between the two devices.
///
/// When a connection drops in the middle of the night, the question is always
/// why. Every decision about the link is written here, and can be read in
/// Console on a Mac with the device plugged in: filter on the subsystem "nuzzlecam".
public enum LinkLog {
    #if canImport(os)
    private static let logger = Logger(subsystem: "nuzzlecam", category: "link")
    #endif

    public static func note(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger.notice("\(text, privacy: .public)")
        #endif
    }
}
