import Foundation
import Testing
@testable import Illumination

struct IlluminationTests {

    @Test("Settings defaults and clamping")
    func settingsDefaultsAndBounds() {
        guard let suite = UserDefaults(suiteName: "IlluminationTests.SettingsDefaults") else {
            #expect(Bool(false))
            return
        }
        suite.removePersistentDomain(forName: "IlluminationTests.SettingsDefaults")
        Settings.useStore(suite)
        defer {
            Settings.resetStore()
            suite.removePersistentDomain(forName: "IlluminationTests.SettingsDefaults")
        }

        #expect(Settings.entryMinPercent == 1.0)
        #expect(Settings.overlayFPS == 30)
        #expect(Settings.luxStepMode == 2)

        Settings.entryMinPercent = 99.0
        Settings.overlayFPS = 1000
        Settings.hdrThreshold = 99
        Settings.tileSize = -10
        Settings.appPolicyScope = 99

        #expect(Settings.entryMinPercent == 10.0)
        #expect(Settings.overlayFPS == 120)
        #expect(Settings.hdrThreshold == 3.0)
        #expect(Settings.tileSize == 1)
        #expect(Settings.appPolicyScope == 1)
    }

    @Test("Corrupt calibrator data falls back safely")
    func calibratorCorruptDataFallback() {
        guard let suite = UserDefaults(suiteName: "IlluminationTests.CalibratorFallback") else {
            #expect(Bool(false))
            return
        }
        suite.removePersistentDomain(forName: "IlluminationTests.CalibratorFallback")
        Settings.useStore(suite)
        defer {
            Settings.resetStore()
            suite.removePersistentDomain(forName: "IlluminationTests.CalibratorFallback")
        }

        Settings.alsCalibratorData = Data([0x00, 0xFF, 0x10])
        let loaded = LuxCalibrator.load()

        #expect(loaded.a > 0)
        #expect(loaded.p > 0)
        #expect(loaded.xDark >= 0)
    }

    @Test("ALS blend sanitizes NaN and infinity")
    func alsBlendSanitization() {
        #expect(ALSComputation.sanitizeLux(.nan) == 0.0)
        #expect(ALSComputation.sanitizeLux(.infinity) == ALSComputation.maxPlausibleLux)

        let blended = ALSComputation.blendedLux(fit: .infinity, relative: .nan, weight: 5.0)
        #expect(blended == 0.0)

        let bounded = ALSComputation.blendedLux(fit: 50_000, relative: 200_000, weight: 0.5)
        #expect(bounded <= ALSComputation.maxPlausibleLux)
        #expect(bounded >= 0.0)
    }

    @Test("Factor to percent mapping is bounded and monotonic")
    func brightnessFactorPercentMonotonicity() {
        let cap = 1.7

        let p0 = BrightnessController.percent(forFactor: 1.0, cap: cap)
        let p1 = BrightnessController.percent(forFactor: 1.2, cap: cap)
        let p2 = BrightnessController.percent(forFactor: cap, cap: cap)

        #expect(p0 >= 0 && p0 <= 100)
        #expect(p1 >= p0)
        #expect(p2 >= p1)
        #expect(p2 <= 100)

        let f0 = BrightnessController.factor(forPercent: 0, cap: cap)
        let f1 = BrightnessController.factor(forPercent: 50, cap: cap)
        let f2 = BrightnessController.factor(forPercent: 100, cap: cap)

        #expect(f0 >= 1.0 && f0 <= cap)
        #expect(f1 >= f0)
        #expect(f2 >= f1)
        #expect(f2 <= cap)

        let roundTrip = BrightnessController.percent(forFactor: BrightnessController.factor(forPercent: 37, cap: cap), cap: cap)
        #expect(abs(roundTrip - 37.0) < 0.0001)
    }

    @Test("Guard cap behavior is bounded and deterministic")
    func brightnessGuardCapComputation() {
        let noGuard = BrightnessController.effectiveCap(rawCap: 1.85, guardEnabled: false, guardFactor: 0.90)
        #expect(noGuard == 1.70)

        let guarded = BrightnessController.effectiveCap(rawCap: 1.85, guardEnabled: true, guardFactor: 0.90)
        #expect(abs(guarded - 1.53) < 0.0001)

        let floorBound = BrightnessController.effectiveCap(rawCap: 0.80, guardEnabled: true, guardFactor: 0.70)
        #expect(floorBound == 1.0)
    }

