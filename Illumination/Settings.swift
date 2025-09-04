import Foundation

enum Settings {
    // ALS tuning
    private static let entryMinKey = "illumination.als.entry.minPercent"
    private static let entryEnvelopeKey = "illumination.als.entry.envelopeSeconds"
    private static let maxSlopeKey = "illumination.als.maxPercentPerSecond"
    private static let minOnKey = "illumination.als.minOnSeconds"
    private static let minOffKey = "illumination.als.minOffSeconds"
    // ALS modeling
    private static let sunDxTriggerKey = "illumination.als.sunDxTrigger"
    private static let relBlendMaxKey = "illumination.als.relativeBlendMax"

    static var entryMinPercent: Double {
        get { UserDefaults.standard.object(forKey: entryMinKey) as? Double ?? 1.0 }
        set { UserDefaults.standard.set(max(0.0, min(10.0, newValue)), forKey: entryMinKey) }
    }
    static var entryEnvelopeSeconds: Double {
        get { UserDefaults.standard.object(forKey: entryEnvelopeKey) as? Double ?? 1.5 }
        set { UserDefaults.standard.set(max(0.1, min(5.0, newValue)), forKey: entryEnvelopeKey) }
    }
    static var maxPercentPerSecond: Double {
        get { UserDefaults.standard.object(forKey: maxSlopeKey) as? Double ?? 50.0 }
        set { UserDefaults.standard.set(max(5.0, min(200.0, newValue)), forKey: maxSlopeKey) }
    }
    static var minOnSeconds: Double {
        get { UserDefaults.standard.object(forKey: minOnKey) as? Double ?? 1.5 }
        set { UserDefaults.standard.set(max(0.0, min(10.0, newValue)), forKey: minOnKey) }
    }
    static var minOffSeconds: Double {
        get { UserDefaults.standard.object(forKey: minOffKey) as? Double ?? 1.5 }
        set { UserDefaults.standard.set(max(0.0, min(10.0, newValue)), forKey: minOffKey) }
    }
    static var sunDxTrigger: Double {
        get { UserDefaults.standard.object(forKey: sunDxTriggerKey) as? Double ?? 1200.0 }
        set { UserDefaults.standard.set(max(100.0, min(2047.0, newValue)), forKey: sunDxTriggerKey) }
    }
    static var relativeBlendMax: Double {
        get { UserDefaults.standard.object(forKey: relBlendMaxKey) as? Double ?? 0.25 }
        set { UserDefaults.standard.set(max(0.0, min(0.5, newValue)), forKey: relBlendMaxKey) }
    }
    // Master + brightness
    private static let masterEnabledKey = "illumination.enabled"
    private static let brightnessFactorKey = "illumination.brightness"
    static var masterEnabled: Bool {
        get { UserDefaults.standard.object(forKey: masterEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: masterEnabledKey) }
    }
    static var brightnessFactor: Double? {
        get { UserDefaults.standard.object(forKey: brightnessFactorKey) as? Double }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: brightnessFactorKey) }
            else { UserDefaults.standard.removeObject(forKey: brightnessFactorKey) }
        }
    }

    // Guard
    private static let guardEnabledKey = "illumination.guard.enabled"
    private static let guardFactorKey = "illumination.guard.factor"
    static var guardEnabled: Bool {
        get { UserDefaults.standard.object(forKey: guardEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: guardEnabledKey) }
    }
    static var guardFactor: Double {
        get { UserDefaults.standard.object(forKey: guardFactorKey) as? Double ?? 0.90 }
        set { UserDefaults.standard.set(newValue, forKey: guardFactorKey) }
    }

    // Overlay
    private static let overlayFullsizeKey = "illumination.overlay.fullsize"
    private static let overlayFPSKey = "illumination.overlay.fps"
    static var overlayFullsize: Bool {
        get { UserDefaults.standard.object(forKey: overlayFullsizeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: overlayFullsizeKey) }
    }
    static var overlayFPS: Int {
        get { UserDefaults.standard.object(forKey: overlayFPSKey) as? Int ?? 30 }
        set { UserDefaults.standard.set(max(5, min(120, newValue)), forKey: overlayFPSKey) }
    }

    // HDR
    private static let hdrAwareEnabledKey = "illumination.hdraware.enabled"
    private static let hdrAwareDuckPercentKey = "illumination.hdraware.duck.percent"
    private static let hdrAwareThresholdKey = "illumination.hdraware.threshold"
    private static let hdrRegionSamplerModeKey = "illumination.hdraware.regionsampler.mode"
    private static let hdrAwareFadeDurationKey = "illumination.hdraware.fade.duration"
    static var hdrAwareEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hdrAwareEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: hdrAwareEnabledKey) }
    }
    static var hdrDuckPercent: Double {
        get { UserDefaults.standard.object(forKey: hdrAwareDuckPercentKey) as? Double ?? 50.0 }
        set { UserDefaults.standard.set(max(0.0, min(100.0, newValue)), forKey: hdrAwareDuckPercentKey) }
    }
    static var hdrThreshold: Double {
        get { UserDefaults.standard.object(forKey: hdrAwareThresholdKey) as? Double ?? 1.5 }
        set { UserDefaults.standard.set(max(1.1, min(3.0, newValue)), forKey: hdrAwareThresholdKey) }
    }
    static var hdrRegionSamplerMode: Int {
        get { UserDefaults.standard.object(forKey: hdrRegionSamplerModeKey) as? Int ?? 0 }
        set { UserDefaults.standard.set(max(0, min(3, newValue)), forKey: hdrRegionSamplerModeKey) }
    }
    static var hdrFadeDuration: Double {
        get { UserDefaults.standard.object(forKey: hdrAwareFadeDurationKey) as? Double ?? 0.25 }
        set { UserDefaults.standard.set(max(0.05, min(2.0, newValue)), forKey: hdrAwareFadeDurationKey) }
    }

    // ALS core
    private static let alsProfileKey = "illumination.als.profile"
    private static let alsAutoEnabledKey = "illumination.als.autoEnabled"
    static var alsProfileRaw: String? {
        get { UserDefaults.standard.string(forKey: alsProfileKey) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: alsProfileKey) }
            else { UserDefaults.standard.removeObject(forKey: alsProfileKey) }
        }
    }
    static var alsAutoEnabled: Bool {
        get { UserDefaults.standard.object(forKey: alsAutoEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: alsAutoEnabledKey) }
    }
}
