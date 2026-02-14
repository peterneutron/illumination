import Foundation
import Testing
@testable import Illumination

struct IlluminationTests {

    @Test("Settings defaults and clamping")
    func settingsDefaultsAndBounds() {
        let suite = UserDefaults(suiteName: "IlluminationTests.SettingsDefaults")!
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

        #expect(Settings.entryMinPercent == 10.0)
        #expect(Settings.overlayFPS == 120)
        #expect(Settings.hdrThreshold == 3.0)
        #expect(Settings.tileSize == 1)
    }

    @Test("Corrupt calibrator data falls back safely")
    func calibratorCorruptDataFallback() {
        let suite = UserDefaults(suiteName: "IlluminationTests.CalibratorFallback")!
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
    }
}
