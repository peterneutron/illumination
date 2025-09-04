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
}

