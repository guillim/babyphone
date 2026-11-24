import BabyphoneCore
import SwiftUI
@preconcurrency import WebRTC

/// The live screen of the parent unit. The picture fills it from edge to edge,
/// and everything else floats over it on glass: the state of the link, the
/// room's switches, and what the parent must not miss.
struct ParentLiveView: View {
    @ObservedObject var model: ParentMonitorModel
    let showJournal: @MainActor () -> Void

    @State private var isChoosingWhiteNoise = false
    @State private var isChoosingSnooze = false
    @State private var isShowingDetails = false

    var body: some View {
        ZStack {
            picture
                .ignoresSafeArea()
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        linkPill
                        if model.isConnected {
                            battery
                        } else {
                            searching
                        }
                    }
                    Spacer(minLength: 0)
                    rail
                }
                Spacer(minLength: 0)
                // Nearest the thumb: what asks for an answer, then what is only said.
                VStack(spacing: 8) {
                    banners
                    chips
                    if model.isConnected {
                        meter
                    }
                }
                .readableWidth()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
        .confirmationDialog("parent.whiteNoise.title", isPresented: $isChoosingWhiteNoise, titleVisibility: .visible) {
            ForEach([15, 30], id: \.self) { minutes in
                Button("parent.whiteNoise.minutes \(String(minutes))") { model.setWhiteNoise(minutes: minutes) }
            }
            Button("parent.whiteNoise.hour") { model.setWhiteNoise(minutes: 60) }
            Button("common.cancel", role: .cancel) {}
        }
        .confirmationDialog("parent.snooze.title", isPresented: $isChoosingSnooze, titleVisibility: .visible) {
            ForEach(AlertPolicy.snoozeChoices, id: \.self) { minutes in
                Button("parent.snooze.minutes \(String(minutes))") { model.snoozeAlerts(minutes: minutes) }
            }
            Button("common.cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isShowingDetails) {
            ParentStatusSheet(model: model)
        }
    }

    // MARK: Picture

    private var picture: some View {
        ZStack {
            RadialGradient(
                colors: [Theme.pictureGlow, Theme.pictureBackground],
                center: UnitPoint(x: 0.4, y: 0.34), startRadius: 0, endRadius: 480
            )
            if model.isConnected, !isAudioOnly {
                ZoomableVideo(track: model.videoTrack)
            } else if model.isConnected {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                    Text("parent.audioOnly.detail")
                        .font(.footnote)
                }
                .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var isAudioOnly: Bool {
        !(model.status?.isVideoEnabled ?? true)
    }

    // MARK: Link

    /// The room and the state of the link, in one glance.
    private var linkPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isConnected ? Theme.status : Theme.alert)
                .frame(width: 8, height: 8)
            Text(verbatim: model.status?.roomName ?? AppInfo.name)
                .font(Theme.heading(.subheadline))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(linkText)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Theme.minimumTouchTarget)
        .glass(in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(model.isConnected ? "parent.live" : "parent.offline")
    }

    private var linkText: LocalizedStringKey {
        model.isConnected ? "parent.live \(networkName)" : "parent.offline"
    }

    @ViewBuilder private var battery: some View {
        if let level = model.status?.batteryLevel {
            let percent = level.formatted(.percent.precision(.fractionLength(0)))
            Badge(
                text: Text(verbatim: percent),
                systemImage: model.status?.isCharging == true ? "battery.100.bolt" : "battery.50",
                tint: level < 0.2 && model.status?.isCharging != true ? Theme.alert : Theme.status
            )
            // The icon is enough on screen; VoiceOver still says whose battery it is.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("parent.babyBattery \(percent)"))
        }
    }

