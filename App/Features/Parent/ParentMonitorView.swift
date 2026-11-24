import BabyphoneCore
import SwiftUI

/// The parent unit: the live screen, the journal and the settings, under one floating bar.
struct ParentMonitorView: View {
    @StateObject private var model: ParentMonitorModel
    @State private var tab = ParentTab.live

    init(model: @autoclosure @escaping () -> ParentMonitorModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        Group {
            switch tab {
            case .live:
                live
            case .journal:
                NavigationStack {
                    JournalView(model: model)
                }
            case .settings:
                SettingsView(role: .parent, parentModel: model, onClose: { tab = .live })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The bar floats: lists scroll under it, and the picture runs behind it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ParentTabBar(selection: $tab, hasNews: model.cryAlert != nil || model.noiseAlert != nil)
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await model.start() }
        .alert("parent.microphoneDenied.title", isPresented: microphoneDeniedBinding) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("parent.microphoneDenied.message")
        }
    }

    /// The failure screen replaces the live view only when no connection could be
    /// made at all. After a drop, the live view stays and shows the link as lost.
    private var failureToShow: ParentConnector.UnreachableReason? {
        guard case .unreachable(let reason) = model.connection, model.status == nil, !model.didBabyStop else { return nil }
        return reason
    }

    private var microphoneDeniedBinding: Binding<Bool> {
        Binding(get: { model.isMicrophoneDenied }, set: { _ in model.acknowledgeMicrophoneDenied() })
    }

    // MARK: Live

    @ViewBuilder private var live: some View {
        if !model.isMonitoring {
            paused
        } else if let reason = failureToShow {
            ConnectionFailedView(reason: reason, relay: model.relay, relayDigest: model.relayDigest, retry: model.retry) {
                tab = .journal
            }
        } else if model.didBabyStop, !model.isConnected {
            babyStopped
        } else {
            ParentLiveView(model: model, showJournal: { tab = .journal })
        }
    }

    private var babyStopped: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("parent.babyStopped.title")
                .font(Theme.heading(.title2))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text("parent.babyStopped.detail")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
            Button("failure.retry", action: model.retry)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
        .readableWidth()
    }

    private var paused: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("parent.paused.title")
                .font(Theme.heading(.title2))
                .foregroundStyle(Theme.text)
            Text("parent.paused.detail")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
            Button("parent.resume") {
                Task { await model.start() }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
        .readableWidth()
    }
}
