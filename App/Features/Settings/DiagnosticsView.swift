import BabyphoneCore
import BabyphoneTransport
import SwiftUI

/// Answers "why does it not connect?" without a support email: what network
/// this phone is on, whether it can be reached from outside, and how the night went.
struct DiagnosticsView: View {
    let database: AppDatabase
    /// The link to the baby unit. Parent unit only.
    var parentModel: ParentMonitorModel?

    @State private var addresses: [InterfaceAddress] = []
    @State private var cloud: RendezvousAvailability?
    @State private var path: WebRTCSession.Path?
    @State private var healthExport: URL?
    @State private var routerPort: PortMappingOutcome?
    @State private var isTestingRouter = false

    var body: some View {
        List {
            Group {
                Section {
                    InfoRow(title: "diagnostics.icloud") { Text(cloudText) }
                        .accessibilityIdentifier("diagnostics.icloud")
                    InfoRow(title: "diagnostics.ipv6") { Text(hasGlobalIPv6 ? "common.yes" : "common.no") }
                } header: {
                    Text("diagnostics.remote")
                } footer: {
                    Text(hasGlobalIPv6 ? "diagnostics.ipv6.present" : "diagnostics.ipv6.missing")
                }

                Section {
                    if let routerPort {
                        Text(routerText(for: routerPort))
                            .accessibilityIdentifier("diagnostics.router.result")
                    }
                    Button("diagnostics.router.test") {
                        Task { await testRouter() }
                    }
                    .disabled(isTestingRouter)
                    .accessibilityIdentifier("diagnostics.router.test")
                } header: {
                    Text("diagnostics.router")
                } footer: {
                    Text("diagnostics.router.footer")
                }

                if let parentModel {
                    ParentLinkSection(model: parentModel, path: path)
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
            .listRowBackground(Theme.card)
        }
        .themedList()
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

    private func routerText(for outcome: PortMappingOutcome) -> LocalizedStringKey {
        switch outcome {
        case .mapped(let mapping): "diagnostics.router.mapped \(mapping.method.rawValue) \(mapping.externalAddress)"
        case .noRouter: "diagnostics.router.none"
        case .unsupported: "diagnostics.router.unsupported"
        case .sharedAddress(let address): "diagnostics.router.shared \(address)"
        }
    }

    /// Asks the router for a port, says what came of it, and gives the port back.
    private func testRouter() async {
        isTestingRouter = true
        defer { isTestingRouter = false }
        guard let local = InterfaceAddress.current().first(where: { $0.interface == "en0" && $0.scope == .privateNetwork }) else {
            routerPort = .noRouter
            return
        }
        let mapper = RouterPortMapper(label: AppInfo.name)
        let outcome = await mapper.open(internalAddress: local.address, internalPort: UInt16.random(in: 50_000...59_999))
        routerPort = outcome
        if case .mapped(let mapping) = outcome {
            await mapper.close(mapping)
        }
    }

    private func refresh() async {
        addresses = InterfaceAddress.current()
        cloud = await CloudKitRendezvous().availability()
        path = await parentModel?.currentPath()
        healthExport = await exportHealthLog()
    }

    /// Writes the last 24 hours of health samples to a CSV file that can be shared.
    private func exportHealthLog() async -> URL? {
        guard let csv = try? await HealthLog(database: database).csv(since: Date().addingTimeInterval(-24 * 3600)) else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nuzzlecam-health.csv")
        return (try? csv.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}

/// The state of the parent unit's link: when the baby unit was last heard, the path in use, and a way to start over.
private struct ParentLinkSection: View {
    @ObservedObject var model: ParentMonitorModel
    let path: WebRTCSession.Path?

    var body: some View {
        Section("diagnostics.link") {
            InfoRow(title: "diagnostics.lastSignal") {
                if let lastSignal = model.lastSignal {
                    Text(lastSignal, style: .relative)
                } else {
                    Text("diagnostics.lastSignal.none")
                }
            }
            if let path {
                InfoRow(title: "diagnostics.path.local") { Text(verbatim: path.local) }
                InfoRow(title: "diagnostics.path.remote") { Text(verbatim: path.remote) }
            }
            Button("diagnostics.reconnect", action: model.reconnect)
        }
    }
}
