import Foundation

/// Renders the two sounds the app plays without shipping any audio file.
public enum ToneSynthesizer {
    /// A music-box rendition of Brahms' lullaby (public domain), as mono samples that loop cleanly.
    public static func lullaby(sampleRate: Double) -> [Float] {
        let beat = 0.72
        let total = Lullaby.melody.reduce(0) { $0 + $1.beats } * beat
        var samples = [Float](repeating: 0, count: Int(total * sampleRate))
        var start = 0.0
        for note in Lullaby.melody {
            if let semitone = note.semitone {
                // One octave above the written melody, where a music box sits.
                let frequency = 261.63 * pow(2, Double(semitone + 12) / 12)
                addChime(frequency: frequency, at: start, into: &samples, sampleRate: sampleRate)
            }
            start += note.beats * beat
        }
        return samples
    }

    /// A two-tone alarm, as mono samples that loop cleanly.
    public static func alarm(sampleRate: Double) -> [Float] {
        let beepDuration = 0.22
        let pattern: [(frequency: Double?, duration: Double)] = [
            (880, beepDuration), (nil, 0.08), (660, beepDuration), (nil, 0.08),
            (880, beepDuration), (nil, 0.9),
        ]
        var samples: [Float] = []
        for step in pattern {
            let count = Int(step.duration * sampleRate)
            guard let frequency = step.frequency else {
                samples.append(contentsOf: [Float](repeating: 0, count: count))
                continue
            }
            let fade = Int(0.01 * sampleRate)
            for index in 0..<count {
                let envelope = min(1, Double(min(index, count - index)) / Double(fade))
                let value = sin(2 * .pi * frequency * Double(index) / sampleRate)
                samples.append(Float(0.6 * envelope * value))
            }
        }
        return samples
    }

    /// Adds one struck-metal note. Its tail wraps around the end of the buffer so the loop has no gap.
    private static func addChime(frequency: Double, at start: Double, into samples: inout [Float], sampleRate: Double) {
        let ringTime = 2.4
        let decay = 0.55
        let attack = 0.004
        let partials: [(ratio: Double, gain: Double)] = [(1, 1), (2, 0.35), (3, 0.12), (4.2, 0.05)]
        let first = Int(start * sampleRate)
        for offset in 0..<Int(ringTime * sampleRate) {
            let time = Double(offset) / sampleRate
            let envelope = min(1, time / attack) * exp(-time / decay)
            var value = 0.0
            for partial in partials {
                value += partial.gain * sin(2 * .pi * frequency * partial.ratio * time)
            }
            samples[(first + offset) % samples.count] += Float(0.16 * envelope * value)
        }
    }
}

private enum Lullaby {
    struct Note {
        /// Semitones above middle C, or nil for a rest.
        let semitone: Int?
        let beats: Double
    }

    private static let c = 0, d = 2, e = 4, f = 5, g = 7, a = 9, b = 11, highC = 12

    private static func note(_ semitone: Int, _ beats: Double) -> Note { Note(semitone: semitone, beats: beats) }
    private static func rest(_ beats: Double) -> Note { Note(semitone: nil, beats: beats) }

    /// Wiegenlied, Op. 49 No. 4, in C major, three beats to the bar.
    static let melody: [Note] = [
        note(e, 0.5), note(e, 0.5),
        note(g, 2), note(e, 0.5), note(e, 0.5),
        note(g, 2), note(e, 0.5), note(g, 0.5),
        note(highC, 1), note(b, 1.5), note(a, 0.5),
        note(a, 1), note(g, 1), note(d, 0.5), note(e, 0.5),
        note(f, 1), note(d, 1), note(d, 0.5), note(e, 0.5),
        note(f, 2), note(d, 0.5), note(f, 0.5),
        note(b, 0.5), note(a, 0.5), note(g, 1), note(b, 1),
        note(highC, 2), note(c, 0.5), note(c, 0.5),
        note(highC, 2), note(a, 0.5), note(f, 0.5),
        note(g, 2), note(e, 0.5), note(c, 0.5),
        note(f, 1), note(g, 1), note(a, 1),
        note(g, 2), note(c, 0.5), note(c, 0.5),
        note(highC, 2), note(a, 0.5), note(f, 0.5),
        note(g, 2), note(e, 0.5), note(c, 0.5),
        note(f, 1), note(e, 1), note(d, 1),
        note(c, 2), rest(2),
    ]
}
