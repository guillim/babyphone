@preconcurrency import AVFoundation
import BabyphoneCore
import BabyphoneTransport
import UIKit

/// The baby unit: listens to the room, hosts the connection of each parent unit and keeps the journal.
@MainActor
final class BabyMonitorModel: ObservableObject {
    enum StartFailure: Equatable {
        /// Without the microphone there is nothing to monitor.
        case microphoneDenied
        case audioUnavailable
    }

    /// How the night light is produced: by whichever side of the device faces the baby.
    enum NightLight: Equatable {
        case off
        /// The front camera is in use, so the screen faces the baby.
        case screen
        /// The rear camera is in use, so the torch faces the baby.
        case torch
    }

    /// One paired parent unit, with its own key, its own connection and its own choices.
    @MainActor
    private final class Parent {
        let key: PairingKey
        let media: BabyPeerMedia
        var host: BabyHost?
        /// Leaves this parent the latest alerts in iCloud, for when it has no direct link.
        var beacon: AlertBeacon?
        var link = BabyHost.State.stopped
        var remoteAccess = BabyHost.RemoteAccess.disabled
        /// This parent asked for sound only. The other parent's picture is not affected.
        var wantsVideo = true
        var isTalking = false
        private var pendingSilence: Task<Void, Never>?

        init(key: PairingKey, media: BabyPeerMedia) {
            self.key = key
            self.media = media
        }

        var route: LinkRoute? {
            if case .connected(let route) = link { route } else { nil }
        }

        /// Plays this parent's voice while they hold the talk button. On release the
        /// speaker stays open a moment longer, for the words still on their way.
        func setTalking(_ isTalking: Bool, immediately: Bool = false) {
            self.isTalking = isTalking
            pendingSilence?.cancel()
            pendingSilence = nil
            if isTalking || immediately {
                media.setPlayingParentVoice(isTalking)
                return
            }
            pendingSilence = Task { [media] in
                guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
                media.setPlayingParentVoice(false)
            }
        }
    }

    @Published private(set) var isMonitoring = false
    @Published private(set) var startFailure: StartFailure?
    /// How each connected parent unit reaches this device. Empty while none is connected.
    @Published private(set) var connectedRoutes: [LinkRoute] = []
    @Published private(set) var remoteAccess = BabyHost.RemoteAccess.disabled
    /// Sound level in the room, from 0 to 1.
    @Published private(set) var soundLevel = 0.0
    @Published private(set) var batteryLevel: Double?
    @Published private(set) var isCharging = false
    @Published private(set) var isCameraRunning = false
    @Published private(set) var isCameraAllowed = true
    @Published private(set) var nightLight = NightLight.off
    @Published private(set) var isLullabyPlaying = false
    @Published private(set) var isScreenDimmed = false
    @Published private(set) var roomName = ""
    @Published private(set) var usesFrontCamera = false

    /// The keys of the paired parent units, in pairing order.
    var parentKeys: [PairingKey] { parents.map(\.key) }

    /// Seconds without a touch before the screen dims.
    static let dimDelay: Duration = .seconds(10)
    private static let statusInterval: Duration = .milliseconds(250)
    private static let healthInterval: Duration = .seconds(60)
    private static let journalBatchSize = 100

    private let parents: [Parent]
    private let settings: SettingsStore
    private let journal: JournalStore
    private let healthLog: HealthLog
    private let media: BabyMedia
    private let roomAudio = RoomAudio()
    private let roomLight = RoomLight()
    private let network = NetworkStatus()
    /// Asks the home router for a port, so a parent unit away from home can reach this
    /// device over IPv4. Shared by the connections of every parent unit.
    private let portMapper = RouterPortMapper(label: AppInfo.name)

    private var detector = NoiseDetector(sensitivity: .medium)
    private var cryDetector = CryDetector()
    private var powerWatch = PowerWatch()
    private var noiseEvent: JournalEvent?
    private var cryEvent: JournalEvent?
    private var whiteNoiseEndsAt: Date?
    private var whiteNoiseTimer: Task<Void, Never>?
    private var isLowLightOn = false
    private var isInBackground = false
    private var tasks: [Task<Void, Never>] = []
    private var lifecycleObservers: [any NSObjectProtocol] = []
    private var dimming: Task<Void, Never>?

