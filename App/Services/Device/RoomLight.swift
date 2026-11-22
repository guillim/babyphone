@preconcurrency import AVFoundation
import UIKit

/// The baby unit's control over the light it gives off: its screen and its torch.
@MainActor
final class RoomLight {
    private static let dimmedBrightness: CGFloat = 0.01
    private static let nightLightBrightness: CGFloat = 0.55
    private static let torchLevel: Float = 0.12

    private var brightnessBeforeMonitoring: CGFloat?

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    /// Call when monitoring starts, to remember the brightness to restore afterwards.
    func begin() {
        brightnessBeforeMonitoring = screen?.brightness
    }

    func setScreen(_ level: ScreenLevel) {
        guard let original = brightnessBeforeMonitoring else { return }
        switch level {
        case .normal: screen?.brightness = original
        case .dimmed: screen?.brightness = Self.dimmedBrightness
        case .nightLight: screen?.brightness = Self.nightLightBrightness
        }
    }

    /// Call when monitoring stops.
    func end() {
        setTorch(false)
        if let brightnessBeforeMonitoring {
            screen?.brightness = brightnessBeforeMonitoring
        }
        brightnessBeforeMonitoring = nil
    }

    /// Turns the rear torch on at a low level, or off. Returns false when the phone has no torch.
    @discardableResult
    func setTorch(_ isOn: Bool) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch,
              (try? device.lockForConfiguration()) != nil
        else { return false }
        defer { device.unlockForConfiguration() }
        if isOn {
            return (try? device.setTorchModeOn(level: Self.torchLevel)) != nil
        }
        device.torchMode = .off
        return true
    }

    enum ScreenLevel {
        case normal
        case dimmed
        case nightLight
    }
}
