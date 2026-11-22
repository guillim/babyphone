@preconcurrency import AVFoundation
import BabyphoneCore
import UIKit

/// The baby unit: listens to the room, hosts the parent unit's connection and keeps the journal.
@MainActor
final class BabyMonitorModel: ObservableObject {
    enum StartFailure: Equatable {
        /// Without the microphone there is nothing to monitor.
        case microphoneDenied
        case audioUnavailable
    }

    /// How the night light is produced: by whichever side of the phone faces the baby.
    enum NightLight: Equatable {
        case off
        /// The front camera is in use, so the screen faces the baby.
        case screen
        /// The rear camera is in use, so the torch faces the baby.
        case torch
    }

    @Published private(set) var isMonitoring = false
    @Published private(set) var startFailure: StartFailure?
    @Published private(set) var link = BabyHost.State.stopped
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

    /// Seconds without a touch before the screen dims.
    static let dimDelay: Duration = .seconds(10)
    private static let statusInterval: Duration = .milliseconds(250)
    private static let healthInterval: Duration = .seconds(60)
    private static let journalBatchSize = 100

    private let key: PairingKey
    private let settings: SettingsStore
    private let journal: JournalStore
    private let healthLog: HealthLog
    private let media: BabyMedia
    private let roomAudio = RoomAudio()
    private let roomLight = RoomLight()
    private let network = NetworkStatus()

    private var host: BabyHost?
    private var detector = NoiseDetector(sensitivity: .medium)
    private var noiseEvent: JournalEvent?
    private var isVideoRequested = true
    private var isParentTalking = false
    private var tasks: [Task<Void, Never>] = []
    private var dimming: Task<Void, Never>?

    init(key: PairingKey, database: AppDatabase, media: MediaEngine) {
        self.key = key
        settings = SettingsStore(database: database)
        journal = JournalStore(database: database, role: .baby)
        healthLog = HealthLog(database: database)
        self.media = BabyMedia(engine: media)
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
        if nightLight != .off {
            setNightLight(false)
            setNightLight(true)
        }
        if isCameraRunning {
            media.stopCamera()
            isCameraRunning = false
            updateCamera()
        }
    }

    // MARK: Monitoring

    func start() async {
        guard !isMonitoring else { return }
        startFailure = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            startFailure = .microphoneDenied
            return
        }
        isCameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
        do {
            try AudioSessionController.activate(.room)
            try roomAudio.start()
        } catch {
            roomAudio.stop()
            AudioSessionController.deactivate()
            startFailure = .audioUnavailable
            return
        }

        isMonitoring = true
        isVideoRequested = true
        UIApplication.shared.isIdleTimerDisabled = true
        DeviceHealth.startMonitoring()
        roomLight.begin()
        registerTouch()
        _ = try? await journal.record(.monitoringStarted)
        try? await journal.prune()

