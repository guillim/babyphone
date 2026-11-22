@preconcurrency import AVFoundation
import SoundAnalysis

/// Listens for crying in the room's sound with the classifier that ships in iOS.
///
/// Everything happens on the device. The classifier knows a few hundred
/// sounds; this type only keeps how confident it is that one of them is crying.
/// What counts as a cry over time is decided elsewhere, in `CryDetector`.
final class CryClassifier: NSObject, SNResultsObserving, @unchecked Sendable {
    /// Called a few times a second with a confidence from 0 to 1, on the classifier's queue.
    var onConfidence: (@Sendable (Double) -> Void)?

    /// The analyzer is not safe to share: every use of it goes through this queue.
    private let queue = DispatchQueue(label: "nuzzlecam.cry-classifier")
    // Only touched on `queue`.
    private var analyzer: SNAudioStreamAnalyzer?
    private var labels: [String] = []
    private let lock = NSLock()
    private var active = false

    /// Whether the classifier is running. False on a device or a simulator that does not have it.
    var isActive: Bool { lock.withLock { active } }

    /// Starts classifying sound of this format, replacing any earlier run.
    func start(format: AVAudioFormat) {
        queue.async { [self] in
            analyzer = nil
            var isRunning = false
            defer { lock.withLock { active = isRunning } }
            guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return }
            // The names are read from the classifier rather than assumed: "baby_crying", "crying_sobbing".
            labels = request.knownClassifications.filter { $0.contains("cry") }
            guard !labels.isEmpty else { return }
            request.overlapFactor = 0.75
            let analyzer = SNAudioStreamAnalyzer(format: format)
            guard (try? analyzer.add(request, withObserver: self)) != nil else { return }
            self.analyzer = analyzer
            isRunning = true
        }
    }

    func stop() {
        queue.async { [self] in
            analyzer = nil
            lock.withLock { active = false }
        }
    }

    /// Hands over one buffer from the microphone. Call from the audio tap.
    func analyze(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        queue.async { [self] in
            analyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
        }
    }

    // MARK: SNResultsObserving

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = labels.compactMap { result.classification(forIdentifier: $0)?.confidence }.max() ?? 0
        onConfidence?(confidence)
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        lock.withLock { active = false }
    }
}
