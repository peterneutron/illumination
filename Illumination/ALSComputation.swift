import Foundation

enum ALSComputation {
    static let maxPlausibleLux = 120_000.0

    static func sanitizeLux(_ lux: Double) -> Double {
        if lux == .infinity { return maxPlausibleLux }
        if lux == -.infinity || lux.isNaN { return 0.0 }
        guard lux.isFinite else { return 0.0 }
        return max(0.0, min(maxPlausibleLux, lux))
    }

    static func blendedLux(fit: Double, relative: Double, weight: Double) -> Double {
        let w = max(0.0, min(1.0, weight))
        return sanitizeLux((1.0 - w) * fit + w * relative)
    }
}
