import Foundation

struct ALSReplayGateConfig {
    let onLux: Double
    let offLux: Double
    let sampleHz: Double
    let onSeconds: Double
    let offSeconds: Double
    let canEnable: Bool
    let canDisable: Bool

    static let `default` = ALSReplayGateConfig(
        onLux: 15_000.0,
        offLux: 10_000.0,
        sampleHz: 2.0,
        onSeconds: 2.0,
        offSeconds: 2.0,
        canEnable: true,
        canDisable: true
    )
}

enum ALSReplay {
    static func parseJSONL(_ jsonl: String) -> [ALSTraceEvent] {
        let decoder = JSONDecoder()
        return jsonl
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard !line.isEmpty else { return nil }
                return try? decoder.decode(ALSTraceEvent.self, from: Data(line.utf8))
            }
    }

    static func actionSequence(from events: [ALSTraceEvent]) -> [String] {
        events
            .filter { $0.kind == .autoGateDecision || $0.kind == .masterAction }
            .compactMap { $0.gateAction ?? $0.reason }
    }

    static func replayAutoGate(luxSamples: [Double], config: ALSReplayGateConfig = .default) -> [String] {
        var actions: [String] = []
        var aboveCount = 0
        var belowCount = 0
        var isOn = false

        for lux in luxSamples {
            let gate = ALSComputation.nextAutoGateState(
                lux: lux,
                isOn: isOn,
                aboveCount: aboveCount,
                belowCount: belowCount,
                onLux: config.onLux,
                offLux: config.offLux,
                sampleHz: config.sampleHz,
                onSeconds: config.onSeconds,
                offSeconds: config.offSeconds,
                canEnable: config.canEnable,
                canDisable: config.canDisable
            )
            aboveCount = gate.aboveCount
            belowCount = gate.belowCount
            switch gate.action {
            case .none:
                actions.append("none")
            case .enable:
                actions.append("enable")
                isOn = true
            case .disable:
                actions.append("disable")
                isOn = false
            }
        }
        return actions
    }

    static func replayLastExportSummary(jsonl: String) -> String {
        let events = parseJSONL(jsonl)
        guard !events.isEmpty else { return "ALS replay: no trace events" }
        let actions = actionSequence(from: events)
        let enableCount = actions.filter { $0 == "enable" }.count
        let disableCount = actions.filter { $0 == "disable" }.count
        return "ALS replay: \(events.count) events, enable=\(enableCount), disable=\(disableCount)"
    }
}
