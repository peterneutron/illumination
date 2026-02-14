import Foundation

@inline(__always)
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

@inline(__always)
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

enum Settings {
    enum Key: String, CaseIterable {
        case entryMinPercent = "illumination.als.entry.minPercent"
        case entryEnvelopeSeconds = "illumination.als.entry.envelopeSeconds"
        case maxPercentPerSecond = "illumination.als.maxPercentPerSecond"
        case minOnSeconds = "illumination.als.minOnSeconds"
        case minOffSeconds = "illumination.als.minOffSeconds"

        case masterEnabled = "illumination.enabled"
        case brightnessFactor = "illumination.brightness"

        case guardEnabled = "illumination.guard.enabled"
        case guardFactor = "illumination.guard.factor"

        case overlayFullsize = "illumination.overlay.fullsize"
        case overlayFPS = "illumination.overlay.fps"

        case tileEnabled = "illumination.overlay.hdrtile"
        case tileFullOpacity = "illumination.overlay.hdrtile.fullopacity"
        case tileSize = "illumination.overlay.hdrtile.size"

        case hdrAwareEnabled = "illumination.hdraware.enabled"
        case hdrAwareDuckPercent = "illumination.hdraware.duck.percent"
        case hdrAwareThreshold = "illumination.hdraware.threshold"
        case hdrRegionSamplerMode = "illumination.hdraware.regionsampler.mode"
        case hdrAwareFadeDuration = "illumination.hdraware.fade.duration"

        case alsProfile = "illumination.als.profile"
        case alsHardwareProfile = "illumination.als.hardwareProfile"
        case alsAutoEnabled = "illumination.als.autoEnabled"
        case luxStepMode = "illumination.ui.lux.step"
        case edrPolicyProfile = "illumination.edr.policyProfile"

        case alsCalibrator = "illumination.als.calibrator"
        case alsCalibAnchorA = "illumination.als.calib.anchorA"
        case alsCalibAnchorB = "illumination.als.calib.anchorB"
        case hdrAppRegistry = "illumination.hdraware.app.registry"
        case appPolicyScope = "illumination.app.scope"
    }

    private static var store: UserDefaults = .standard

    static func useStore(_ defaults: UserDefaults) {
        store = defaults
    }

    static func resetStore() {
        store = .standard
    }

