@preconcurrency import AVFoundation
import BabyphoneCore
import BabyphoneTransport
import UIKit
@preconcurrency import WebRTC

/// The parent unit: keeps the link to the baby unit, shows what it reports and raises alerts.
@MainActor
final class ParentMonitorModel: ObservableObject {
    @Published private(set) var isMonitoring = false
    @Published private(set) var connection = ParentConnector.State.idle
    /// Latest report from the baby unit. Kept after a disconnection so the screen does not go blank.
    @Published private(set) var status: MonitorStatus?
    @Published private(set) var videoTrack: RTCVideoTrack?
    @Published private(set) var events: [JournalEvent] = []
    /// Set while the "noise in the room" banner is showing.
    @Published private(set) var noiseAlert: JournalEvent?
    /// Set while the "baby is crying" banner is showing.
    @Published private(set) var cryAlert: JournalEvent?
    /// This parent's choices about alerts: how loud, about what, and whether they are paused.
    @Published private(set) var alertPolicy = AlertPolicy()
    /// The fallback through iCloud, used while no direct link exists.
    @Published private(set) var relay = AlertWatch.State.off
    /// What the baby unit last left in iCloud. Kept while the fallback runs.
    @Published private(set) var relayDigest: AlertDigest?
    /// Set while the banner about the baby unit's power is showing: unplugged, or battery low.
    @Published private(set) var powerAlert: JournalEvent.Kind?
    @Published private(set) var isAlarmSounding = false
    /// When the baby unit last reported its status.
    @Published private(set) var lastSignal: Date?
    /// The baby unit's monitoring was stopped on purpose, on the baby unit.
    @Published private(set) var didBabyStop = false
    @Published private(set) var isTalking = false
    @Published private(set) var isMicrophoneDenied = false
    @Published private(set) var isVolumeLow = false
    /// No iCloud account on this phone: monitoring works on the local network only.
    @Published private(set) var isRemoteAccessMissing = false
    @Published private(set) var networkKind = NetworkStatus.Kind.offline

    /// How long the link may stay down before the alarm sounds. Short drops,
    /// such as a phone switching from Wi-Fi to 4G, heal within this time.
    private static let alarmGrace: Duration = .seconds(10)
    private static let housekeepingInterval: Duration = .seconds(30)
    /// An event older than this is history being synced, not something happening now.
    private static let alertFreshness: TimeInterval = 60
    /// The same, for events that come through iCloud, which takes its time.
    private static let relayedAlertFreshness: TimeInterval = 300
    private static let streamCheckInterval: Duration = .seconds(5)
    /// Checks in a row without a new frame before the stream counts as frozen.
    private static let frozenChecks = 3
    private static let journalWindow: TimeInterval = 7 * 24 * 3600
    private static let lowVolume: Float = 0.1

    private let key: PairingKey
    private let journal: JournalStore
    private let settings: SettingsStore
    private let healthLog: HealthLog
    private let media: ParentMedia
    private let audio: ParentAudio
    private let network = NetworkStatus()

    private var connector: ParentConnector?
    private var alertWatch: AlertWatch?
    private var tasks: [Task<Void, Never>] = []
    private var pendingAlarm: Task<Void, Never>?
    private var snoozeEnd: Task<Void, Never>?
    /// Events that already raised an alert. One that is still going on comes back with every update.
    private var alertedEvents: Set<UUID> = []
    private var hasRecordedLoss = false
    private var lastHealthSample = Date.distantPast
    private var lastFrameCount: Int?
    private var checksWithoutFrames = 0

    init(key: PairingKey, database: AppDatabase, media: MediaEngine, audio: ParentAudio) {
        self.key = key
        self.audio = audio
        journal = JournalStore(database: database, role: .parent)
        settings = SettingsStore(database: database)
        healthLog = HealthLog(database: database)
        self.media = ParentMedia(engine: media)
    }

    var isConnected: Bool {
        if case .connected = connection { true } else { false }
    }

