import Foundation

/// Coarse device temperature, mirrored from the system's thermal state.
public enum ThermalLevel: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// Snapshot of the baby unit, sent to the parent unit several times a second.
public struct MonitorStatus: Codable, Sendable, Equatable {
    /// Sound level in the room, from 0 (silence) to 1 (full scale).
    public var soundLevel: Double
    public var isNoiseActive: Bool
    /// Battery charge from 0 to 1, or nil when the system does not report it.
    public var batteryLevel: Double?
    public var isCharging: Bool
    public var thermal: ThermalLevel
    public var roomName: String
    public var sensitivity: Sensitivity
    public var isVideoEnabled: Bool
    public var isNightLightOn: Bool
    public var isLullabyPlaying: Bool
    /// When the white noise will stop by itself, or nil when it is off.
    public var whiteNoiseEndsAt: Date?
    /// The camera trades frame rate for longer exposure, to see in a dim room.
    public var isLowLightOn: Bool

    public init(
        soundLevel: Double = 0,
        isNoiseActive: Bool = false,
        batteryLevel: Double? = nil,
        isCharging: Bool = false,
        thermal: ThermalLevel = .nominal,
        roomName: String = "",
        sensitivity: Sensitivity = .medium,
        isVideoEnabled: Bool = true,
        isNightLightOn: Bool = false,
        isLullabyPlaying: Bool = false,
        whiteNoiseEndsAt: Date? = nil,
        isLowLightOn: Bool = false
    ) {
        self.soundLevel = soundLevel
        self.isNoiseActive = isNoiseActive
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.thermal = thermal
        self.roomName = roomName
        self.sensitivity = sensitivity
        self.isVideoEnabled = isVideoEnabled
        self.isNightLightOn = isNightLightOn
        self.isLullabyPlaying = isLullabyPlaying
        self.whiteNoiseEndsAt = whiteNoiseEndsAt
        self.isLowLightOn = isLowLightOn
    }
}