    init(keys: [PairingKey], database: AppDatabase, media: MediaEngine) {
        let babyMedia = BabyMedia(engine: media)
        self.media = babyMedia
        parents = keys.map { Parent(key: $0, media: babyMedia.makePeer()) }
        settings = SettingsStore(database: database)
        journal = JournalStore(database: database, role: .baby)
        healthLog = HealthLog(database: database)
    }

    func loadSettings() async {
        roomName = (try? await settings.string(for: .roomName)) ?? String(localized: "baby.defaultRoomName")
        usesFrontCamera = (try? await settings.string(for: .usesFrontCamera)) == "1"
        if let stored = try? await settings.string(for: .sensitivity), let sensitivity = Sensitivity(rawValue: stored) {
            detector.sensitivity = sensitivity
        }
    }

    func setRoomName(_ name: String) {
        roomName = name
        Task { try? await settings.set(name, for: .roomName) }
    }

    func setUsesFrontCamera(_ usesFront: Bool) {
        guard usesFront != usesFrontCamera else { return }
        usesFrontCamera = usesFront
        Task { try? await settings.set(usesFront ? "1" : "0", for: .usesFrontCamera) }
        // Stopped first, so that the lamp and the picture start the other camera once between them.
        if isCameraRunning {
            media.stopCamera()
            isCameraRunning = false
        }
        if nightLight != .off {
            setNightLight(false)
            setNightLight(true)
        }
        updateCamera()
    }

    // MARK: Monitoring

    /// Starts monitoring again when the app ended without anyone stopping it:
    /// an iOS update, a restart, the system closing the app in the night.
    func resumeIfInterrupted() async {
        guard (try? await settings.string(for: .isMonitoring)) != nil else { return }
        LinkLog.note("baby unit: monitoring resumes after the app restarted")
        await start()
    }

    func start() async {
        guard !isMonitoring else { return }
        startFailure = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            startFailure = .microphoneDenied
            return
        }
        isCameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
        do {
            try AudioSessionController.activate()
            try roomAudio.start()
        } catch {
            roomAudio.stop()
            AudioSessionController.deactivate()
            startFailure = .audioUnavailable
            return
        }

        isMonitoring = true
        try? await settings.set("1", for: .isMonitoring)
        isInBackground = false
        detector.recalibrate()
        cryDetector = CryDetector()
        powerWatch = PowerWatch()
        UIApplication.shared.isIdleTimerDisabled = true
        DeviceHealth.startMonitoring()
        roomLight.begin()
        registerTouch()
        _ = try? await journal.record(.monitoringStarted)
        try? await journal.prune()

