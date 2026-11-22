import BabyphoneCore
import SwiftUI

/// The night journal, and the noise sensitivity that feeds it.
struct JournalView: View {
    @ObservedObject var model: ParentMonitorModel

    var body: some View {
        List {
            Section {
                Picker("journal.sensitivity", selection: sensitivity) {
                    Text("sensitivity.low").tag(Sensitivity.low)
                    Text("sensitivity.medium").tag(Sensitivity.medium)
                    Text("sensitivity.high").tag(Sensitivity.high)
                }
                .pickerStyle(.segmented)
                .disabled(!model.isConnected)
                .accessibilityIdentifier("journal.sensitivity")
            } header: {
                Text("journal.sensitivity")
            } footer: {
                Text("journal.sensitivity.footer")
            }
            .listRowBackground(Theme.card)

            if nights.isEmpty {
                Text("journal.empty")
                    .foregroundStyle(Theme.secondaryText)
                    .listRowBackground(Theme.card)
            }
            ForEach(nights, id: \.start) { night in
                Section {
                    ForEach(night.events) { event in
                        JournalRow(event: event)
                    }
                } header: {
                    if night.start == Night.start(containing: Date()) {
                        Text("journal.tonight")
                    } else {
                        Text(night.start, format: .dateTime.weekday(.wide).day().month())
                    }
                }
                .listRowBackground(Theme.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("journal.title")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: model.dismissNoiseAlert)
    }

    private var sensitivity: Binding<Sensitivity> {
        Binding(get: { model.status?.sensitivity ?? .medium }, set: { model.setSensitivity($0) })
    }

    /// Events grouped by night, most recent night first.
    private var nights: [(start: Date, events: [JournalEvent])] {
        Dictionary(grouping: model.events) { Night.start(containing: $0.date) }
            .map { (start: $0.key, events: $0.value) }
            .sorted { $0.start > $1.start }
    }
}

private struct JournalRow: View {
    let event: JournalEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Theme.text)
                if event.kind == .noise || event.kind == .cry {
                    if let duration = event.duration {
                        Text(Duration.seconds(duration.rounded()), format: .units(allowed: [.minutes, .seconds], width: .abbreviated))
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        Text("journal.noise.ongoing")
                            .font(.footnote)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            Spacer()
            Text(event.date, format: .dateTime.hour().minute())
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(minHeight: Theme.minimumTouchTarget)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("journal.event.\(event.kind.rawValue)")
    }

    private var title: LocalizedStringKey {
        switch event.kind {
        case .monitoringStarted: "journal.event.started"
        case .monitoringStopped: "journal.event.stopped"
        case .noise: "journal.event.noise"
        case .cry: "journal.event.cry"
        case .linkLost: "journal.event.linkLost"
        case .linkRestored: "journal.event.linkRestored"
        case .unplugged: "journal.event.unplugged"
        case .batteryLow: "journal.event.batteryLow"
        }
    }

    private var systemImage: String {
        switch event.kind {
        case .monitoringStarted: "play.circle"
        case .monitoringStopped: "stop.circle"
        case .noise: "waveform"
        case .cry: "drop.fill"
        case .linkLost: "wifi.slash"
        case .linkRestored: "wifi"
        case .unplugged: "powerplug"
        case .batteryLow: "battery.25"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .noise, .cry, .unplugged: Theme.accent
        case .linkLost, .batteryLow: Theme.alert
        default: Theme.status
        }
    }
}