    /// Reads the addresses of the connection in use, for the diagnostics screen.
    var currentPath: () async -> WebRTCSession.Path? {
        { [media] in await media.session?.selectedPath() }
    }

    // MARK: Monitoring

    func start() async {
        guard !isMonitoring else { return }
        isMonitoring = true
        didBabyStop = false
        await reloadJournal()
        await loadAlertChoices()
        await AlertNotifier.requestAuthorization()
        // Asked up front, so the first press of the talk button works at once.
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        audio.start()
        DeviceHealth.startMonitoring()
        network.start { [weak self] in
            Task { @MainActor [weak self] in self?.networkDidChange() }
        }

        let rendezvous = RendezvousClient(provider: CloudKitRendezvous(), key: key, role: .parent)
        let connector = ParentConnector(
            makeSession: media.sessionFactory,
            local: BonjourSignalingConnector(key: key),
            rendezvous: rendezvous
        )
        self.connector = connector
        let alertWatch = AlertWatch(rendezvous: rendezvous)
        self.alertWatch = alertWatch
        tasks = [
            Task { [weak self] in
                for await state in alertWatch.states { self?.relay = state }
            },
            Task { [weak self] in
                for await digest in alertWatch.digests { await self?.handle(digest) }
            },
            Task { [weak self] in
                for await state in connector.states { await self?.connectionDidChange(to: state) }
            },
            Task { [weak self] in
                for await payload in connector.payloads { await self?.handle(payload) }
            },
            Task { [weak self] in
                repeat { await self?.housekeeping() } while (try? await Task.sleep(for: Self.housekeepingInterval)) != nil
            },
            Task { [weak self] in
                while (try? await Task.sleep(for: Self.streamCheckInterval)) != nil { await self?.checkStream() }
            },
        ]
        await connector.start()
    }

    func stop() async {
        guard isMonitoring else { return }
        isMonitoring = false
        tasks.forEach { $0.cancel() }
        tasks = []
        pendingAlarm?.cancel()
        snoozeEnd?.cancel()
        alertPolicy.resume()
        setTalking(false)
        await connector?.stop()
        connector = nil
        await alertWatch?.stop()
        alertWatch = nil
        relay = .off
        relayDigest = nil
        alertedEvents = []
        network.stop()
        audio.stop()
        AlertNotifier.clear()
        connection = .idle
        videoTrack = nil
        status = nil
        noiseAlert = nil
        cryAlert = nil
        powerAlert = nil
        lastSignal = nil
        isAlarmSounding = false
        hasRecordedLoss = false
    }

    func retry() {
        didBabyStop = false
        Task { await connector?.retryNow() }
    }

    /// Drops the link and connects again from scratch.
    func reconnect() {
        Task { await connector?.reconnect() }
    }

    func silenceAlarm() {
        isAlarmSounding = false
        audio.setAlarmSounding(false)
    }

    func dismissNoiseAlert() {
        noiseAlert = nil
        cryAlert = nil
    }

    // MARK: Alert choices

    func setAlertTrigger(_ trigger: AlertTrigger) {
        alertPolicy.trigger = trigger
        Task { try? await settings.set(trigger.rawValue, for: .alertTrigger) }
    }

