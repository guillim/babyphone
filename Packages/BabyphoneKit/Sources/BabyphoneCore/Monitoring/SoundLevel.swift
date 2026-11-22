import Foundation

/// Conversions between raw audio samples, decibels and the 0...1 scale shown on screen.
public enum SoundLevel {
    /// Level displayed as an empty meter.
    public static let floorDecibels = -60.0

    /// Root-mean-square level of a block of samples, in dBFS (0 is full scale).
    public static func decibels(of samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return floorDecibels }
        var sumOfSquares = 0.0
        for sample in samples {
            sumOfSquares += Double(sample) * Double(sample)
        }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()
        guard rms > 0 else { return floorDecibels }
        return max(floorDecibels, 20 * log10(rms))
    }

    /// Maps a dBFS level to 0...1 for meters.
    public static func normalized(decibels: Double) -> Double {
        min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}
