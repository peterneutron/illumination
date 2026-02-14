import Foundation
import Testing
@testable import Illumination

struct ALSTraceTests {

    @Test("ALS trace event codable roundtrip")
    func traceEventCodableRoundtrip() throws {
        let event = ALSTraceEvent(
            timestampMs: 1234,
            kind: .blendComputed,
            decodedX: 420.0,
            dx: 410.0,
            fitLux: 12_000.0,
            relLux: 22_000.0,
            blendW: 0.2,
            finalLux: 14_000.0,
            isOn: true,
            targetPercent: 55.0,
            nextPercent: 52.0,
            gateAction: "none",
            aboveCount: 1,
            belowCount: 0,
            onLux: 15_000.0,
            offLux: 10_000.0,
            profile: "midday",
            reason: "test"
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ALSTraceEvent.self, from: data)

        #expect(decoded.kind == .blendComputed)
        #expect(decoded.timestampMs == 1234)
        #expect(decoded.finalLux == 14_000.0)
        #expect(decoded.profile == "midday")
    }

    @Test("ALS trace ring buffer capacity and ordering")
    func ringBufferCapacityAndOrder() {
        let store = ALSTraceStore(capacity: 3)
        store.append(ALSTraceEvent(timestampMs: 1, kind: .sampleValue, reason: "1"))
        store.append(ALSTraceEvent(timestampMs: 2, kind: .sampleValue, reason: "2"))
        store.append(ALSTraceEvent(timestampMs: 3, kind: .sampleValue, reason: "3"))
        store.append(ALSTraceEvent(timestampMs: 4, kind: .sampleValue, reason: "4"))

        let snapshot = store.snapshot()
        #expect(snapshot.count == 3)
        #expect(snapshot[0].timestampMs == 2)
        #expect(snapshot[1].timestampMs == 3)
        #expect(snapshot[2].timestampMs == 4)

        store.clear()
        #expect(store.snapshot().isEmpty)
    }

    @Test("ALS trace JSONL export emits valid JSON lines")
    func jsonlExportValidity() {
        let store = ALSTraceStore(capacity: 3)
        store.append(ALSTraceEvent(timestampMs: 10, kind: .sampleValue))
        store.append(ALSTraceEvent(timestampMs: 11, kind: .autoGateDecision, gateAction: "enable"))

        let jsonl = store.exportJSONL()
        let events = ALSReplay.parseJSONL(jsonl)

        #expect(events.count == 2)
        #expect(events[0].timestampMs == 10)
        #expect(events[1].gateAction == "enable")
    }

    @Test("ALS replay is deterministic across repeated runs")
    func replayDeterminism() {
        let script: [Double] = [
            14_900, 15_100, 15_200, 15_300,
            20_000, 25_000, 30_000,
            12_000, 9_500, 9_000, 8_500
        ]
        let config = ALSReplayGateConfig(
            onLux: 15_000,
            offLux: 10_000,
            sampleHz: 2.0,
            onSeconds: 1.0,
            offSeconds: 1.0,
            canEnable: true,
            canDisable: true
        )

        let first = ALSReplay.replayAutoGate(luxSamples: script, config: config)
        let second = ALSReplay.replayAutoGate(luxSamples: script, config: config)

        #expect(first == second)
        #expect(first.contains("enable"))
        #expect(first.contains("disable"))
    }

    @Test("ALS replay handles invalid and saturated style traces safely")
    func replayTraceNonCrashBehavior() {
        let events = [
            ALSTraceEvent(timestampMs: 1, kind: .sampleInvalid, reason: "invalid"),
            ALSTraceEvent(timestampMs: 2, kind: .sampleSaturated, reason: "saturated"),
            ALSTraceEvent(timestampMs: 3, kind: .autoGateDecision, gateAction: "none"),
            ALSTraceEvent(timestampMs: 4, kind: .rebindAttempt, reason: "attempt"),
            ALSTraceEvent(timestampMs: 5, kind: .rebindResult, reason: "success")
        ]
        let encoder = JSONEncoder()
        let lines = events.compactMap { event -> String? in
            guard let data = try? encoder.encode(event) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let jsonl = lines.joined(separator: "\n")
        let summary = ALSReplay.replayLastExportSummary(jsonl: jsonl)

        #expect(summary.contains("5 events"))
        #expect(summary.contains("enable=0"))
        #expect(summary.contains("disable=0"))
    }

    @Test("ALS gate denylist-style enable block remains deterministic")
    func replayDenylistBlockedEnableAttempt() {
        let script: [Double] = [20_000, 22_000, 24_000, 26_000]
        let blockedConfig = ALSReplayGateConfig(
            onLux: 15_000,
            offLux: 10_000,
            sampleHz: 2.0,
            onSeconds: 1.0,
            offSeconds: 1.0,
            canEnable: false,
            canDisable: true
        )

        let actions = ALSReplay.replayAutoGate(luxSamples: script, config: blockedConfig)
        #expect(actions.allSatisfy { $0 == "none" })
    }
}