    /// Pauses the sound of noise and cry alerts. A lost link and a power problem still ring.
    func snoozeAlerts(minutes: Int) {
        alertPolicy.snooze(minutes: minutes, from: Date())
        snoozeEnd?.cancel()
        snoozeEnd = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(minutes * 60))) != nil else { return }
            self?.alertPolicy.resume()
        }
    }

    func resumeAlerts() {
        snoozeEnd?.cancel()
        alertPolicy.resume()
    }

    private func loadAlertChoices() async {
        if let stored = try? await settings.string(for: .alertTrigger), let trigger = AlertTrigger(rawValue: stored) {
            alertPolicy.trigger = trigger
        }
    }

    func dismissPowerAlert() {
        powerAlert = nil
    }

    // MARK: Controls

    func toggleNightLight() {
        guard let status else { return }
        send(.setNightLight(!status.isNightLightOn))
    }

    func toggleLullaby() {
        guard let status else { return }
        send(.setLullaby(!status.isLullabyPlaying))
    }

    func toggleVideo() {
        guard let status else { return }
        send(.setVideoEnabled(!status.isVideoEnabled))
    }

    func toggleLowLight() {
        guard let status else { return }
        send(.setLowLight(!status.isLowLightOn))
    }

    /// Plays white noise in the room for `minutes`, or stops it when nil.
    func setWhiteNoise(minutes: Int?) {
        send(.setWhiteNoise(minutes: minutes))
    }

    func setSensitivity(_ sensitivity: Sensitivity) {
        status?.sensitivity = sensitivity
        send(.setSensitivity(sensitivity))
    }

    /// Hold-to-talk: sends the parent's voice to the baby unit for as long as `isTalking` is true.
    func setTalking(_ isTalking: Bool) {
        guard isTalking != self.isTalking, isConnected || !isTalking else { return }
        guard isTalking else {
            self.isTalking = false
            media.setTalking(false)
            audio.setTalking(false)
            send(.talking(false))
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            isMicrophoneDenied = true
            return
        }
        self.isTalking = true
        audio.setTalking(true)
        media.setTalking(true)
        send(.talking(true))
    }

    func acknowledgeMicrophoneDenied() {
        isMicrophoneDenied = false
    }

    // MARK: Link

    private func connectionDidChange(to state: ParentConnector.State) async {
        let wasConnected = isConnected
        connection = state

        if case .connected = state {
            didBabyStop = false
            videoTrack = media.session?.remoteVideoTrack
            pendingAlarm?.cancel()
            silenceAlarm()
            if hasRecordedLoss {
                hasRecordedLoss = false
                await record(.linkRestored)
            }
            send(.hello(lastJournalRevision: (try? await journal.latestRevision(from: .baby)) ?? 0))
            AlertNotifier.postponeWatchdog()
            // The link carries everything: the fallback through iCloud rests.
            await alertWatch?.stop()
            relayDigest = nil
        } else if wasConnected {
            videoTrack = nil
            if isTalking { setTalking(false) }
            scheduleAlarm(lostAt: Date())
        }
        if case .unreachable = state {
            // No direct link could be made: alerts may still arrive through iCloud.
            await alertWatch?.start()
        }
    }

    private func scheduleAlarm(lostAt: Date) {
        guard !didBabyStop else { return }
        pendingAlarm?.cancel()
        pendingAlarm = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.alarmGrace)) != nil else { return }
            await self?.raiseAlarm(lostAt: lostAt)
        }
    }

    private func raiseAlarm(lostAt: Date) async {
        guard isMonitoring, !isConnected, !didBabyStop else { return }
        hasRecordedLoss = true
        isAlarmSounding = true
        audio.setAlarmSounding(true)
        AlertNotifier.notifyLinkLost()
        await record(.linkLost, at: lostAt)
    }

    private func handle(_ payload: Data) async {
        guard let message = try? WireCoding.decode(BabyMessage.self, from: payload) else { return }
        switch message {
        case .status(let newStatus):
            status = newStatus
            lastSignal = Date()
        case .journal(let received):
            try? await journal.merge(received)
            await reloadJournal()
            raiseAlerts(for: received, freshness: Self.alertFreshness)
        case .stopping:
            didBabyStop = true
            pendingAlarm?.cancel()
        }
    }

    /// Takes what the baby unit left in iCloud while no direct link exists.
    private func handle(_ digest: AlertDigest) async {
        guard isMonitoring, !isConnected else { return }
        relayDigest = digest
        try? await journal.merge(digest.events)
        await reloadJournal()
        raiseAlerts(for: digest.events, freshness: Self.relayedAlertFreshness)
    }

    /// Alerts about what is happening now. Older events are history catching up after a
    /// reconnection, and an event that already raised its alert does not raise it twice.
    private func raiseAlerts(for events: [JournalEvent], freshness: TimeInterval) {
        let news = events.filter { Date().timeIntervalSince($0.date) < freshness && !alertedEvents.contains($0.id) }
        let isCryDetectionActive = status?.isCryDetectionActive ?? relayDigest?.status?.isCryDetectionActive ?? false
        if let cry = news.last(where: { $0.kind == .cry && $0.duration == nil }) {
            alertedEvents.insert(cry.id)
            cryAlert = cry
            ring(.cry, notification: AlertNotifier.notifyCry)
        }
        if let noise = news.last(where: { $0.kind == .noise && $0.duration == nil }) {
            alertedEvents.insert(noise.id)
            if alertPolicy.shows(.noise, isCryDetectionActive: isCryDetectionActive) {
                noiseAlert = noise
                ring(.noise, notification: AlertNotifier.notifyNoise)
            }
        }
        if let power = news.last(where: { $0.kind == .unplugged || $0.kind == .batteryLow }) {
            alertedEvents.insert(power.id)
            powerAlert = power.kind
            let title = power.kind == .unplugged ? String(localized: "parent.power.unplugged") : String(localized: "parent.power.low")
            ring(.power) { AlertNotifier.notifyPower(title: title) }
        }
    }

    /// Makes the sound of an alert, unless the parent paused it.
    private func ring(_ kind: AlertKind, notification: () -> Void) {
        let isCryDetectionActive = status?.isCryDetectionActive ?? relayDigest?.status?.isCryDetectionActive ?? false
        guard alertPolicy.rings(kind, at: Date(), isCryDetectionActive: isCryDetectionActive) else { return }
        // The chime plays through the app's own audio, so it is heard on silent and in a Focus mode.
        audio.playChime()
        if DeviceHealth.isInBackground {
            notification()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    /// A link can stay up while the picture stops arriving. Frames that no longer
    /// come in while the baby unit says it is filming mean a frozen stream: reconnect.
    private func checkStream() async {
        guard isConnected, status?.isVideoEnabled == true, let frames = await media.session?.decodedVideoFrameCount() else {
            lastFrameCount = nil
            checksWithoutFrames = 0
            return
        }
        checksWithoutFrames = frames == lastFrameCount ? checksWithoutFrames + 1 : 0
        lastFrameCount = frames
        if checksWithoutFrames >= Self.frozenChecks {
            checksWithoutFrames = 0
            lastFrameCount = nil
            await connector?.reconnect()
        }
    }

    private func send(_ message: ParentMessage) {
        guard let payload = try? WireCoding.encode(message) else { return }
        Task { await connector?.send(payload) }
    }

    // MARK: Journal and upkeep

    private func record(_ kind: JournalEvent.Kind, at date: Date = Date()) async {
        _ = try? await journal.record(kind, at: date)
        await reloadJournal()
    }

    private func reloadJournal() async {
        let since = Date().addingTimeInterval(-Self.journalWindow)
        events = (try? await journal.events(since: since)) ?? []
    }

    private func networkDidChange() {
        networkKind = network.kind
    }

    private func housekeeping() async {
        isVolumeLow = AVAudioSession.sharedInstance().outputVolume < Self.lowVolume
        isRemoteAccessMissing = await CloudKitRendezvous().availability() == .noAccount
        if isConnected {
            AlertNotifier.postponeWatchdog()
        }
        guard Date().timeIntervalSince(lastHealthSample) >= 60 else { return }
        lastHealthSample = Date()
        let linkLabel: String
        switch connection {
        case .connected(let route): linkLabel = route.rawValue
        case .unreachable: linkLabel = "unreachable"
        default: linkLabel = "connecting"
        }
        try? await healthLog.append(HealthSample(
            role: .parent,
            batteryLevel: DeviceHealth.batteryLevel,
            isCharging: DeviceHealth.isCharging,
            thermal: DeviceHealth.thermal,
            link: linkLabel,
            isInBackground: DeviceHealth.isInBackground
        ))
        try? await journal.prune()
    }
}
