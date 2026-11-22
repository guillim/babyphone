import BabyphoneCore
import SwiftUI

/// Shown when the parent unit cannot reach the baby unit at all.
///
/// The app has no relay, so some networks simply cannot be crossed. This
/// screen says so plainly and walks the parent through what does work: a
/// personal hotspot, or mobile data on both sides.
struct ConnectionFailedView: View {
    let reason: ParentConnector.UnreachableReason
    let retry: @MainActor () -> Void
    let showJournal: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: reason == .noDirectPath ? "wifi.exclamationmark" : "moon.zzz.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 24)
                Text(title)
                    .font(Theme.heading(.title2))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(tips, id: \.self) { tip in
                            Label {
                                Text(LocalizedStringKey(tip))
                            } icon: {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(Theme.status)
                            }
                            .font(.subheadline)
                            .foregroundStyle(Theme.text)
                        }
                    }
                }

                Button("failure.retry", action: retry)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("failure.retry")
                Button("failure.journal", action: showJournal)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("failure.journal")
            }
            .padding(20)
            .readableWidth()
        }
    }

    private var title: LocalizedStringKey {
        switch reason {
        case .noDirectPath: "failure.noPath.title"
        case .babyOffline: "failure.offline.title"
        case .rendezvousUnavailable: "failure.noAccount.title"
        }
    }

    private var explanation: LocalizedStringKey {
        switch reason {
        case .noDirectPath: "failure.noPath.detail"
        case .babyOffline: "failure.offline.detail"
        case .rendezvousUnavailable: "icloud.missing"
        }
    }

    private var tips: [String] {
        switch reason {
        case .noDirectPath: ["failure.tip.hotspot", "failure.tip.cellular", "failure.tip.vpn", "failure.tip.place"]
        case .babyOffline: ["failure.tip.babyOpen", "failure.tip.babyNetwork"]
        case .rendezvousUnavailable: ["failure.tip.icloud", "failure.tip.sameWifi"]
        }
    }
}
