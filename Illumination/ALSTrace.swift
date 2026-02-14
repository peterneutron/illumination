import Foundation

enum ALSTraceEventKind: String, Codable {
    case sampleValue = "sample_value"
    case sampleSaturated = "sample_saturated"
    case sampleInvalid = "sample_invalid"
    case blendComputed = "blend_computed"
    case autoGateDecision = "auto_gate_decision"
    case masterAction = "master_action"
    case rebindAttempt = "rebind_attempt"
    case rebindResult = "rebind_result"
}

struct ALSTraceEvent: Codable {
    let timestampMs: Int64
    let kind: ALSTraceEventKind
    let decodedX: Double?
    let dx: Double?
    let fitLux: Double?
    let relLux: Double?
    let blendW: Double?
    let finalLux: Double?
    let isOn: Bool?
    let targetPercent: Double?
    let nextPercent: Double?
    let gateAction: String?
    let aboveCount: Int?
    let belowCount: Int?
    let onLux: Double?
    let offLux: Double?
    let profile: String?
    let reason: String?

    init(
        timestampMs: Int64 = ALSTraceEvent.nowMillis(),
        kind: ALSTraceEventKind,
        decodedX: Double? = nil,
        dx: Double? = nil,
        fitLux: Double? = nil,
        relLux: Double? = nil,
        blendW: Double? = nil,
        finalLux: Double? = nil,
        isOn: Bool? = nil,
        targetPercent: Double? = nil,
        nextPercent: Double? = nil,
        gateAction: String? = nil,
        aboveCount: Int? = nil,
        belowCount: Int? = nil,
        onLux: Double? = nil,
        offLux: Double? = nil,
        profile: String? = nil,
        reason: String? = nil
    ) {
        self.timestampMs = timestampMs
        self.kind = kind
        self.decodedX = decodedX
        self.dx = dx
        self.fitLux = fitLux
        self.relLux = relLux
        self.blendW = blendW
        self.finalLux = finalLux
        self.isOn = isOn
        self.targetPercent = targetPercent
        self.nextPercent = nextPercent
        self.gateAction = gateAction
        self.aboveCount = aboveCount
        self.belowCount = belowCount
        self.onLux = onLux
        self.offLux = offLux
        self.profile = profile
        self.reason = reason
    }

    private static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }
}

final class ALSTraceStore {
    private var events: [ALSTraceEvent] = []
    private let lock = NSLock()
    private(set) var capacity: Int
    private var captureEnabled = true

    init(capacity: Int = 1_000) {
        self.capacity = max(1, capacity)
    }

    func append(_ event: ALSTraceEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard captureEnabled else { return }
        if events.count == capacity {
            events.removeFirst()
        }
        events.append(event)
    }

    func snapshot() -> [ALSTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll(keepingCapacity: true)
    }

    func setCaptureEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        captureEnabled = enabled
    }

    func isCaptureEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return captureEnabled
    }

    func exportJSONL() -> String {
        let current = snapshot()
        guard !current.isEmpty else { return "" }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = current.compactMap { event -> String? in
            guard let data = try? encoder.encode(event) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return lines.joined(separator: "\n")
    }
}
