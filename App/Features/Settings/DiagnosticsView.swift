import BabyphoneCore
import BabyphoneTransport
import SwiftUI

/// Answers "why does it not connect?" without a support email: what network
/// this phone is on, whether it can be reached from outside, and how the night went.
struct DiagnosticsView: View {
    let database: AppDatabase
    /// Reads the addresses of the live connection. Parent unit only.
    var currentPath: (() async -> WebRTCSession.Path?)?

    @State private var addresses: [InterfaceAddress] = []
    @State private var cloud: RendezvousAvailability?
    @State private var path: WebRTCSession.Path?
    @State private var healthExport: URL?

    var body: some View {
        List {
            Section {
                InfoRow(title: "diagnostics.icloud") { Text(cloudText) }
                    .accessibilityIdentifier("diagnostics.icloud")
                InfoRow(title: "diagnostics.ipv6") { Text(hasGlobalIPv6 ? "common.yes" : "common.no") }
            } header: {
                Text("diagnostics.remote")
            } footer: {
                Text(hasGlobalIPv6 ? "diagnostics.ipv6.present" : "diagnostics.ipv6.missing")
            }

            if let path {
                Section("diagnostics.path") {
                    InfoRow(title: "diagnostics.path.local") { Text(verbatim: path.local) }
                    InfoRow(title: "diagnostics.path.remote") { Text(verbatim: path.remote) }
                }
            }

            Section("diagnostics.addresses") {
                if addresses.isEmpty {
                    Text("diagnostics.addresses.none")
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(addresses) { address in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: address.address)
                            .font(.footnote.monospaced())
                        Text(verbatim: "\(address.interface) · \(address.scope.rawValue)")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }

            Section {
                if let healthExport {
                    ShareLink("diagnostics.health.export", item: healthExport)
                }
            } header: {
                Text("diagnostics.health")
            } footer: {
                Text("diagnostics.health.footer")
            }
        }
        .navigationTitle("diagnostics.title")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    private var hasGlobalIPv6: Bool {
        addresses.contains { $0.scope == .globalIPv6 }
    }

    private var cloudText: LocalizedStringKey {
        switch cloud {
        case .available: "diagnostics.icloud.available"
        case .noAccount: "diagnostics.icloud.noAccount"
        case .unavailable: "diagnostics.icloud.unavailable"
        case nil: "common.unknown"
        }
    }

    private func refresh() async {
        addresses = InterfaceAddress.current()
        cloud = await CloudKitRendezvous().availability()
        path = await currentPath?()
        healthExport = await exportHealthLog()
    }

    /// Writes the last 24 hours of health samples to a CSV file that can be shared.
    private func exportHealthLog() async -> URL? {
        guard let csv = try? await HealthLog(database: database).csv(since: Date().addingTimeInterval(-24 * 3600)) else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nid-health.csv")
        return (try? csv.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}
