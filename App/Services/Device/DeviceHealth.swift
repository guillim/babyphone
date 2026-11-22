import BabyphoneCore
import UIKit

/// Battery and temperature of this phone.
@MainActor
enum DeviceHealth {
    static func startMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// Battery charge from 0 to 1, or nil when the system does not report it.
    static var batteryLevel: Double? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Double(level)
    }

    static var isCharging: Bool {
        [.charging, .full].contains(UIDevice.current.batteryState)
    }

    static var thermal: ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    static var isInBackground: Bool {
        UIApplication.shared.applicationState != .active
    }
}
