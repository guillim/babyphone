import BabyphoneCore
import SwiftUI

/// The parent unit's main screen: the picture, the sound level and the controls.
struct ParentMonitorView: View {
    @StateObject private var model: ParentMonitorModel
    @State private var isShowingJournal = false
    @State private var isShowingSettings = false

    init(model: @autoclosure @escaping () -> ParentMonitorModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.isMonitoring {
                    paused
                } else if let reason = failureToShow {
                    ConnectionFailedView(reason: reason, retry: model.retry) {
                        isShowingJournal = true
                    }
                } else if model.didBabyStop, !model.isConnected {
                    babyStopped
                } else {
                    live
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(verbatim: model.status?.roomName ?? AppInfo.name)
                        .font(Theme.heading(.headline))
                        .foregroundStyle(Theme.text)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { isShowingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(Text("settings.title"))
                    .accessibilityIdentifier("parent.settings")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { isShowingJournal = true } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel(Text("journal.title"))
                    .accessibilityIdentifier("parent.journal")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $isShowingJournal) {
                JournalView(model: model)
            }
        }
        .task { await model.start() }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(role: .parent, parentModel: model)
        }
        .alert("parent.microphoneDenied.title", isPresented: microphoneDeniedBinding) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("parent.microphoneDenied.message")
        }
    }

    /// The failure screen replaces the live view only when no connection could be
    /// made at all. After a drop, the live view stays and shows the link as lost.
    private var failureToShow: ParentConnector.UnreachableReason? {
        guard case .unreachable(let reason) = model.connection, model.status == nil, !model.didBabyStop else { return nil }
        return reason
    }

    private var microphoneDeniedBinding: Binding<Bool> {
        Binding(get: { model.isMicrophoneDenied }, set: { _ in model.acknowledgeMicrophoneDenied() })
    }

    // MARK: Live

    private var live: some View {
        GeometryReader { proxy in
            // Fits one screen, down to an iPhone SE. Scrolls only when several banners stack up.
            ScrollView {
                liveContent(pictureHeight: max(170, proxy.size.height * 0.42))
                    .frame(minHeight: proxy.size.height)
            }
        }
    }

    private func liveContent(pictureHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            picture
                .frame(height: pictureHeight)
            banners
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("parent.sound")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                    SoundMeter(level: model.isConnected ? (model.status?.soundLevel ?? 0) : 0)
                }
            }
            Spacer(minLength: 0)
            TalkButton(isTalking: model.isTalking, isEnabled: model.isConnected, onChange: model.setTalking)
            HStack(spacing: 10) {
                ToggleTile(
                    title: "parent.nightLight", systemImage: "lightbulb.fill",
                    isOn: model.status?.isNightLightOn ?? false, action: model.toggleNightLight
                )
                ToggleTile(
                    title: "parent.lullaby", systemImage: "music.note",
                    isOn: model.status?.isLullabyPlaying ?? false, action: model.toggleLullaby
                )
                ToggleTile(
                    title: "parent.audioOnly", systemImage: "waveform",
                    isOn: !(model.status?.isVideoEnabled ?? true), action: model.toggleVideo
                )
            }
            .disabled(!model.isConnected)
            .opacity(model.isConnected ? 1 : 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var picture: some View {
        ZStack {
            Color.black
            if model.isConnected, model.status?.isVideoEnabled ?? true {
                VideoView(track: model.videoTrack)
            } else if model.isConnected {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                    Text("parent.audioOnly.detail")
                        .font(.footnote)
                }
                .foregroundStyle(Theme.secondaryText)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(connectingText)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(alignment: .topLeading) {
            if model.isConnected {
                Badge(text: Text("parent.live \(networkName)"), systemImage: "dot.radiowaves.left.and.right")
                    .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.isConnected, let level = model.status?.batteryLevel {
                Badge(
                    text: Text("parent.babyBattery \(level.formatted(.percent.precision(.fractionLength(0))))"),
                    systemImage: model.status?.isCharging == true ? "battery.100.bolt" : "battery.50",
                    tint: level < 0.2 && model.status?.isCharging != true ? Theme.alert : Theme.status
                )
                .padding(10)
            }
        }
    }

    @ViewBuilder private var banners: some View {
        if model.isAlarmSounding {
            AlertBanner(title: "parent.alarm.title", systemImage: "wifi.exclamationmark", actionTitle: "parent.alarm.silence", action: model.silenceAlarm)
        }
        if model.noiseAlert != nil {
            AlertBanner(title: "parent.noise.title", systemImage: "waveform.badge.exclamationmark", actionTitle: "parent.noise.view") {
                model.dismissNoiseAlert()
                isShowingJournal = true
            }
        }
        if model.isConnected, let thermal = model.status?.thermal, thermal == .serious || thermal == .critical {
            Text("parent.babyHot")
                .font(.footnote)
                .foregroundStyle(Theme.alert)
        }
        if model.isVolumeLow {
            Text("parent.volumeLow")
                .font(.footnote)
                .foregroundStyle(Theme.accent)
        }
        if model.isRemoteAccessMissing {
            Text("icloud.missing")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var babyStopped: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("parent.babyStopped.title")
                .font(Theme.heading(.title2))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text("parent.babyStopped.detail")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
            Button("failure.retry", action: model.retry)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
    }

    private var paused: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("parent.paused.title")
                .font(Theme.heading(.title2))
                .foregroundStyle(Theme.text)
            Text("parent.paused.detail")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
            Button("parent.resume") {
                Task { await model.start() }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
    }

    private var connectingText: LocalizedStringKey {
        switch model.connection {
        case .connecting: "parent.connecting"
        case .unreachable: "parent.reconnecting"
        default: "parent.searching"
        }
    }

    /// Name of the network the picture travels on, as shown in the "live" badge.
    private var networkName: String {
        guard case .connected(.remote) = model.connection else { return String(localized: "network.wifi") }
        switch model.networkKind {
        case .cellular(let generation?): return generation
        case .cellular: return String(localized: "network.cellular")
        default: return String(localized: "network.remote")
        }
    }
}

/// The main button of the parent unit: hold it to talk to the baby.
private struct TalkButton: View {
    let isTalking: Bool
    let isEnabled: Bool
    let onChange: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isTalking ? "mic.fill" : "mic")
            Text(isTalking ? "parent.talk.active" : "parent.talk")
        }
        .font(.headline)
        .foregroundStyle(Theme.onAccent)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(isTalking ? Theme.status : Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .opacity(isEnabled ? 1 : 0.4)
        .scaleEffect(isTalking ? 0.98 : 1)
        .animation(.easeOut(duration: 0.12), value: isTalking)
        // A zero-distance drag reports both the press and the release, which a tap cannot.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if isEnabled, !isTalking { onChange(true) } }
                .onEnded { _ in onChange(false) }
        )
        .accessibilityElement()
        .accessibilityLabel(Text("parent.talk"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("parent.talk")
    }
}

/// A prominent banner with one action, for things the parent must not miss.
private struct AlertBanner: View {
    let title: LocalizedStringKey
    let systemImage: String
    let actionTitle: LocalizedStringKey
    let action: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .font(.subheadline.weight(.bold))
                .frame(minWidth: Theme.minimumTouchTarget, minHeight: Theme.minimumTouchTarget)
        }
        .foregroundStyle(Theme.onAccent)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}
