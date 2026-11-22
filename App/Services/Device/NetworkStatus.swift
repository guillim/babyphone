import BabyphoneCore
import CoreTelephony
import Foundation
@preconcurrency import Network

/// What kind of network this phone is on, and a signal each time it changes.
final class NetworkStatus: @unchecked Sendable {
    enum Kind: Sendable, Equatable {
        case wifi
        case cellular(generation: String?)
        case other
        case offline
    }

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var current = Kind.offline

    var kind: Kind { lock.withLock { current } }

    /// Starts watching. `onChange` runs on a background queue whenever the network changes.
    func start(onChange: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let kind = Self.kind(of: path)
            lock.withLock { current = kind }
            onChange()
        }
        monitor.start(queue: DispatchQueue(label: "nid.network-status"))
    }

    func stop() {
        monitor.cancel()
    }

    private static func kind(of path: NWPath) -> Kind {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular(generation: cellularGeneration()) }
        return .other
    }

    private static func cellularGeneration() -> String? {
        guard let technology = CTTelephonyNetworkInfo().serviceCurrentRadioAccessTechnology?.values.first else { return nil }
        switch technology {
        case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA: return "5G"
        case CTRadioAccessTechnologyLTE: return "4G"
        default: return nil
        }
    }
}

/// The IP addresses of this phone, for the diagnostics screen.
struct InterfaceAddress: Identifiable, Equatable {
    let interface: String
    let address: String
    let scope: AddressScope

    var id: String { interface + address }

    /// Addresses of the Wi-Fi (`en0`) and cellular (`pdp_ip`) interfaces.
    static func current() -> [InterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var addresses: [InterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("pdp_ip"), let socketAddress = entry.pointee.ifa_addr else { continue }
            let family = Int32(socketAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(socketAddress, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            addresses.append(InterfaceAddress(interface: name, address: address, scope: .of(address)))
        }
        return addresses
    }
}
