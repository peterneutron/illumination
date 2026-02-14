import Foundation

enum ALSHardwareProfileID: String, CaseIterable, Codable {
    case hwMbp16l23 = "HW_MBP16L23"

    static var defaultProfile: ALSHardwareProfileID { .hwMbp16l23 }

    var displayName: String {
        rawValue
    }
}

enum EDRPolicyProfileID: String, CaseIterable, Codable {
    case edrMbp16l23 = "EDR_MBP16L23"

    static var defaultProfile: EDRPolicyProfileID { .edrMbp16l23 }

    var displayName: String {
        rawValue
    }
}

struct ALSHardwareProfileConfig {
    let calibratorA: Double
    let calibratorP: Double
    let calibratorXDark: Double

    let maxPlausibleLux: Double
    let minRelativeLux: Double
    let maxRelativeLux: Double
    let relativeGamma: Double

    let sunDxTrigger: Double
    let relBlendMax: Double
    let blendWarmupSeconds: Double

    let saturationApplyAfter: Double
    let saturationBoost: Double
    let saturationFloorDx: Double

    let smoothingTwilight: (tau: Double, mult: Double)
    let smoothingDaybreak: (tau: Double, mult: Double)
    let smoothingMidday: (tau: Double, mult: Double)
    let smoothingSunburst: (tau: Double, mult: Double)
    let smoothingHighNoon: (tau: Double, mult: Double)

    let onLuxTwilight: Double
    let onLuxDaybreak: Double
    let onLuxMidday: Double
    let onLuxSunburst: Double
    let onLuxHighNoon: Double

    let offLuxTwilight: Double
    let offLuxDaybreak: Double
    let offLuxMidday: Double
    let offLuxSunburst: Double
    let offLuxHighNoon: Double

    let onSecondsTwilight: Double
    let onSecondsDaybreak: Double
    let onSecondsMidday: Double
    let onSecondsSunburst: Double
    let onSecondsHighNoon: Double

    let offSecondsTwilight: Double
    let offSecondsDaybreak: Double
    let offSecondsMidday: Double
    let offSecondsSunburst: Double
    let offSecondsHighNoon: Double

    let rampStepTwilight: Double
    let rampStepDaybreak: Double
    let rampStepMidday: Double
    let rampStepSunburst: Double
    let rampStepHighNoon: Double

    let calibrationFitMinAnchorValue: Double
    let calibrationPMin: Double
    let calibrationPMax: Double

    func smoothing(for profile: ALSProfile) -> (tau: Double, mult: Double) {
        switch profile {
        case .twilight: return smoothingTwilight
        case .daybreak: return smoothingDaybreak
        case .midday: return smoothingMidday
        case .sunburst: return smoothingSunburst
        case .highNoon: return smoothingHighNoon
        }
    }

    func onLux(for profile: ALSProfile) -> Double {
        switch profile {
        case .twilight: return onLuxTwilight
        case .daybreak: return onLuxDaybreak
        case .midday: return onLuxMidday
        case .sunburst: return onLuxSunburst
        case .highNoon: return onLuxHighNoon
        }
    }

    func offLux(for profile: ALSProfile) -> Double {
        switch profile {
        case .twilight: return offLuxTwilight
        case .daybreak: return offLuxDaybreak
        case .midday: return offLuxMidday
        case .sunburst: return offLuxSunburst
        case .highNoon: return offLuxHighNoon
        }
    }

    func onSeconds(for profile: ALSProfile) -> Double {
        switch profile {
        case .twilight: return onSecondsTwilight
        case .daybreak: return onSecondsDaybreak
        case .midday: return onSecondsMidday
        case .sunburst: return onSecondsSunburst
        case .highNoon: return onSecondsHighNoon
        }
    }

    func offSeconds(for profile: ALSProfile) -> Double {
        switch profile {
        case .twilight: return offSecondsTwilight
        case .daybreak: return offSecondsDaybreak
        case .midday: return offSecondsMidday
        case .sunburst: return offSecondsSunburst
        case .highNoon: return offSecondsHighNoon
        }
    }

    func rampStep(for profile: ALSProfile) -> Double {
        switch profile {
        case .twilight: return rampStepTwilight
        case .daybreak: return rampStepDaybreak
        case .midday: return rampStepMidday
        case .sunburst: return rampStepSunburst
        case .highNoon: return rampStepHighNoon
        }
    }
}