    private static func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        max(minValue, min(maxValue, value))
    }

    private static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        max(minValue, min(maxValue, value))
    }

    private static func bool(_ key: Key, default defaultValue: Bool) -> Bool {
        store.object(forKey: key.rawValue) as? Bool ?? defaultValue
    }

    private static func double(_ key: Key, default defaultValue: Double) -> Double {
        store.object(forKey: key.rawValue) as? Double ?? defaultValue
    }

    private static func int(_ key: Key, default defaultValue: Int) -> Int {
        store.object(forKey: key.rawValue) as? Int ?? defaultValue
    }

    static func data(for key: Key) -> Data? {
        store.data(forKey: key.rawValue)
    }

    static func set(_ data: Data?, for key: Key) {
        if let data {
            store.set(data, forKey: key.rawValue)
        } else {
            store.removeObject(forKey: key.rawValue)
        }
    }

    static var entryMinPercent: Double {
        get { double(.entryMinPercent, default: 1.0) }
        set { store.set(clamp(newValue, min: 0.0, max: 10.0), forKey: Key.entryMinPercent.rawValue) }
    }
    static var entryEnvelopeSeconds: Double {
        get { double(.entryEnvelopeSeconds, default: 1.5) }
        set { store.set(clamp(newValue, min: 0.1, max: 5.0), forKey: Key.entryEnvelopeSeconds.rawValue) }
    }
    static var maxPercentPerSecond: Double {
        get { double(.maxPercentPerSecond, default: 50.0) }
        set { store.set(clamp(newValue, min: 5.0, max: 200.0), forKey: Key.maxPercentPerSecond.rawValue) }
    }
    static var minOnSeconds: Double {
        get { double(.minOnSeconds, default: 1.5) }
        set { store.set(clamp(newValue, min: 0.0, max: 10.0), forKey: Key.minOnSeconds.rawValue) }
    }
    static var minOffSeconds: Double {
        get { double(.minOffSeconds, default: 1.5) }
        set { store.set(clamp(newValue, min: 0.0, max: 10.0), forKey: Key.minOffSeconds.rawValue) }
    }

    static var masterEnabled: Bool {
        get { bool(.masterEnabled, default: false) }
        set { store.set(newValue, forKey: Key.masterEnabled.rawValue) }
    }
    static var brightnessFactor: Double? {
        get { store.object(forKey: Key.brightnessFactor.rawValue) as? Double }
        set { newValue.map { store.set($0, forKey: Key.brightnessFactor.rawValue) } ?? store.removeObject(forKey: Key.brightnessFactor.rawValue) }
    }

    static var guardEnabled: Bool {
        get { bool(.guardEnabled, default: false) }
        set { store.set(newValue, forKey: Key.guardEnabled.rawValue) }
    }
    static var guardFactor: Double {
        get { double(.guardFactor, default: 0.90) }
        set { store.set(clamp(newValue, min: 0.70, max: 0.98), forKey: Key.guardFactor.rawValue) }
    }

    static var overlayFullsize: Bool {
        get { bool(.overlayFullsize, default: true) }
        set { store.set(newValue, forKey: Key.overlayFullsize.rawValue) }
    }
    static var overlayFPS: Int {
        get { int(.overlayFPS, default: 30) }
        set { store.set(clamp(newValue, min: 5, max: 120), forKey: Key.overlayFPS.rawValue) }
    }

    static var tileEnabled: Bool {
        get { bool(.tileEnabled, default: false) }
        set { store.set(newValue, forKey: Key.tileEnabled.rawValue) }
    }
    static var tileFullOpacity: Bool {
        get { bool(.tileFullOpacity, default: false) }
        set { store.set(newValue, forKey: Key.tileFullOpacity.rawValue) }
    }
    static var tileSize: Int {
        get { int(.tileSize, default: 64) }
        set { store.set(clamp(newValue, min: 1, max: 512), forKey: Key.tileSize.rawValue) }
    }

    static var hdrAwareEnabled: Bool {
        get { bool(.hdrAwareEnabled, default: false) }
        set { store.set(newValue, forKey: Key.hdrAwareEnabled.rawValue) }
    }
    static var hdrDuckPercent: Double {
        get { double(.hdrAwareDuckPercent, default: EDRPolicyProfileCatalog.defaultConfig.hdrDefaultDuckPercent) }
        set { store.set(clamp(newValue, min: 0.0, max: 100.0), forKey: Key.hdrAwareDuckPercent.rawValue) }
    }
    static var hdrThreshold: Double {
        get { double(.hdrAwareThreshold, default: EDRPolicyProfileCatalog.defaultConfig.hdrDefaultThreshold) }
        set { store.set(clamp(newValue, min: 1.1, max: 3.0), forKey: Key.hdrAwareThreshold.rawValue) }
    }
    static var hdrRegionSamplerMode: Int {
        get { int(.hdrRegionSamplerMode, default: 0) }
        set { store.set(clamp(newValue, min: 0, max: 3), forKey: Key.hdrRegionSamplerMode.rawValue) }
    }
    static var hdrFadeDuration: Double {
        get { double(.hdrAwareFadeDuration, default: EDRPolicyProfileCatalog.defaultConfig.hdrDefaultFadeDuration) }
        set { store.set(clamp(newValue, min: 0.05, max: 2.0), forKey: Key.hdrAwareFadeDuration.rawValue) }
    }

    static var alsProfileRaw: String? {
        get { store.string(forKey: Key.alsProfile.rawValue) }
        set { newValue.map { store.set($0, forKey: Key.alsProfile.rawValue) } ?? store.removeObject(forKey: Key.alsProfile.rawValue) }
    }
    static var alsHardwareProfileID: String {
        get { store.string(forKey: Key.alsHardwareProfile.rawValue) ?? ALSHardwareProfileID.defaultProfile.rawValue }
        set { store.set(newValue, forKey: Key.alsHardwareProfile.rawValue) }
    }
    static var alsHardwareProfile: ALSHardwareProfileID {
        get { ALSHardwareProfileID(rawValue: alsHardwareProfileID) ?? .defaultProfile }
        set { alsHardwareProfileID = newValue.rawValue }
    }
    static var edrPolicyProfileID: String {
        get { store.string(forKey: Key.edrPolicyProfile.rawValue) ?? EDRPolicyProfileID.defaultProfile.rawValue }
        set { store.set(newValue, forKey: Key.edrPolicyProfile.rawValue) }
    }
    static var edrPolicyProfile: EDRPolicyProfileID {
        get { EDRPolicyProfileID(rawValue: edrPolicyProfileID) ?? .defaultProfile }
        set { edrPolicyProfileID = newValue.rawValue }
    }
    static var alsAutoEnabled: Bool {
        get { bool(.alsAutoEnabled, default: false) }
        set { store.set(newValue, forKey: Key.alsAutoEnabled.rawValue) }
    }

    static var luxStepMode: Int {
        get { clamp(int(.luxStepMode, default: 2), min: 0, max: 3) }
        set { store.set(clamp(newValue, min: 0, max: 3), forKey: Key.luxStepMode.rawValue) }
    }

    static var alsCalibratorData: Data? {
        get { data(for: .alsCalibrator) }
        set { set(newValue, for: .alsCalibrator) }
    }

    static var alsCalibAnchorAData: Data? {
        get { data(for: .alsCalibAnchorA) }
        set { set(newValue, for: .alsCalibAnchorA) }
    }

    static var alsCalibAnchorBData: Data? {
        get { data(for: .alsCalibAnchorB) }
        set { set(newValue, for: .alsCalibAnchorB) }
    }

    static var hdrAppRegistryData: Data? {
        get { data(for: .hdrAppRegistry) }
        set { set(newValue, for: .hdrAppRegistry) }
    }

    static var appPolicyScope: Int {
        get { clamp(int(.appPolicyScope, default: 1), min: 0, max: 1) }
        set { store.set(clamp(newValue, min: 0, max: 1), forKey: Key.appPolicyScope.rawValue) }
    }
}