    /// Stands where the picture will be, and says first what matters most:
    /// whether anything watches over the room at all.
    private var searching: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text(offlineTitle)
                .font(Theme.heading(.title2))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(connectingText)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 28)
        .padding(.leading, 12)
        .accessibilityElement(children: .combine)
    }

    private var offlineTitle: LocalizedStringKey {
        // Only the baby unit's own word, read through iCloud, says that it stopped.
        if model.relay == .receiving, let digest = model.relayDigest, !digest.isMonitoring {
            return "parent.offline.unmonitored"
        }
        return "parent.offline.title"
    }

    private var connectingText: LocalizedStringKey {
        switch model.connection {
        case .connecting: "parent.connecting"
        case .unreachable: "parent.reconnecting"
        default: "parent.searching"
        }
    }

    /// Name of the network the picture travels on, as shown beside the room's name.
    private var networkName: String {
        guard case .connected(.remote) = model.connection else { return String(localized: "network.wifi") }
        switch model.networkKind {
        case .cellular(let generation?): return generation
        case .cellular: return String(localized: "network.cellular")
        default: return String(localized: "network.remote")
        }
    }

    // MARK: Rail

    /// The room's switches, out of the picture's way. The last one is this parent's
    /// own: it turns the picture off and keeps only the sound.
    private var rail: some View {
        VStack(spacing: 4) {
            RailButton(
                title: "parent.nightLight", systemImage: "lightbulb.fill",
                isOn: model.status?.isNightLightOn ?? false, action: model.toggleNightLight
            )
            .accessibilityIdentifier("parent.nightLight")
            RailButton(
                title: "parent.lullaby", systemImage: "music.note",
                isOn: model.status?.isLullabyPlaying ?? false, action: model.toggleLullaby
            )
            .accessibilityIdentifier("parent.lullaby")
            RailButton(
                title: "parent.whiteNoise", systemImage: "wind",
                isOn: model.status?.whiteNoiseEndsAt != nil
            ) {
                // Off: ask for how long. On: one touch stops it.
                if model.status?.whiteNoiseEndsAt == nil {
                    isChoosingWhiteNoise = true
                } else {
                    model.setWhiteNoise(minutes: nil)
                }
            }
            .accessibilityIdentifier("parent.whiteNoise")
            RailButton(
                title: "parent.lowLight", systemImage: "moon.fill",
                isOn: model.status?.isLowLightOn ?? false, action: model.toggleLowLight
            )
            .accessibilityIdentifier("parent.lowLight")
            Capsule()
                .fill(Color.white.opacity(0.16))
                .frame(width: 24, height: 1)
                .padding(.vertical, 2)
            RailButton(
                title: "parent.audioOnly", systemImage: isAudioOnly ? "video.slash.fill" : "video.fill",
                isOn: isAudioOnly, action: model.toggleVideo
            )
            .accessibilityIdentifier("parent.audioOnly")
        }
        .padding(6)
        .glass(in: Capsule())
        .disabled(!model.isConnected)
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if model.isAlarmSounding {
            GlassBanner(
                title: "parent.alarm.title", systemImage: "wifi.exclamationmark",
                actionTitle: "parent.alarm.silence", action: model.silenceAlarm
            )
        }
        if let power = model.powerAlert {
            GlassBanner(
                title: power == .unplugged ? "parent.power.unplugged" : "parent.power.low",
                systemImage: power == .unplugged ? "powerplug" : "battery.25",
                actionTitle: "common.ok", action: model.dismissPowerAlert
            )
        }
        if let alert = model.cryAlert ?? model.noiseAlert {
            GlassBanner(
                title: model.cryAlert != nil ? "parent.cry.title" : "parent.noise.title",
                systemImage: model.cryAlert != nil ? "drop.fill" : "waveform.badge.exclamationmark",
                time: alert.date,
                actionTitle: "parent.noise.view",
                action: {
                    model.dismissNoiseAlert()
                    showJournal()
                },
                secondaryTitle: model.alertPolicy.snoozedUntil == nil ? "parent.snooze" : nil,
                secondaryAction: { isChoosingSnooze = true }
            )
        }
        if let until = model.alertPolicy.snoozedUntil {
            HStack(spacing: 8) {
                Image(systemName: "bell.slash")
                Text("parent.snooze.until \(until.formatted(date: .omitted, time: .shortened))")
                Spacer(minLength: 8)
                Button("parent.snooze.resume", action: model.resumeAlerts)
                    .font(.footnote.weight(.bold))
                    .frame(minWidth: Theme.minimumTouchTarget, minHeight: Theme.minimumTouchTarget)
                    .accessibilityIdentifier("parent.snooze.resume")
            }
            .font(.footnote)
            .foregroundStyle(Theme.accent)
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .glass(in: Capsule())
        }
    }

    // MARK: Chips

    private var hasRelay: Bool {
        !model.isConnected && model.relay != .off
    }

    private var isBabyHot: Bool {
        guard model.isConnected, let thermal = model.status?.thermal else { return false }
        return thermal == .serious || thermal == .critical
    }

    /// Short facts that need no answer. One touch opens them as full sentences.
    @ViewBuilder private var chips: some View {
        if hasRelay || isBabyHot || model.isVolumeLow || model.isRemoteAccessMissing {
            Button {
                isShowingDetails = true
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { chipList }
                    VStack(spacing: 8) { chipList }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("parent.details")
        }
    }

    @ViewBuilder private var chipList: some View {
        if hasRelay {
            Chip(title: "parent.relay.short", systemImage: "icloud", leadsFurther: true)
        }
        if isBabyHot {
            Chip(title: "parent.babyHot.short", systemImage: "flame.fill", tint: Theme.alert)
        }
        if model.isVolumeLow {
            Chip(title: "parent.volumeLow.short", systemImage: "speaker.wave.1.fill")
        }
        if model.isRemoteAccessMissing {
            Chip(title: "icloud.missing.short", systemImage: "exclamationmark.icloud")
        }
    }

    // MARK: Sound

    private var meter: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            SoundMeter(level: model.status?.soundLevel ?? 0)
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.minimumTouchTarget)
        .glass(in: Capsule())
    }
}