        let host = BabyHost(
            makeSession: media.sessionFactory,
            listener: BonjourSignalingListener(key: key),
            rendezvous: RendezvousClient(provider: CloudKitRendezvous(), key: key, role: .baby)
        )
        self.host = host
        roomAudio.onLevel = { [weak self] decibels in
            Task { @MainActor in self?.ingest(decibels: decibels) }
        }
        network.start { [weak host] in
            Task { await host?.networkDidChange() }
        }
        tasks = [
            Task { [weak self] in
                for await state in host.states { self?.linkDidChange(to: state) }
            },
            Task { [weak self] in
                for await access in host.remoteAccessChanges { self?.remoteAccess = access }
            },
            Task { [weak self] in
                for await payload in host.payloads { await self?.handle(payload) }
            },
            Task { [weak self] in
                while (try? await Task.sleep(for: Self.statusInterval)) != nil { await self?.sendStatus() }
            },
            Task { [weak self] in
                repeat { await self?.recordHealth() } while (try? await Task.sleep(for: Self.healthInterval)) != nil
            },
        ]
        await host.start()
    }

    func stop() async {
        guard isMonitoring else { return }
        isMonitoring = false
        tasks.forEach { $0.cancel() }
        tasks = []
        dimming?.cancel()
        network.stop()
        roomAudio.onLevel = nil

        if case .ended(let startedAt, let duration) = detector.finish() {
            await closeNoiseEvent(startedAt: startedAt, duration: duration)
        }
        if let stopped = try? await journal.record(.monitoringStopped) {
            await send(.journal([stopped]))
        }
        // Lets the parent unit tell a deliberate stop from a lost link.
        await send(.stopping)
        try? await Task.sleep(for: .milliseconds(300))
        await host?.stop()
        host = nil

        media.stopCamera()
        isCameraRunning = false
        roomAudio.stop()
        AudioSessionController.deactivate()
        roomLight.end()
        nightLight = .off
        isLullabyPlaying = false
        isScreenDimmed = false
        soundLevel = 0
        link = .stopped
        UIApplication.shared.isIdleTimerDisabled = false
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
        // The phone's own speaker must not count as noise from the room.
        let isMasked = isLullabyPlaying || isParentTalking
        switch detector.ingest(decibels: decibels, at: Date(), isMasked: isMasked) {
        case .none:
            break
        case .started(let date):
            Task {
                guard let event = try? await journal.record(.noise, at: date) else { return }
                noiseEvent = event
                await send(.journal([event]))
            }
        case .ended(let startedAt, let duration):
            Task { await closeNoiseEvent(startedAt: startedAt, duration: duration) }
        }
    }

    private func closeNoiseEvent(startedAt: Date, duration: TimeInterval) async {
        guard let open = noiseEvent, open.date == startedAt else { return }
        noiseEvent = nil
        if let closed = try? await journal.setDuration(duration, ofEvent: open.id) {
            await send(.journal([closed]))
        }
    }

    private func setNightLight(_ isOn: Bool) {
        if !isOn {
            roomLight.setTorch(false)
            nightLight = .off
        } else if usesFrontCamera || !roomLight.setTorch(true) {
            nightLight = .screen
        } else {
            nightLight = .torch
        }
        updateScreen()
    }

    private func updateScreen() {
        if nightLight == .screen {
            roomLight.setScreen(.nightLight)
        } else {
            roomLight.setScreen(isScreenDimmed ? .dimmed : .normal)
        }
    }

    /// The camera only runs while a parent unit is watching: it is what heats the phone.
    private func updateCamera() {
        let isWanted: Bool
        if case .connected = link { isWanted = isVideoRequested && isCameraAllowed } else { isWanted = false }
        media.setVideoEnabled(isWanted)
        guard isWanted != isCameraRunning else { return }
        if isWanted {
            isCameraRunning = media.startCamera(position: usesFrontCamera ? .front : .back)
        } else {
            media.stopCamera()
            isCameraRunning = false
        }
    }

    // MARK: Parent unit

    private func linkDidChange(to state: BabyHost.State) {
        link = state
        if state == .waiting {
            isParentTalking = false
        }
        updateCamera()
    }

    private func handle(_ payload: Data) async {
        guard let message = try? WireCoding.decode(ParentMessage.self, from: payload) else { return }
        switch message {
        case .hello(let lastJournalRevision):
            await sendJournal(after: lastJournalRevision)
        case .setNightLight(let isOn):
            setNightLight(isOn)
        case .setLullaby(let isPlaying):
            isLullabyPlaying = isPlaying
            roomAudio.setLullabyPlaying(isPlaying)
        case .setVideoEnabled(let isEnabled):
            isVideoRequested = isEnabled
            updateCamera()
        case .setSensitivity(let sensitivity):
            detector.sensitivity = sensitivity
            try? await settings.set(sensitivity.rawValue, for: .sensitivity)
        case .talking(let isTalking):
            isParentTalking = isTalking
        }
    }

    private func sendJournal(after revision: Int64) async {
        guard let events = try? await journal.events(from: .baby, afterRevision: revision) else { return }
        for start in stride(from: 0, to: events.count, by: Self.journalBatchSize) {
            await send(.journal(Array(events[start..<min(events.count, start + Self.journalBatchSize)])))
        }
    }

    private func sendStatus() async {
        batteryLevel = DeviceHealth.batteryLevel
        isCharging = DeviceHealth.isCharging
        guard case .connected = link else { return }
        await send(.status(MonitorStatus(
            soundLevel: soundLevel,
            isNoiseActive: detector.isNoiseActive,
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            thermal: DeviceHealth.thermal,
            roomName: roomName,
            sensitivity: detector.sensitivity,
            isVideoEnabled: isCameraRunning,
            isNightLightOn: nightLight != .off,
            isLullabyPlaying: isLullabyPlaying
        )))
    }

    private func send(_ message: BabyMessage) async {
        guard let payload = try? WireCoding.encode(message) else { return }
        await host?.send(payload)
    }

    private func recordHealth() async {
        let linkLabel: String
        switch link {
        case .stopped: linkLabel = "stopped"
        case .waiting: linkLabel = "waiting"
        case .connected(let route): linkLabel = route.rawValue
        }
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
