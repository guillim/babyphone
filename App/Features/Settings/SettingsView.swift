import BabyphoneCore
import SwiftUI

/// Settings of this phone: the room, the pairing, and a way to check the network.
struct SettingsView: View {
    let role: DeviceRole
    var babyModel: BabyMonitorModel?
    var parentModel: ParentMonitorModel?
    /// Set where the settings are a screen of their own and not a sheet: called
    /// in place of dismissing, to go back to where monitoring shows.
    var onClose: (@MainActor () -> Void)?

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
                Group {
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

                    if let parentModel {
                        ParentAlertSection(model: parentModel)
                    }

                    // Kept apart from the alerts: this ends everything, where a pause only quietens.
                    if let parentModel, parentModel.isMonitoring {
                        Section {
                            Button {
                                Task {
                                    await parentModel.stop()
                                    close()
                                }
                            } label: {
                                RowLabel(title: "settings.stopListening", systemImage: "stop.circle")
                            }
                        } footer: {
                            Text("settings.stopListening.footer")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            pendingAction = .unpair
                        } label: {
                            RowLabel(title: "settings.unpair", systemImage: "trash", isDestructive: true)
                        }
                        Button(role: .destructive) {
                            pendingAction = .changeRole
                        } label: {
                            RowLabel(title: "settings.changeRole", systemImage: "arrow.left.arrow.right", isDestructive: true)
                        }
                    }

                    // Last of what can be touched: the least needed.
                    Section {
                        if let database = app.database {
                            NavigationLink {
                                DiagnosticsView(database: database, parentModel: parentModel)
                            } label: {
                                RowLabel(title: "diagnostics.title", systemImage: "wifi")
                            }
                            .accessibilityIdentifier("settings.diagnostics")
                        }
                    }

                    Section {
                        InfoRow(title: "settings.version") {
                            Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                        }
                    } footer: {
                        Text("role.footer")
                    }
                }
                .listRowBackground(Theme.card)
            }
            .themedList()
            .navigationTitle("settings.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A sheet needs a way out. A screen of its own has the bar under it.
                if onClose == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done") {
                            babyModel?.setRoomName(roomName)
                            dismiss()
                        }
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
            close()
            await change()
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

/// One parent's choices about alerts: about what, and a pause.
private struct ParentAlertSection: View {
    @ObservedObject var model: ParentMonitorModel

    var body: some View {
        Section {
            Picker(selection: trigger) {
                Text("settings.alerts.trigger.anyNoise").tag(AlertTrigger.anyNoise)
                Text("settings.alerts.trigger.cryOnly").tag(AlertTrigger.cryOnly)
            } label: {
                RowLabel(title: "settings.alerts.trigger", systemImage: "bell")
            }
            .accessibilityIdentifier("settings.alerts.trigger")
            if model.alertPolicy.trigger == .cryOnly, model.status?.isCryDetectionActive == false {
                Text("settings.alerts.cryUnavailable")
                    .font(.footnote)
                    .foregroundStyle(Theme.alert)
            }
            if let until = model.alertPolicy.snoozedUntil {
                HStack {
                    RowLabel(title: "parent.snooze.until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "bell.slash")
                    Spacer()
                    Button("parent.snooze.resume", action: model.resumeAlerts)
                        .buttonStyle(.borderless)
                }
            } else if model.isMonitoring {
                Menu {
                    ForEach(AlertPolicy.snoozeChoices, id: \.self) { minutes in
                        Button("parent.snooze.minutes \(String(minutes))") { model.snoozeAlerts(minutes: minutes) }
                    }
                } label: {
                    // A menu centres a label that wraps; a row reads from its leading edge.
                    RowLabel(title: "settings.alerts.snooze", systemImage: "bell.slash")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            Text("settings.alerts")
        }
    }

    private var trigger: Binding<AlertTrigger> {
        Binding(get: { model.alertPolicy.trigger }, set: { model.setAlertTrigger($0) })
    }
}

/// The label of a settings row: its title in the text colour and its icon in the
/// accent, so that rows read alike whatever control they sit in. A row that
/// undoes the pairing takes the alert colour for both.
private struct RowLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isDestructive = false

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(isDestructive ? Theme.alert : Theme.text)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(isDestructive ? Theme.alert : Theme.accent)
        }
    }
}