/// One of the room's switches, on the rail beside the picture.
private struct RailButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isOn: Bool
    let action: @MainActor () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
                .frame(width: Theme.minimumTouchTarget, height: Theme.minimumTouchTarget)
                .background(isOn ? Theme.accent : Color.clear, in: Circle())
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        // The rail shows icons only: the name is for VoiceOver.
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A short fact on glass: an icon and two or three words.
private struct Chip: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint = Theme.accent
    /// Takes the room left in its row and shows that more can be read.
    var leadsFurther = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(title)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if leadsFurther {
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 14)
        .frame(minHeight: Theme.minimumTouchTarget)
        .glass(in: Capsule())
    }
}

/// A banner on glass for things the parent must not miss. With one action it
/// stays on one line. With two, the actions get a line of their own.
private struct GlassBanner: View {
    let title: LocalizedStringKey
    let systemImage: String
    /// When what the banner reports happened.
    var time: Date?
    let actionTitle: LocalizedStringKey
    let action: @MainActor () -> Void
    var secondaryTitle: LocalizedStringKey?
    var secondaryAction: (@MainActor () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 32, height: 32)
                    .background(Theme.alert, in: Circle())
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if let time {
                    Text(time, format: .dateTime.hour().minute())
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
                if secondaryTitle == nil {
                    primaryButton
                }
            }
            if let secondaryTitle, let secondaryAction {
                HStack(spacing: 8) {
                    Button(action: secondaryAction) {
                        Text(secondaryTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, minHeight: Theme.minimumTouchTarget)
                            .background(Color.white.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    primaryButton
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, secondaryTitle == nil ? 6 : 12)
        .padding(.vertical, secondaryTitle == nil ? 6 : 12)
        .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), outline: Theme.alert.opacity(0.55))
    }

    private var primaryButton: some View {
        Button(action: action) {
            Text(actionTitle)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 18)
                .frame(maxWidth: secondaryTitle == nil ? nil : .infinity, minHeight: Theme.minimumTouchTarget)
                .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The picture from the room. Pinch to look closer, drag to move around, double-tap to see it all again.
private struct ZoomableVideo: View {
    let track: RTCVideoTrack?

    private static let maxZoom: CGFloat = 4
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var drag = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let scale = min(max(zoom * pinch, 1), Self.maxZoom)
            VideoView(track: track)
                .scaleEffect(scale)
                .offset(clamped(CGSize(width: offset.width + drag.width, height: offset.height + drag.height), scale: scale, in: proxy.size))
                .gesture(
                    MagnificationGesture()
                        .onChanged { pinch = $0 }
                        .onEnded { _ in
                            zoom = scale
                            pinch = 1
                            offset = clamped(offset, scale: zoom, in: proxy.size)
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { if scale > 1 { drag = $0.translation } }
                        .onEnded { _ in
                            offset = clamped(CGSize(width: offset.width + drag.width, height: offset.height + drag.height), scale: scale, in: proxy.size)
                            drag = .zero
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        zoom = 1
                        offset = .zero
                    }
                }
        }
        .clipped()
    }

    /// Keeps the enlarged picture from sliding off its frame.
    private func clamped(_ offset: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let limitX = size.width * (scale - 1) / 2, limitY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(offset.width, -limitX), limitX), height: min(max(offset.height, -limitY), limitY))
    }
}
