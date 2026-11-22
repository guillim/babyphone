import BabyphoneCore
import SwiftUI

/// The baby unit's only screen: start monitoring, then stay dark and out of the way.
struct BabyMonitorView: View {
    @StateObject private var model: BabyMonitorModel
    @State private var isShowingSettings = false

    init(model: @autoclosure @escaping () -> BabyMonitorModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        ZStack {
            Theme.babyBackground.ignoresSafeArea()
            if model.isMonitoring {
                monitoring
            } else {
                idle
            }
            if model.nightLight == .screen {
                nightLight
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.registerTouch() })
        .task { await model.loadSettings() }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(role: .baby, babyModel: model)
        }
    }

    private var idle: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text(model.roomName)
                .font(Theme.heading(.title))
                .foregroundStyle(Theme.text)
            Text("baby.idle.detail")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            if let failure = model.startFailure {
                Text(failure == .microphoneDenied ? "baby.error.microphone" : "baby.error.audio")
                    .font(.footnote)
                    .foregroundStyle(Theme.alert)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("baby.startFailure")
            }
            Spacer()
            Button("baby.start") {
                Task { await model.start() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("baby.start")
            Button("settings.title") {
                isShowingSettings = true
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("baby.settings")
        }
        .padding(20)
    }

    private var monitoring: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Badge(text: Text("baby.active"), systemImage: "dot.radiowaves.left.and.right")
                    Text(model.roomName)
                        .font(Theme.heading(.title2))
                        .foregroundStyle(Theme.text)
                    Text(isParentConnected ? "baby.parent.connected" : "baby.parent.waiting")
                        .font(.subheadline)
                        .foregroundStyle(isParentConnected ? Theme.status : Theme.secondaryText)
                }
                .padding(.top, 8)

                Card {
                    VStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("baby.sound")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryText)
                            SoundMeter(level: model.soundLevel)
                        }
                        InfoRow(title: "baby.battery") { batteryText }
                        InfoRow(title: "baby.camera") { Text(cameraText) }
                        InfoRow(title: "baby.link") { Text(linkText) }
                        InfoRow(title: "baby.remote") { Text(remoteText) }
                    }
                }

                if model.remoteAccess == .noAccount {
                    Text("icloud.missing")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                        .multilineTextAlignment(.center)
                }
                Text("baby.note")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)

                Button("baby.stop") {
                    Task { await model.stop() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("baby.stop")
            }
            .padding(20)
        }
        // A dimmed screen should show as little light as possible.
        .opacity(model.isScreenDimmed ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.6), value: model.isScreenDimmed)
    }

    private var nightLight: some View {
        Theme.nightLight
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text("baby.nightLight.hint")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.onAccent.opacity(0.6))
                    .padding(24)
            }
            .transition(.opacity)
    }

    private var isParentConnected: Bool {
        if case .connected = model.link { true } else { false }
    }

    @ViewBuilder private var batteryText: some View {
        if let level = model.batteryLevel {
            let percentage = level.formatted(.percent.precision(.fractionLength(0)))
            Text(model.isCharging ? "baby.battery.charging \(percentage)" : "baby.battery.unplugged \(percentage)")
        } else {
            Text("common.unknown")
        }
    }

    private var cameraText: LocalizedStringKey {
        if !model.isCameraAllowed { return "baby.camera.denied" }
        return model.isCameraRunning ? "baby.camera.on" : "baby.camera.standby"
    }

    private var linkText: LocalizedStringKey {
        switch model.link {
        case .connected(.local): "baby.link.local"
        case .connected(.remote): "baby.link.remote"
        case .waiting, .stopped: "baby.link.waiting"
        }
    }

    private var remoteText: LocalizedStringKey {
        switch model.remoteAccess {
        case .ready: "baby.remote.ready"
        case .noAccount: "baby.remote.noAccount"
        case .unavailable: "baby.remote.unavailable"
        case .disabled: "baby.remote.starting"
        }
    }
}
