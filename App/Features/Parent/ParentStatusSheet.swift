import BabyphoneCore
import SwiftUI

/// What the chips of the live screen stand for, in full sentences.
///
/// A chip has room for three words. What the fallback through iCloud cannot
/// promise takes more than that, and is said here in full.
struct ParentStatusSheet: View {
    @ObservedObject var model: ParentMonitorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if !model.isConnected {
                        RelayCard(state: model.relay, digest: model.relayDigest)
                    }
                    if isBabyHot {
                        note("parent.babyHot", systemImage: "flame.fill", tint: Theme.alert)
                    }
                    if model.isVolumeLow {
                        note("parent.volumeLow", systemImage: "speaker.wave.1.fill", tint: Theme.accent)
                    }
                    if model.isRemoteAccessMissing {
                        note("icloud.missing", systemImage: "exclamationmark.icloud", tint: Theme.secondaryText)
                    }
                }
                .padding(16)
                .readableWidth()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("parent.details.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var isBabyHot: Bool {
        guard model.isConnected, let thermal = model.status?.thermal else { return false }
        return thermal == .serious || thermal == .critical
    }

    private func note(_ text: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        Card {
            Label {
                Text(text)
                    .foregroundStyle(Theme.text)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            .font(.subheadline)
        }
    }
}
