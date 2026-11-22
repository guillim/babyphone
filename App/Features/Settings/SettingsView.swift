import BabyphoneCore
import SwiftUI

/// Settings of this phone: the room, the pairing, and a way to check the network.
struct SettingsView: View {
    let role: DeviceRole
    var babyModel: BabyMonitorModel?
    var parentModel: ParentMonitorModel?

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var roomName = ""
    @State private var usesFrontCamera = false
    @State private var pendingAction: DestructiveAction?

    private enum DestructiveAction: Identifiable {
        case unpair
        case changeRole

        var id: Self { self }
    }

    /// The parent units paired with this baby unit.
    private var parentKeys: [PairingKey] {
        guard case .monitoring(.baby, let keys) = app.stage else { return [] }
        return keys
    }

    var body: some View {
        NavigationStack {
            Form {
                if let babyModel {
                    Section {
                        TextField("settings.roomName", text: $roomName)
                            .onSubmit { babyModel.setRoomName(roomName) }
                        Picker("settings.camera", selection: $usesFrontCamera) {
                            Text("settings.camera.back").tag(false)
                            Text("settings.camera.front").tag(true)
                        }
                        .onChange(of: usesFrontCamera) { babyModel.setUsesFrontCamera($0) }
                    } header: {
                        Text("settings.room")
                    } footer: {
                        Text("settings.camera.footer")
                    }

                    Section {
                        ForEach(Array(parentKeys.enumerated()), id: \.element.rendezvousID) { index, key in
                            HStack {
                                Text("settings.parent \(String(index + 1))")
                                Spacer()
                                Button("settings.removeParent", role: .destructive) {
                                    leave { app.removeParent(key) }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        if parentKeys.count < AppModel.maxParents {
                            Button("settings.addParent") {
                                leave { app.addParent() }
                            }
                            .accessibilityIdentifier("settings.addParent")
                        }
                    } header: {
                        Text("settings.parents")
                    } footer: {
                        Text("settings.parents.footer")
                    }
                }

                if let parentModel, parentModel.isMonitoring {
                    Section {
                        Button("settings.stopListening") {
                            Task {
                                await parentModel.stop()
                                dismiss()
                            }
                        }
                    } footer: {
                        Text("parent.paused.detail")
                    }
                }

                Section {
                    if let database = app.database {
                        NavigationLink("diagnostics.title") {
                            DiagnosticsView(database: database, parentModel: parentModel)
                        }
                        .accessibilityIdentifier("settings.diagnostics")
                    }
                }

                Section {
                    Button("settings.unpair", role: .destructive) { pendingAction = .unpair }
                    Button("settings.changeRole", role: .destructive) { pendingAction = .changeRole }
                } footer: {
                    Text("settings.pairing.footer")
                }

                Section {
                    InfoRow(title: "settings.version") {
                        Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    }
                } footer: {
                    Text("role.footer")
                }
            }
            .navigationTitle("settings.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        babyModel?.setRoomName(roomName)
                        dismiss()
                    }
                }
            }
            .onAppear {
                roomName = babyModel?.roomName ?? ""
                usesFrontCamera = babyModel?.usesFrontCamera ?? false
            }
            .confirmationDialog(
                "settings.confirm.title",
                isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                titleVisibility: .visible,
                presenting: pendingAction
            ) { action in
                Button(action == .unpair ? "settings.unpair" : "settings.changeRole", role: .destructive) {
                    perform(action)
                }
            } message: { _ in
                Text("settings.confirm.message")
            }
        }
    }

    private func perform(_ action: DestructiveAction) {
        leave {
            switch action {
            case .unpair: await app.unpair()
            case .changeRole: await app.resetRole()
            }
        }
    }

    /// Stops monitoring and closes the settings before a change that replaces the screen underneath.
    private func leave(then change: @escaping @MainActor () async -> Void) {
        Task {
            await babyModel?.stop()
            await parentModel?.stop()
            dismiss()
            await change()
        }
    }
}