struct EDRPolicyProfileConfig {
    let safetyMargin: Double
    let refSpan: Double
    let refAlpha: Double

    let capPollIntervalSeconds: Double
    let capPollToleranceSeconds: Double

    let hdrStreakClamp: Int
    let hdrActiveRequired: Int
    let hdrInactiveRequired: Int

    let hdrDuckAnimationEpsilon: Double
    let hdrDuckApplyMinLevel: Double

    let hdrDefaultDuckPercent: Double
    let hdrDefaultThreshold: Double
    let hdrDefaultFadeDuration: Double

    let edrLowThreshold: Double
    let edrLowRequiredStreak: Int
    let recoveryOverlayFPS: Int
    let recoveryDurationSeconds: Double

    let duckAnimationFPS: Double
}

enum ALSHardwareProfileCatalog {
    static let hwMbp16l23 = ALSHardwareProfileConfig(
        calibratorA: 20.701263635343665,
        calibratorP: 1.13652988767883,
        calibratorXDark: 0.0,
        maxPlausibleLux: 120_000.0,
        minRelativeLux: 50.0,
        maxRelativeLux: 100_000.0,
        relativeGamma: 1.45,
        sunDxTrigger: 1200.0,
        relBlendMax: 0.25,
        blendWarmupSeconds: 2.0,
        saturationApplyAfter: 0.5,
        saturationBoost: 1.15,
        saturationFloorDx: 1200.0,
        smoothingTwilight: (1.5, 1.6),
        smoothingDaybreak: (1.6, 1.55),
        smoothingMidday: (1.8, 1.5),
        smoothingSunburst: (3.5, 1.0),
        smoothingHighNoon: (6.0, 0.8),
        onLuxTwilight: 8_000.0,
        onLuxDaybreak: 12_000.0,
        onLuxMidday: 15_000.0,
        onLuxSunburst: 25_000.0,
        onLuxHighNoon: 35_000.0,
        offLuxTwilight: 5_000.0,
        offLuxDaybreak: 8_000.0,
        offLuxMidday: 10_000.0,
        offLuxSunburst: 18_000.0,
        offLuxHighNoon: 25_000.0,
        onSecondsTwilight: 1.0,
        onSecondsDaybreak: 1.0,
        onSecondsMidday: 1.0,
        onSecondsSunburst: 2.0,
        onSecondsHighNoon: 3.0,
        offSecondsTwilight: 2.0,
        offSecondsDaybreak: 3.0,
        offSecondsMidday: 2.0,
        offSecondsSunburst: 4.0,
        offSecondsHighNoon: 6.0,
        rampStepTwilight: 0.50,
        rampStepDaybreak: 0.45,
        rampStepMidday: 0.40,
        rampStepSunburst: 0.25,
        rampStepHighNoon: 0.15,
        calibrationFitMinAnchorValue: 1e-6,
        calibrationPMin: 0.8,
        calibrationPMax: 1.8
    )

    static func config(for id: ALSHardwareProfileID) -> ALSHardwareProfileConfig {
        switch id {
        case .hwMbp16l23: return hwMbp16l23
        }
    }

    static let defaultConfig = config(for: .defaultProfile)
}

enum EDRPolicyProfileCatalog {
    static let edrMbp16l23 = EDRPolicyProfileConfig(
        safetyMargin: 0.98,
        refSpan: 0.6,
        refAlpha: 1.0,
        capPollIntervalSeconds: 1.0,
        capPollToleranceSeconds: 0.2,
        hdrStreakClamp: 10,
        hdrActiveRequired: 2,
        hdrInactiveRequired: 3,
        hdrDuckAnimationEpsilon: 0.001,
        hdrDuckApplyMinLevel: 0.0001,
        hdrDefaultDuckPercent: 50.0,
        hdrDefaultThreshold: 1.5,
        hdrDefaultFadeDuration: 0.25,
        edrLowThreshold: 1.05,
        edrLowRequiredStreak: 2,
        recoveryOverlayFPS: 60,
        recoveryDurationSeconds: 2.0,
        duckAnimationFPS: 30.0
    )

    static func config(for id: EDRPolicyProfileID) -> EDRPolicyProfileConfig {
        switch id {
        case .edrMbp16l23: return edrMbp16l23
        }
    }

    static let defaultConfig = config(for: .defaultProfile)
}