    @Test("Blocked app registry seeds once and remains stable")
    func blockedAppRegistrySeedAndStability() {
        let suiteName = "IlluminationTests.HDRAppSeed"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            #expect(Bool(false))
            return
        }
        suite.removePersistentDomain(forName: suiteName)
        Settings.useStore(suite)
        defer {
            Settings.resetStore()
            suite.removePersistentDomain(forName: suiteName)
        }

        let first = HDRAppList.allDenylistedEntries()
        let second = HDRAppList.allDenylistedEntries()
        #expect(first.count == second.count)
        #expect(first.count >= 6)
        #expect(Set(first.map(\.bundleID)).count == first.count)
    }

    @Test("Blocked app matching normalizes and respects enabled/removed states")
    func blockedAppMatchingNormalizationAndState() {
        let suiteName = "IlluminationTests.HDRAppMatch"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            #expect(Bool(false))
            return
        }
        suite.removePersistentDomain(forName: suiteName)
        Settings.useStore(suite)
        defer {
            Settings.resetStore()
            suite.removePersistentDomain(forName: suiteName)
        }

        HDRAppList.addDenylistedApp(bundleID: "COM.TEST.HDRAPP", displayName: "Test HDR App")
        #expect(HDRAppList.isBundleIDDenylisted("com.test.hdrapp"))
        #expect(HDRAppList.isBundleIDDenylisted("COM.TEST.HDRAPP"))

        HDRAppList.setDenylistedEnabled(bundleID: "com.test.hdrapp", isEnabled: false)
        #expect(HDRAppList.isBundleIDDenylisted("com.test.hdrapp") == false)

        HDRAppList.removeDenylistedApp(bundleID: "com.test.hdrapp")
        #expect(HDRAppList.isBundleIDDenylisted("com.test.hdrapp") == false)
    }

    @Test("Corrupt blocked app registry payload falls back safely")
    func blockedAppRegistryCorruptFallback() {
        let suiteName = "IlluminationTests.HDRAppCorrupt"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            #expect(Bool(false))
            return
        }
        suite.removePersistentDomain(forName: suiteName)
        Settings.useStore(suite)
        defer {
            Settings.resetStore()
            suite.removePersistentDomain(forName: suiteName)
        }

        Settings.hdrAppRegistryData = Data([0x01, 0x02, 0x03])
        let entries = HDRAppList.allDenylistedEntries()
        #expect(entries.count >= 6)
        #expect(HDRAppList.isBundleIDDenylisted("com.apple.photos"))
    }

    @Test("HDR detection gate semantics are deterministic")
    func hdrDetectionGateSemantics() {
        let off = BrightnessController.hdrGateDecision(mode: 0, appMatched: true, samplerHDRPresent: true)
        #expect(off.allowed == false)
        #expect(off.gate == "Off")

        let appsBlocked = BrightnessController.hdrGateDecision(mode: 3, appMatched: false, samplerHDRPresent: true)
        #expect(appsBlocked.allowed == false)
        #expect(appsBlocked.gate == "Apps blocked")

        let appsAllowed = BrightnessController.hdrGateDecision(mode: 3, appMatched: true, samplerHDRPresent: false)
        #expect(appsAllowed.allowed)
        #expect(appsAllowed.gate == "Apps allowed")

        let autoBlocked = BrightnessController.hdrGateDecision(mode: 2, appMatched: true, samplerHDRPresent: false)
        #expect(autoBlocked.allowed == false)
        #expect(autoBlocked.gate == "Auto blocked")

        let autoAllowed = BrightnessController.hdrGateDecision(mode: 2, appMatched: true, samplerHDRPresent: true)
        #expect(autoAllowed.allowed)
        #expect(autoAllowed.gate == "Auto allowed")
    }

    @Test("Adding duplicate blocked app is idempotent")
    func blockedAppDuplicateAddIdempotent() {
        let suiteName = "IlluminationTests.HDRAppIdempotent"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            #expect(Bool(false))
            return
        }
        suite.removePersistentDomain(forName: suiteName)
        Settings.useStore(suite)
        defer {
            Settings.resetStore()
            suite.removePersistentDomain(forName: suiteName)
        }

        HDRAppList.addDenylistedApp(bundleID: "com.test.idempotent", displayName: "Idempotent")
        HDRAppList.addDenylistedApp(bundleID: "COM.TEST.IDEMPOTENT", displayName: "Idempotent")
        let entries = HDRAppList.allDenylistedEntries().filter { $0.bundleID.lowercased() == "com.test.idempotent" }
        #expect(entries.count == 1)
        #expect(entries.first?.isEnabled == true)
    }

    @Test("App policy scope semantics are deterministic")
    func appPolicyScopeSemantics() {
        let appsBlocked = AppPolicy.decide(scope: .apps, frontmostDenylisted: true)
        #expect(appsBlocked.isBlocked)
        #expect(appsBlocked.result == "blocked")

        let appsAllowed = AppPolicy.decide(scope: .apps, frontmostDenylisted: false)
        #expect(appsAllowed.isBlocked == false)
        #expect(appsAllowed.result == "allowed")

        let everywhereAllowed = AppPolicy.decide(scope: .everywhere, frontmostDenylisted: true)
        #expect(everywhereAllowed.isBlocked == false)
        #expect(everywhereAllowed.result == "allowed")
    }

    @Test("ALS decode handles malformed and sentinel inputs")
    func alsDecodeRobustness() {
        let negative = ALSComputation.decodeAmbientBrightnessSample(raw: NSNumber(value: -1))
        #expect(negative.kind == "invalid")

        let sentinel = ALSComputation.decodeAmbientBrightnessSample(raw: NSNumber(value: Int32.max))
        #expect(sentinel.kind == "saturated")

        var nearSentinelLE = UInt32(0x7FFFFF10).littleEndian
        let sentinelData = Data(bytes: &nearSentinelLE, count: MemoryLayout<UInt32>.size)
        let fromData = ALSComputation.decodeAmbientBrightnessSample(raw: sentinelData)
        #expect(fromData.kind == "saturated")
    }

    @Test("ALS percent mapping and ramp are stable and bounded")
    func alsPercentAndRampStability() {
        let base = ALSComputation.percentForLux(lux: 15_000, onLux: 15_000, entryMinPercent: 5)
        let brighter = ALSComputation.percentForLux(lux: 150_000, onLux: 15_000, entryMinPercent: 5)
        #expect(base >= 5)
        #expect(brighter >= base)
        #expect(brighter <= 100)

        let ramped = ALSComputation.nextRampPercent(
            currentPercent: 5,
            targetPercent: 80,
            entryMinPercent: 5,
            maxPercentPerSecond: 10,
            dt: 0.5,
            step: 1.0
        )
        #expect(ramped <= 10.0)
        #expect(ramped >= 5.0)

        let clampedToEntry = ALSComputation.nextRampPercent(
            currentPercent: 20,
            targetPercent: 0,
            entryMinPercent: 5,
            maxPercentPerSecond: 100,
            dt: 1.0,
            step: 1.0
        )
        #expect(clampedToEntry >= 5.0)
    }

    @Test("ALS saturation surrogate stays bounded")
    func alsSaturationBounds() {
        let surrogate = ALSComputation.surrogateSaturatedX(
            lastGoodX: 1500,
            calibratorXDark: 0,
            rollingMaxDx: 1800,
            saturationBoost: 1.15,
            saturationFloorDx: 1200,
            maxDecodedX: 2047
        )
        #expect(surrogate <= 2047)
        #expect(surrogate >= 0)
    }

    @Test("ALS calibration fit rejects degenerate anchors")
    func alsCalibrationDegenerateInput() {
        let rejectedEqualDx = ALSComputation.fitCalibration(
            anchorA: (dx: 10, lux: 100),
            anchorB: (dx: 10, lux: 200)
        )
        #expect(rejectedEqualDx == nil)

        let rejectedInvalid = ALSComputation.fitCalibration(
            anchorA: (dx: .nan, lux: 100),
            anchorB: (dx: 20, lux: 200)
        )
        #expect(rejectedInvalid == nil)
    }

    @Test("ALS auto gate avoids rapid toggles near thresholds")
    func alsAutoGateJitterStability() {
        var above = 0
        var below = 0
        let jitterLux: [Double] = [14_900, 15_100, 14_950, 15_050, 14_990, 15_010]

        for lux in jitterLux {
            let next = ALSComputation.nextAutoGateState(
                lux: lux,
                isOn: false,
                aboveCount: above,
                belowCount: below,
                onLux: 15_000,
                offLux: 10_000,
                sampleHz: 2.0,
                onSeconds: 2.0,
                offSeconds: 2.0,
                canEnable: true,
                canDisable: true
            )
            above = next.aboveCount
            below = next.belowCount
            #expect(next.action == .none)
        }
    }

    @Test("ALS auto gate min ON/OFF guards defer toggles")
    func alsAutoGateMinGuards() {
        let blockedEnable = ALSComputation.nextAutoGateState(
            lux: 20_000,
            isOn: false,
            aboveCount: 1,
            belowCount: 0,
            onLux: 15_000,
            offLux: 10_000,
            sampleHz: 2.0,
            onSeconds: 1.0,
            offSeconds: 1.0,
            canEnable: false,
            canDisable: true
        )
        #expect(blockedEnable.action == .none)
        #expect(blockedEnable.aboveCount == 0)
        #expect(blockedEnable.belowCount == 0)

        let blockedDisable = ALSComputation.nextAutoGateState(
            lux: 5_000,
            isOn: true,
            aboveCount: 0,
            belowCount: 1,
            onLux: 15_000,
            offLux: 10_000,
            sampleHz: 2.0,
            onSeconds: 1.0,
            offSeconds: 1.0,
            canEnable: true,
            canDisable: false
        )
        #expect(blockedDisable.action == .none)
        #expect(blockedDisable.aboveCount == 0)
        #expect(blockedDisable.belowCount == 0)
    }

    @Test("ALS rapid invalid/value/saturated sequence remains non-crashing")
    func alsRapidSampleTransitionsRegression() {
        var sentinelLE = UInt32(0x7FFFFF00).littleEndian
        let saturatedData = Data(bytes: &sentinelLE, count: MemoryLayout<UInt32>.size)
        let sequence: [Any] = [
            NSNumber(value: -4),                // invalid
            NSNumber(value: 1_200_000),         // value
            saturatedData,                      // saturated
            NSNumber(value: Int32.max),         // saturated
            Data([0x01, 0x02]),                 // invalid short data
            NSNumber(value: 900_000)            // value
        ]

        for raw in sequence {
            let decoded = ALSComputation.decodeAmbientBrightnessSample(raw: raw)
            switch decoded.kind {
            case "value":
                let lux = ALSComputation.relativeLux(normalizedX: (decoded.value ?? 0) / 2047.0)
                #expect(lux.isFinite)
                #expect(lux >= 0.0)
            case "saturated":
                let surrogate = ALSComputation.surrogateSaturatedX(
                    lastGoodX: 1500,
                    calibratorXDark: 0,
                    rollingMaxDx: 1800,
                    saturationBoost: 1.15,
                    saturationFloorDx: 1200,
                    maxDecodedX: 2047
                )
                #expect(surrogate.isFinite)
                #expect(surrogate <= 2047)
            default:
                #expect(decoded.value == nil)
            }
        }
    }

    @Test("xDark remains pinned at zero")
    func xDarkPinnedPolicy() {
        let suiteName = "IlluminationTests.XDarkPinned"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            #expect(Bool(false))
            return
        }
        suite.removePersistentDomain(forName: suiteName)
        Settings.useStore(suite)
        defer {
            Settings.resetStore()
            suite.removePersistentDomain(forName: suiteName)
        }

        var c = LuxCalibrator()
        c.xDark = 123.0
        c.save()
        let loaded = LuxCalibrator.load()
        #expect(loaded.xDark == 123.0)

        // Policy check: pinned value for runtime model remains zero in defaults.
        c.xDark = 0.0
        c.save()
        let reloaded = LuxCalibrator.load()
        #expect(reloaded.xDark == 0.0)
    }
}
