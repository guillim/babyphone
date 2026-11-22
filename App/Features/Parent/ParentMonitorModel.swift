@preconcurrency import AVFoundation
import BabyphoneCore
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
    @Published private(set) var isAlarmSounding = false
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
    private static let journalWindow: TimeInterval = 7 * 24 * 3600
    private static let lowVolume: Float = 0.1

    private let key: PairingKey
    private let journal: JournalStore
    private let healthLog: HealthLog
    private let media: ParentMedia
    private let audio = ParentAudio()
    private let network = NetworkStatus()

    private var connector: ParentConnector?
    private var tasks: [Task<Void, Never>] = []
    private var pendingAlarm: Task<Void, Never>?
    private var hasRecordedLoss = false
    private var lastHealthSample = Date.distantPast

    init(key: PairingKey, database: AppDatabase, media: MediaEngine) {
        self.key = key
        journal = JournalStore(database: database, role: .parent)
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
        await AlertNotifier.requestAuthorization()
        try? AudioSessionController.activate(.listening)
        audio.start()
        DeviceHealth.startMonitoring()
        network.start { [weak self] in
            Task { @MainActor [weak self] in self?.networkDidChange() }
        }

        let connector = ParentConnector(
            makeSession: media.sessionFactory,
            local: BonjourSignalingConnector(key: key),
            rendezvous: RendezvousClient(provider: CloudKitRendezvous(), key: key, role: .parent)
        )
        self.connector = connector
        tasks = [
            Task { [weak self] in
                for await state in connector.states { await self?.connectionDidChange(to: state) }
            },
            Task { [weak self] in
                for await payload in connector.payloads { await self?.handle(payload) }
            },
            Task { [weak self] in
                repeat { await self?.housekeeping() } while (try? await Task.sleep(for: Self.housekeepingInterval)) != nil
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
        setTalking(false)
        await connector?.stop()
        connector = nil
        network.stop()
        audio.stop()
        AudioSessionController.deactivate()
        AlertNotifier.clear()
        connection = .idle
        videoTrack = nil
        status = nil
        noiseAlert = nil
        isAlarmSounding = false
        hasRecordedLoss = false
    }

    func retry() {
        didBabyStop = false
        Task { await connector?.retryNow() }
    }

    func silenceAlarm() {
        isAlarmSounding = false
        audio.setAlarmSounding(false)
    }

    func dismissNoiseAlert() {
        noiseAlert = nil
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
            AudioSessionController.switchTo(.listening)
            send(.talking(false))
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            self.isTalking = true
            AudioSessionController.switchTo(.talking)
            media.setTalking(true)
            send(.talking(true))
        case .notDetermined:
            // The first press only asks for the permission. Talking starts on the next one.
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        default:
            isMicrophoneDenied = true
        }
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
        } else if wasConnected {
            videoTrack = nil
            if isTalking { setTalking(false) }
            scheduleAlarm(lostAt: Date())
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
        case .journal(let received):
            try? await journal.merge(received)
            await reloadJournal()
            if let noise = received.last(where: { $0.kind == .noise && $0.duration == nil }) {
                raiseNoiseAlert(for: noise)
            }
        case .stopping:
            didBabyStop = true
            pendingAlarm?.cancel()
        }
    }

    private func raiseNoiseAlert(for event: JournalEvent) {
        noiseAlert = event
        if DeviceHealth.isInBackground {
            AlertNotifier.notifyNoise()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
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
