import Foundation
import Testing
import TestSupport
@testable import BabyphoneCore

@Suite(.timeLimit(.minutes(1))) struct MonitoringTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let quiet = -50.0
    private let loud = -20.0

    /// A detector that has already heard the quiet room.
    private func calibratedDetector(_ sensitivity: Sensitivity = .medium) -> NoiseDetector {
        var detector = NoiseDetector(sensitivity: sensitivity)
        _ = detector.ingest(decibels: quiet, at: start.addingTimeInterval(-1))
        return detector
    }

    @Test func aBriefKnockIsNotNoise() {
        var detector = calibratedDetector()
        #expect(detector.ingest(decibels: loud, at: start) == .none)
        #expect(detector.ingest(decibels: quiet, at: start.addingTimeInterval(0.1)) == .none)
        #expect(detector.ingest(decibels: loud, at: start.addingTimeInterval(1)) == .none)
        #expect(!detector.isNoiseActive)
    }

    @Test func sustainedSoundStartsAnEpisodeAndQuietEndsIt() {
        var detector = calibratedDetector()
        #expect(detector.ingest(decibels: loud, at: start) == .none)
        #expect(detector.ingest(decibels: loud, at: start.addingTimeInterval(0.5)) == .started(at: start))
        #expect(detector.isNoiseActive)

        // A short pause does not end the episode.
        #expect(detector.ingest(decibels: quiet, at: start.addingTimeInterval(2)) == .none)
        #expect(detector.ingest(decibels: loud, at: start.addingTimeInterval(3)) == .none)

        #expect(detector.ingest(decibels: quiet, at: start.addingTimeInterval(5)) == .none)
        #expect(detector.ingest(decibels: quiet, at: start.addingTimeInterval(7.1)) == .ended(startedAt: start, duration: 3))
        #expect(!detector.isNoiseActive)
    }

    @Test func sensitivityDecidesHowFarAboveTheRoomASoundMustRise() {
        let level = quiet + Sensitivity.medium.marginDecibels + 1
        for (sensitivity, expected) in [(Sensitivity.low, false), (.medium, true), (.high, true)] {
            var detector = calibratedDetector(sensitivity)
            _ = detector.ingest(decibels: level, at: start)
            _ = detector.ingest(decibels: level, at: start.addingTimeInterval(1))
            #expect(detector.isNoiseActive == expected)
        }
    }

    @Test func theThresholdFollowsTheRoom() {
        var detector = calibratedDetector()
        #expect(abs(detector.thresholdDecibels - (quiet + Sensitivity.medium.marginDecibels)) < 0.5)

        // A fan is switched on. It is new, so it alerts once, then becomes the background.
        let fan = -30.0
        var episodes = 0
        var time = start
        for _ in 0..<1200 {
            if case .started = detector.ingest(decibels: fan, at: time) { episodes += 1 }
            time.addTimeInterval(0.5)
        }
        #expect(episodes == 1)
        #expect(!detector.isNoiseActive)
        #expect(abs((detector.ambientDecibels ?? 0) - fan) < 1)

        // Crying over the fan still alerts.
        _ = detector.ingest(decibels: fan + 25, at: time)
        _ = detector.ingest(decibels: fan + 25, at: time.addingTimeInterval(0.5))
        #expect(detector.isNoiseActive)
        _ = detector.finish()

        // The fan stops: within seconds the detector is back to the quiet room.
        for step in 1...40 {
            _ = detector.ingest(decibels: quiet, at: time.addingTimeInterval(1 + Double(step) * 0.5))
        }
        #expect(abs((detector.ambientDecibels ?? 0) - quiet) < 1)
    }

    @Test func theThresholdStaysWithinSaneBounds() {
        var silentRoom = NoiseDetector(sensitivity: .high)
        _ = silentRoom.ingest(decibels: -80, at: start)
        #expect(silentRoom.thresholdDecibels == -55)

        var loudRoom = NoiseDetector(sensitivity: .low)
        _ = loudRoom.ingest(decibels: -15, at: start)
        #expect(loudRoom.thresholdDecibels == -12)
    }

    @Test func soundThePhonePlaysItselfIsIgnored() {
        var detector = calibratedDetector(.high)
        _ = detector.ingest(decibels: loud, at: start, isMasked: true)
        _ = detector.ingest(decibels: loud, at: start.addingTimeInterval(1), isMasked: true)
        #expect(!detector.isNoiseActive)
        // It does not count as background either.
        #expect(detector.ambientDecibels == quiet)
    }

    @Test func recalibrationStartsFromTheNextMeasurement() {
        var detector = calibratedDetector()
        detector.recalibrate()
        #expect(detector.ambientDecibels == nil)
        #expect(detector.ingest(decibels: -32, at: start) == .none)
        #expect(detector.ambientDecibels == -32)
        #expect(!detector.isNoiseActive)
    }

    @Test func finishClosesAnEpisodeInProgress() {
        var detector = calibratedDetector()
        _ = detector.ingest(decibels: loud, at: start)
        _ = detector.ingest(decibels: loud, at: start.addingTimeInterval(2))
        #expect(detector.finish() == .ended(startedAt: start, duration: 2))
        #expect(detector.finish() == .none)
    }

    @Test func powerWatchReportsEachProblemOnce() {
        var watch = PowerWatch()
        #expect(watch.ingest(batteryLevel: 0.8, isCharging: true).isEmpty)
        #expect(watch.ingest(batteryLevel: 0.8, isCharging: false) == [.unplugged])
        #expect(watch.ingest(batteryLevel: 0.5, isCharging: false).isEmpty)
        #expect(watch.ingest(batteryLevel: 0.19, isCharging: false) == [.batteryLow])
        #expect(watch.ingest(batteryLevel: 0.15, isCharging: false).isEmpty)

        // Plugged back in, then pulled out again while still low.
        #expect(watch.ingest(batteryLevel: 0.15, isCharging: true).isEmpty)
        #expect(watch.ingest(batteryLevel: 0.16, isCharging: false) == [.unplugged, .batteryLow])
    }

    @Test func powerWatchIsQuietOnAPhoneThatStartsUnplugged() {
        var watch = PowerWatch()
        #expect(watch.ingest(batteryLevel: 0.9, isCharging: false).isEmpty)
        #expect(watch.ingest(batteryLevel: nil, isCharging: false).isEmpty)
    }

    @Test func levelConversions() {
        let silence = [Float](repeating: 0, count: 480)
        let fullScale = (0..<480).map { Float(sin(Double($0) * 0.3)) }
        #expect(silence.withUnsafeBufferPointer(SoundLevel.decibels) == SoundLevel.floorDecibels)
        let level = fullScale.withUnsafeBufferPointer(SoundLevel.decibels)
        #expect(level > -4 && level < -2)
        #expect(SoundLevel.normalized(decibels: -60) == 0)
        #expect(SoundLevel.normalized(decibels: 0) == 1)
        #expect(SoundLevel.normalized(decibels: -30) == 0.5)
        #expect(SoundLevel.normalized(decibels: 20) == 1)
    }

    @Test func synthesizedSoundsAreAudibleAndDoNotClip() {
        let sounds = [
            ToneSynthesizer.lullaby(sampleRate: 22_050), ToneSynthesizer.alarm(sampleRate: 22_050),
            ToneSynthesizer.chime(sampleRate: 22_050), ToneSynthesizer.whiteNoise(sampleRate: 22_050),
        ]
        for samples in sounds {
            let peak = samples.map(abs).max() ?? 0
            #expect(samples.count > 22_050)
            #expect(peak > 0.2 && peak < 1)
        }
    }

    @Test func whiteNoiseLoopsWithoutAClick() {
        let samples = ToneSynthesizer.whiteNoise(sampleRate: 22_050)
        // From the last sample back to the first, the step is no bigger than between any two neighbours.
        let largestStep = zip(samples, samples.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        #expect(abs(samples[samples.count - 1] - samples[0]) <= largestStep)
        #expect(ToneSynthesizer.whiteNoise(sampleRate: 22_050) == samples)
    }

    @Test func addressScopes() {
        let expectations: [(String, AddressScope)] = [
            ("127.0.0.1", .loopback), ("192.168.1.12", .privateNetwork), ("10.0.0.4", .privateNetwork),
            ("172.20.10.2", .privateNetwork), ("172.32.0.1", .publicIPv4), ("169.254.3.4", .linkLocal),
            ("100.72.1.1", .carrierNAT), ("192.0.0.2", .carrierNAT), ("8.8.8.8", .publicIPv4),
            ("::1", .loopback), ("fe80::1c2b:3aff:fe4d:5e6f%en0", .linkLocal), ("fd12:3456::1", .privateNetwork),
            ("2a01:e0a:123:4560:1c2b:3aff:fe4d:5e6f", .globalIPv6), ("2001:db8::1", .globalIPv6),
            ("garbage", .unknown),
        ]
        for (address, scope) in expectations {
            #expect(AddressScope.of(address) == scope, "\(address)")
        }
    }

    @Test func findsRemotePathInSessionDescription() {
        let localOnly = """
        v=0\r
        a=candidate:1 1 udp 2122260223 192.168.1.20 51234 typ host generation 0\r
        a=candidate:2 1 udp 2122194687 fe80::1 51235 typ host generation 0\r
        """
        let withGlobal = localOnly + "\na=candidate:3 1 udp 2122129151 2a01:e0a:1:2::3 51236 typ host generation 0\r\n"
        #expect(SessionDescriptionInspector.candidateAddresses(in: localOnly) == ["192.168.1.20", "fe80::1"])
        #expect(!SessionDescriptionInspector.offersRemotePath(localOnly))
        #expect(SessionDescriptionInspector.offersRemotePath(withGlobal))
    }
}