        roomAudio.onLevel = { [weak self] decibels in
            Task { @MainActor [weak self] in self?.ingest(decibels: decibels) }
        }
        roomAudio.onCryConfidence = { [weak self] confidence in
            Task { @MainActor [weak self] in self?.ingest(cryConfidence: confidence) }
        }
        tasks = [
            Task { [weak self] in
                while (try? await Task.sleep(for: Self.statusInterval)) != nil { await self?.tick() }
            },
            Task { [weak self] in
                repeat { await self?.recordHealth() } while (try? await Task.sleep(for: Self.healthInterval)) != nil
            },
        ]
        // Each parent unit gets its own host: its own key, its own listener, its own rendezvous record.
        var hosts: [BabyHost] = []
        for parent in parents {
            parent.wantsVideo = true
            parent.setTalking(false, immediately: true)
            let rendezvous = RendezvousClient(provider: CloudKitRendezvous(), key: parent.key, role: .baby)
            let host = BabyHost(
                makeSession: parent.media.sessionFactory,
                listener: BonjourSignalingListener(key: parent.key),
                rendezvous: rendezvous,
                portMapper: portMapper
            )
            parent.host = host
            parent.beacon = AlertBeacon(rendezvous: rendezvous)
            hosts.append(host)
            tasks += [
                Task { [weak self, weak parent] in
                    for await state in host.states {
                        guard let parent else { return }
                        self?.linkDidChange(to: state, for: parent)
                    }
                },
                Task { [weak self, weak parent] in
                    for await access in host.remoteAccessChanges {
                        parent?.remoteAccess = access
                        self?.updateRemoteAccess()
                    }
                },
                Task { [weak self, weak parent] in
                    for await payload in host.payloads {
                        guard let parent else { return }
                        await self?.handle(payload, from: parent)
                    }
                },
            ]
        }
        network.start { [hosts, portMapper] in
            Task {
                // Another network means another router.
                await portMapper.networkDidChange()
                for host in hosts { await host.networkDidChange() }
            }
        }
        lifecycleObservers = [
            (UIApplication.didEnterBackgroundNotification, true),
            (UIApplication.willEnterForegroundNotification, false),
        ].map { name, isInBackground in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setInBackground(isInBackground) }
            }
        }
        for host in hosts {
            await host.start()
        }
    }

    func stop() async {
        guard isMonitoring else { return }
        isMonitoring = false
        // Every caller is someone stopping on purpose: the app ending never comes through here.
        try? await settings.set(nil, for: .isMonitoring)
        tasks.forEach { $0.cancel() }
        tasks = []
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers = []
        dimming?.cancel()
        whiteNoiseTimer?.cancel()
        network.stop()
        roomAudio.onLevel = nil
        roomAudio.onCryConfidence = nil

        if case .ended(let startedAt, let duration) = detector.finish() {
            await closeNoiseEvent(startedAt: startedAt, duration: duration)
        }
        if case .ended(let startedAt, let duration) = cryDetector.finish() {
            await closeCryEvent(startedAt: startedAt, duration: duration)
        }
        if let stopped = try? await journal.record(.monitoringStopped) {
            await broadcast(.journal([stopped]))
        }
        // Lets the parent units tell a deliberate stop from a lost link: over the link
        // for those that are connected, and through iCloud for those that are not.
        await broadcast(.stopping)
        await relayAlerts(toEveryParent: true)
        try? await Task.sleep(for: .milliseconds(300))

        // The device goes quiet and dark before anything that may wait on the network.
        media.stopCamera()
        isCameraRunning = false
        roomAudio.stop()
        roomLight.end()
        nightLight = .off
        isLullabyPlaying = false
        whiteNoiseEndsAt = nil
        isScreenDimmed = false
        soundLevel = 0
        connectedRoutes = []
        UIApplication.shared.isIdleTimerDisabled = false

        for parent in parents {
            await parent.host?.stop()
            parent.host = nil
            parent.link = .stopped
            await parent.beacon?.flush()
            parent.beacon = nil
        }
        AudioSessionController.deactivate()
    }

    /// Call on any touch: wakes the screen, then dims it again after a while.
    func registerTouch() {
        guard isMonitoring else { return }
        isScreenDimmed = false
        updateScreen()
        dimming?.cancel()
        dimming = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.dimDelay)) != nil else { return }
            self?.isScreenDimmed = true
            self?.updateScreen()
        }
    }

    // MARK: Room

    private func ingest(decibels: Double) {
        guard isMonitoring else { return }
        soundLevel = SoundLevel.normalized(decibels: decibels)
        // The lullaby and the parent's voice change all the time: they must count neither as noise
        // nor as background. White noise is steady, so the detector calibrates to it instead.
        let isMasked = isLullabyPlaying || parents.contains(where: \.isTalking)
        switch detector.ingest(decibels: decibels, at: Date(), isMasked: isMasked) {
        case .none:
            break
        case .started(let date):
            Task {
                guard let event = try? await journal.record(.noise, at: date) else { return }
                noiseEvent = event
                await broadcast(.journal([event]))
                await relayAlerts()
            }
        case .ended(let startedAt, let duration):
            Task { await closeNoiseEvent(startedAt: startedAt, duration: duration) }
        }
    }

    /// Takes one reading from the cry classifier: how confident it is, from 0 to 1.
    private func ingest(cryConfidence: Double) {
        guard isMonitoring else { return }
        switch cryDetector.ingest(confidence: cryConfidence, at: Date()) {
        case nil:
            break
        case .started(let date):
            Task {
                guard let event = try? await journal.record(.cry, at: date) else { return }
                cryEvent = event
                await broadcast(.journal([event]))
                await relayAlerts()
            }
        case .ended(let startedAt, let duration):
            Task { await closeCryEvent(startedAt: startedAt, duration: duration) }
        }
    }

    private func closeCryEvent(startedAt: Date, duration: TimeInterval) async {
        guard let open = cryEvent, open.date == startedAt else { return }
        cryEvent = nil
        if let closed = try? await journal.setDuration(duration, ofEvent: open.id) {
            await broadcast(.journal([closed]))
        }
    }

    private func closeNoiseEvent(startedAt: Date, duration: TimeInterval) async {
        guard let open = noiseEvent, open.date == startedAt else { return }
        noiseEvent = nil
        if let closed = try? await journal.setDuration(duration, ofEvent: open.id) {
            await broadcast(.journal([closed]))
        }
    }

    private func setNightLight(_ isOn: Bool) {
        if !isOn {
            roomLight.setTorch(false)
            nightLight = .off
        } else if usesFrontCamera {
            useScreenAsLamp()
        } else {
            // The torch only lights while the camera runs, so the camera starts first.
            nightLight = .torch
            updateCamera()
            if !roomLight.setTorch(true) { useScreenAsLamp() }
        }
        updateCamera()
        updateScreen()
    }

    private func useScreenAsLamp() {
        nightLight = .screen
        // The screen is the lamp: let it glow at once rather than after the usual delay.
        dimming?.cancel()
        isScreenDimmed = true
    }

    /// Plays white noise for `minutes`, or stops it when nil.
    private func setWhiteNoise(minutes: Int?) {
        whiteNoiseTimer?.cancel()
        whiteNoiseEndsAt = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        roomAudio.setWhiteNoisePlaying(minutes != nil)
        // The room's steady level just changed on purpose: measure it afresh instead of alerting on it.
        detector.recalibrate()
        guard let minutes else { return }
        whiteNoiseTimer = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(minutes * 60))) != nil else { return }
            self?.setWhiteNoise(minutes: nil)
        }
    }

    private func updateScreen() {
        if nightLight == .screen {
            roomLight.setScreen(.nightLight)
        } else {
            roomLight.setScreen(isScreenDimmed ? .dimmed : .normal)
        }
    }

    /// iOS cuts the camera when the device is locked or the app leaves the screen. Sound
    /// keeps flowing, and the parent units are told the picture is off rather than shown a frozen one.
    private func setInBackground(_ isInBackground: Bool) {
        self.isInBackground = isInBackground
        updateCamera()
    }

    /// The camera only runs while a parent unit is watching or the torch is the lamp: it is what heats the device.
    private func updateCamera() {
        let canFilm = isCameraAllowed && !isInBackground
        for parent in parents {
            parent.media.setVideoActive(canFilm && parent.wantsVideo)
        }
        // The lamp is the camera's torch: it stays on while the lamp is on, even with no picture watched.
        let isWanted = canFilm && (nightLight == .torch || parents.contains { $0.route != nil && $0.wantsVideo })
        guard isWanted != isCameraRunning else { return }
        if isWanted {
            isCameraRunning = media.startCamera(position: usesFrontCamera ? .front : .back, lowLight: isLowLightOn) { [weak self] in
                // The camera starts asynchronously, and the torch only takes once it runs.
                Task { @MainActor in
                    guard let self, self.nightLight == .torch, self.isCameraRunning else { return }
                    self.roomLight.setTorch(true)
                }
            }
        } else {
            media.stopCamera()
            isCameraRunning = false
        }
    }

    private func restartCameraIfRunning() {
        guard isCameraRunning else { return }
        media.stopCamera()
        isCameraRunning = false
        updateCamera()
    }

    // MARK: Parent units

    private func linkDidChange(to state: BabyHost.State, for parent: Parent) {
        parent.link = state
        if parent.route == nil {
            parent.setTalking(false, immediately: true)
        }
        connectedRoutes = parents.compactMap(\.route)
        updateCamera()
    }

    /// What the screen shows for remote access: ready as soon as one parent unit can reach this device.
    private func updateRemoteAccess() {
        let reported = parents.map(\.remoteAccess)
        let byPriority: [BabyHost.RemoteAccess] = [.ready, .noAccount, .unavailable]
        remoteAccess = byPriority.first { reported.contains($0) } ?? .disabled
    }

    private func handle(_ payload: Data, from parent: Parent) async {
        guard let message = try? WireCoding.decode(ParentMessage.self, from: payload) else { return }
        switch message {
        case .hello(let lastJournalRevision):
            await sendJournal(after: lastJournalRevision, to: parent)
        case .setNightLight(let isOn):
            setNightLight(isOn)
        case .setLullaby(let isPlaying):
            isLullabyPlaying = isPlaying
            roomAudio.setLullabyPlaying(isPlaying)
        case .setWhiteNoise(let minutes):
            setWhiteNoise(minutes: minutes)
        case .setLowLight(let isOn):
            isLowLightOn = isOn
            restartCameraIfRunning()
        case .setVideoEnabled(let isEnabled):
            parent.wantsVideo = isEnabled
            updateCamera()
        case .setSensitivity(let sensitivity):
            detector.sensitivity = sensitivity
            try? await settings.set(sensitivity.rawValue, for: .sensitivity)
        case .talking(let isTalking):
            parent.setTalking(isTalking)
        }
    }

    private func sendJournal(after revision: Int64, to parent: Parent) async {
        guard let events = try? await journal.events(from: .baby, afterRevision: revision) else { return }
        for start in stride(from: 0, to: events.count, by: Self.journalBatchSize) {
            await send(.journal(Array(events[start..<min(events.count, start + Self.journalBatchSize)])), to: parent)
        }
    }

    /// Runs four times a second: watches the power, and reports to each connected parent unit.
    private func tick() async {
        batteryLevel = DeviceHealth.batteryLevel
        isCharging = DeviceHealth.isCharging
        for event in powerWatch.ingest(batteryLevel: batteryLevel, isCharging: isCharging) {
            if let recorded = try? await journal.record(event == .unplugged ? .unplugged : .batteryLow) {
                await broadcast(.journal([recorded]))
                await relayAlerts()
            }
        }
        for parent in parents where parent.route != nil {
            await send(.status(status(for: parent)), to: parent)
        }
    }

    private func status(for parent: Parent) -> MonitorStatus {
        MonitorStatus(
            soundLevel: soundLevel,
            isNoiseActive: detector.isNoiseActive,
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            thermal: DeviceHealth.thermal,
            roomName: roomName,
            sensitivity: detector.sensitivity,
            isVideoEnabled: isCameraRunning && parent.wantsVideo,
            isNightLightOn: nightLight != .off,
            isLullabyPlaying: isLullabyPlaying,
            whiteNoiseEndsAt: whiteNoiseEndsAt,
            isLowLightOn: isLowLightOn,
            isCryDetectionActive: roomAudio.isCryDetectionActive,
            isCrying: cryDetector.isCrying
        )
    }

    /// Leaves the latest state and events in iCloud for the parent units that have no direct
    /// link, so an alert can still reach them. It is a fallback with no guarantee: see `AlertDigest`.
    private func relayAlerts(toEveryParent: Bool = false) async {
        let waiting = parents.filter { $0.remoteAccess == .ready && (toEveryParent || $0.route == nil) }
        guard !waiting.isEmpty else { return }
        let since = Date().addingTimeInterval(-AlertDigest.eventWindow)
        let events = ((try? await journal.events(since: since)) ?? []).filter { $0.origin == .baby }
        for parent in waiting {
            await parent.beacon?.publish(isMonitoring: isMonitoring, status: status(for: parent), events: events)
        }
    }

    private func send(_ message: BabyMessage, to parent: Parent) async {
        guard let payload = try? WireCoding.encode(message) else { return }
        await parent.host?.send(payload)
    }

    private func broadcast(_ message: BabyMessage) async {
        for parent in parents {
            await send(message, to: parent)
        }
    }

    /// Runs once a minute: the health log, and the sign of life left in iCloud.
    private func recordHealth() async {
        await relayAlerts()
        let linkLabel = connectedRoutes.isEmpty ? "waiting" : connectedRoutes.map(\.rawValue).joined(separator: "+")
        try? await healthLog.append(HealthSample(
            role: .baby,
            batteryLevel: DeviceHealth.batteryLevel,
            isCharging: DeviceHealth.isCharging,
            thermal: DeviceHealth.thermal,
            link: linkLabel,
            isInBackground: DeviceHealth.isInBackground
        ))
    }
}
