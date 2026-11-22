import Foundation
import Testing
@testable import BabyphoneCore

@Suite struct MonitoringTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let loud = Sensitivity.medium.thresholdDecibels + 10
    private let quiet = Sensitivity.medium.thresholdDecibels - 20

    @Test func aBriefKnockIsNotNoise() {
        var detector = NoiseDetector(sensitivity: .medium)
        #expect(detector.ingest(decibels: loud, at: start) == .none)
        #expect(detector.ingest(decibels: quiet, at: start.addingTimeInterval(0.1)) == .none)
        #expect(detector.ingest(decibels: loud, at: start.addingTimeInterval(1)) == .none)
        #expect(!detector.isNoiseActive)
    }

    @Test func sustainedSoundStartsAnEpisodeAndQuietEndsIt() {
        var detector = NoiseDetector(sensitivity: .medium)
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

    @Test func sensitivityDecidesWhatCountsAsNoise() {
        let level = Sensitivity.medium.thresholdDecibels + 1
        for (sensitivity, expected) in [(Sensitivity.low, false), (.medium, true), (.high, true)] {
            var detector = NoiseDetector(sensitivity: sensitivity)
            _ = detector.ingest(decibels: level, at: start)
            _ = detector.ingest(decibels: level, at: start.addingTimeInterval(1))
            #expect(detector.isNoiseActive == expected)
        }
    }

    @Test func soundThePhonePlaysItselfIsIgnored() {
        var detector = NoiseDetector(sensitivity: .high)
        _ = detector.ingest(decibels: loud, at: start, isMasked: true)
        _ = detector.ingest(decibels: loud, at: start.addingTimeInterval(1), isMasked: true)
        #expect(!detector.isNoiseActive)
    }

    @Test func finishClosesAnEpisodeInProgress() {
        var detector = NoiseDetector(sensitivity: .medium)
        _ = detector.ingest(decibels: loud, at: start)
        _ = detector.ingest(decibels: loud, at: start.addingTimeInterval(2))
        #expect(detector.finish() == .ended(startedAt: start, duration: 2))
        #expect(detector.finish() == .none)
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
        for samples in [ToneSynthesizer.lullaby(sampleRate: 22_050), ToneSynthesizer.alarm(sampleRate: 22_050)] {
            let peak = samples.map(abs).max() ?? 0
            #expect(samples.count > 22_050)
            #expect(peak > 0.2 && peak < 1)
        }
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
