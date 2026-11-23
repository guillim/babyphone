import BabyphoneCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .task { await app.load() }
    }

    @ViewBuilder private var content: some View {
        switch app.stage {
        case .loading:
            ProgressView()
        case .choosingRole:
            RoleSelectionView()
        case .pairing(.baby):
            BabyPairingView()
        case .pairing(.parent):
            ParentPairingView()
        case .monitoring(.baby, let keys):
            if let database = app.database {
                BabyMonitorView(model: BabyMonitorModel(keys: keys, database: database, media: app.babyMedia))
                    // A new set of parents means new connections: start from a fresh model.
                    .id(keys.map(\.rendezvousID).joined())
            }
        case .monitoring(.parent, let keys):
            if let database = app.database, let key = keys.first {
                ParentMonitorView(model: ParentMonitorModel(key: key, database: database, media: app.parentMedia, audio: app.parentAudio))
                    .id(key.rendezvousID)
            }
        case .broken:
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.accent)
                Text("error.database")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(24)
        }
    }
}
