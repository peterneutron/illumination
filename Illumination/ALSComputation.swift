import Foundation

enum ALSComputation {
    enum AutoGateAction {
        case none
        case enable
        case disable
    }

    struct AutoGateResult {
        let aboveCount: Int
        let belowCount: Int
        let action: AutoGateAction
    }

    static let maxPlausibleLux = 120_000.0
    static let minRelativeLux = 50.0
    static let maxRelativeLux = 100_000.0
    static let relativeGamma = 1.45

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

    static func relativeLux(normalizedX: Double) -> Double {
        let x = max(0.0, min(1.0, normalizedX))
        return minRelativeLux + (maxRelativeLux - minRelativeLux) * pow(x, relativeGamma)
    }

    static func blendWeight(
        rollingMaxDx: Double,
        hasSunAnchor: Bool,
        now: Date,
        warmupUntil: Date,
        sunDxTrigger: Double,
        relBlendMax: Double,
        xSun: Double = 2047.0
    ) -> Double {
        guard now >= warmupUntil else { return 0.0 }
        guard hasSunAnchor || rollingMaxDx >= sunDxTrigger else { return 0.0 }
        let conf = min(1.0, max(0.0, (rollingMaxDx - sunDxTrigger) / max(1.0, (xSun - sunDxTrigger))))
        return max(0.0, min(relBlendMax, relBlendMax * conf))
    }

    static func percentForLux(
        lux: Double,
        onLux: Double,
        entryMinPercent: Double
    ) -> Double {
        let triggerLux = max(1.0, onLux)
        let minPercent = max(0.0, min(100.0, entryMinPercent))
        if lux <= triggerLux { return minPercent }
        let highLux = triggerLux * 10.0
        let ratio = min(1.0, max(0.0, log(lux / triggerLux) / max(1e-6, log(highLux / triggerLux))))
        let smooth = ratio * ratio * (3.0 - 2.0 * ratio)
        return minPercent + (100.0 - minPercent) * smooth
    }

    static func nextRampPercent(
        currentPercent: Double,
        targetPercent: Double,
        entryMinPercent: Double,
        maxPercentPerSecond: Double,
        dt: Double,
        step: Double
    ) -> Double {
        let clampedCurrent = max(0.0, min(100.0, currentPercent))
        let desired = max(entryMinPercent, min(100.0, targetPercent))
        let stepped = clampedCurrent + (desired - clampedCurrent) * step
        let maxDelta = max(0.0, maxPercentPerSecond) * max(0.0, dt)
        let bounded = clampedCurrent + max(-maxDelta, min(maxDelta, stepped - clampedCurrent))
        return max(entryMinPercent, min(100.0, bounded))
    }

    static func surrogateSaturatedX(
        lastGoodX: Double,
        calibratorXDark: Double,
        rollingMaxDx: Double,
        saturationBoost: Double,
        saturationFloorDx: Double,
        maxDecodedX: Double
    ) -> Double {
        let boosted = lastGoodX * saturationBoost
        let floor = calibratorXDark + max(rollingMaxDx * 1.05, saturationFloorDx)
        return min(max(max(boosted, floor), 0.0), maxDecodedX)
    }

    static func shouldAttemptRebind(streak: Int, sampleHz: Double) -> Bool {
        let threshold = Int(max(1.0, sampleHz) * 5.0)
        return streak >= threshold
    }

    static func nextAutoGateState(
        lux: Double,
        isOn: Bool,
        aboveCount: Int,
        belowCount: Int,
        onLux: Double,
        offLux: Double,
        sampleHz: Double,
        onSeconds: Double,
        offSeconds: Double,
        canEnable: Bool,
        canDisable: Bool
    ) -> AutoGateResult {
        let onCountReq = max(1, Int(sampleHz * onSeconds))
        let offCountReq = max(1, Int(sampleHz * offSeconds))

        var nextAbove = aboveCount
        var nextBelow = belowCount

        if lux >= onLux {
            nextAbove = min(aboveCount + 1, onCountReq)
        } else {
            nextAbove = max(0, aboveCount - 1)
        }

        if lux <= offLux {
            nextBelow = min(belowCount + 1, offCountReq)
        } else {
            nextBelow = max(0, belowCount - 1)
        }

        if !isOn && nextAbove >= onCountReq {
            if canEnable {
                return AutoGateResult(aboveCount: 0, belowCount: 0, action: .enable)
            }
            return AutoGateResult(aboveCount: 0, belowCount: 0, action: .none)
        }

        if isOn && nextBelow >= offCountReq {
            if canDisable {
                return AutoGateResult(aboveCount: 0, belowCount: 0, action: .disable)
            }
            return AutoGateResult(aboveCount: 0, belowCount: 0, action: .none)
        }

        return AutoGateResult(aboveCount: nextAbove, belowCount: nextBelow, action: .none)
    }

    static func decodeAmbientBrightnessSample(raw: Any) -> (kind: String, value: Double?) {
        let fixedPointDiv = pow(2.0, 20.0)
        let sentinelGuard = UInt32(0x7FFFFF00)
        let sentinelU32 = UInt32(Int32.max)
        let maxDecodedX = 2047.0

        if let n = raw as? NSNumber {
            let int = n.int64Value
            if int >= Int64(Int32.max) - 16 { return ("saturated", nil) }
            if int < 0 { return ("invalid", nil) }
            let decoded = Double(int) / fixedPointDiv
            guard decoded.isFinite else { return ("invalid", nil) }
            return ("value", min(decoded, maxDecodedX))
        }
        if let d = raw as? Data, d.count >= 4 {
            let rawLE = d.withUnsafeBytes { $0.load(as: UInt32.self) }
            let int = UInt32(littleEndian: rawLE)
            if int >= sentinelGuard || int == sentinelU32 { return ("saturated", nil) }
            let decoded = Double(int) / fixedPointDiv
            guard decoded.isFinite else { return ("invalid", nil) }
            return ("value", min(decoded, maxDecodedX))
        }
        return ("invalid", nil)
    }

    static func fitCalibration(anchorA: (dx: Double, lux: Double), anchorB: (dx: Double, lux: Double)) -> (a: Double, p: Double)? {
        let a1 = anchorA
        let a2 = anchorB
        guard a1.dx > 1e-6, a2.dx > 1e-6, a1.lux > 1e-6, a2.lux > 1e-6 else { return nil }
        guard a1.dx != a2.dx, a1.lux.isFinite, a2.lux.isFinite, a1.dx.isFinite, a2.dx.isFinite else { return nil }
        let p = log(a2.lux / a1.lux) / log(a2.dx / a1.dx)
        guard p.isFinite else { return nil }
        let pClamped = max(0.8, min(1.8, p))
        let a = a1.lux / pow(a1.dx, pClamped)
        guard a.isFinite, a > 0 else { return nil }
        return (a, pClamped)
    }
}
