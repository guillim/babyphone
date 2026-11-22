import BabyphoneCore
import SwiftUI

/// Says what the fallback through iCloud is doing while no direct link exists.
///
/// Through iCloud the parent unit gets neither picture nor sound, only the baby
/// unit's latest alerts, with no promise about delay or delivery. The card says
/// so every time it shows.
struct RelayCard: View {
    let state: AlertWatch.State
    let digest: AlertDigest?

    /// A baby unit that monitors leaves a sign of life every minute. After this long without one, it may be gone.
    private static let staleAfter: TimeInterval = 180

    var body: some View {
        if state != .off {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Label("parent.relay.title", systemImage: "icloud")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    TimelineView(.periodic(from: .now, by: 20)) { context in
                        let stale = isStale(at: context.date)
                        Text(detail(isStale: stale))
                            .font(.footnote)
                            .foregroundStyle(stale ? Theme.alert : Theme.status)
                    }
                    Text("parent.relay.disclaimer")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("parent.relay")
        }
    }

    private func isStale(at now: Date) -> Bool {
        guard state == .receiving, let digest, digest.isMonitoring else { return state == .unavailable }
        return now.timeIntervalSince(digest.publishedAt) > Self.staleAfter
    }

    private func detail(isStale: Bool) -> LocalizedStringKey {
        guard state == .receiving, let digest else {
            return state == .unavailable ? "parent.relay.unavailable" : "parent.relay.waiting"
        }
        guard digest.isMonitoring else { return "parent.relay.stopped" }
        let time = digest.publishedAt.formatted(date: .omitted, time: .shortened)
        return isStale ? "parent.relay.stale \(time)" : "parent.relay.fresh \(time)"
    }
}
