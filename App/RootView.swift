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
        case .monitoring(.baby, let key):
            if let database = app.database {
                BabyMonitorView(model: BabyMonitorModel(key: key, database: database, media: app.media))
                    .id(key.rendezvousID)
            }
        case .monitoring(.parent, let key):
            if let database = app.database {
                ParentMonitorView(model: ParentMonitorModel(key: key, database: database, media: app.media))
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
