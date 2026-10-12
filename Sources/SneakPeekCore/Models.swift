import Foundation

public struct Feed: Codable, Sendable {
    public var generatedAt: Double
    public var demo: Bool
    public var missions: [Mission]
    public var agents: [Agent]
    public var warnings: [String]?
    public var harnesses: [HarnessInfo]?
    public var queue: [QueueItem]?
    public static let empty = Feed(generatedAt: 0, demo: false, missions: [], agents: [])
    public func isDisconnected(at now: Double) -> Bool { !demo && now - generatedAt > 10 }
}

public struct Mission: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var goal: String
    public var checkpoints: [Checkpoint]
    public var owner: String?
    public var workspace: String?
    public var constraints: [String]?
    public var pinned: Bool?
    public var evidenceMaxAgeSeconds: Double?
    public var goalRevision: String?
    public var definitionRevision: String?
    public var goalOrigin: String?
    public var assessment: MissionAssessment?
    public var tasteNotes: [TasteSignal]?
}

public struct Checkpoint: Codable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var status: String
    public var evidence: String
    public var source: String
    public var kind: String?
    public var required: Bool?
    public var trackingState: String?
    public var records: [EvidenceRecord]?
    public var maxAgeSeconds: Double?
    public var verified: Bool { status == "verified" }
    public init(id: String, label: String, status: String, evidence: String, source: String, kind: String? = nil, required: Bool? = nil) {
        self.id = id; self.label = label; self.status = status; self.evidence = evidence; self.source = source
        self.kind = kind; self.required = required
    }
}

public struct Choice: Codable, Identifiable, Sendable {
    public var id: String
    public var label: String
}

public struct Intervention: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var choices: [Choice]
    public var mode: String
    public var expiresAt: Double
    public var issuedAt: Double?
    public var transport: String?
    public func canAnswer(at now: Double) -> Bool {
        mode == "decision" && now < expiresAt && !choices.isEmpty
    }
}

public struct Agent: Codable, Identifiable, Sendable {
    public var id: String
    public var missionId: String
    public var name: String
    public var provider: String
    public var status: String
    public var summary: String
    public var lastActivity: Double
    public var lastProgress: Double
    public var evidence: String
    public var nextStep: String
    public var trajectory: String
    public var sessionId: String?
    public var sourceApp: String?
    public var artifactPath: String?
    public var harnessId: String?
    public var handoffKind: String?
    public var provenance: String?
    public var progressFreshness: String?
    public var reportedTrajectory: String?
    public var request: Intervention?

    public func isQuiet(at now: Double) -> Bool { status == "working" && now - lastActivity > 300 }
    public func needsHuman(at now: Double) -> Bool {
        request != nil || status == "attention" || trajectory == "atRisk"
    }
    public func statusLabel(at now: Double) -> String {
        if request != nil { return "Needs you" }
        if isQuiet(at: now) { return "Quiet · check session" }
        switch status {
        case "working": return "Working"
        case "done": return "Turn finished"
        case "attention": return "Needs inspection"
        case "observed": return "Update observed"
        default: return "Idle"
        }
    }
}

public struct HarnessInfo: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var provider: String
    public var format: String
    public var enabled: Bool
    public var builtin: Bool
    public var logs: [String]
    public var status: String
    public var detail: String
    public var lastSeen: Double?
    public var recentLogs: Int
    public var sessionCount: Int

    public static let defaults: [HarnessInfo] = [
        HarnessInfo(id: "codex", name: "Codex", provider: "Codex", format: "codex", enabled: true, builtin: true, logs: [], status: "waiting", detail: "Waiting for the observer", recentLogs: 0, sessionCount: 0),
        HarnessInfo(id: "claude", name: "Claude Code", provider: "Claude", format: "claude", enabled: true, builtin: true, logs: [], status: "waiting", detail: "Waiting for the observer", recentLogs: 0, sessionCount: 0),
        HarnessInfo(id: "antigravity", name: "Antigravity", provider: "Antigravity", format: "antigravity", enabled: true, builtin: true, logs: [], status: "waiting", detail: "Waiting for the observer", recentLogs: 0, sessionCount: 0),
        HarnessInfo(id: "copilot", name: "GitHub Copilot", provider: "GitHub Copilot", format: "copilot", enabled: true, builtin: true, logs: [], status: "waiting", detail: "Waiting for the observer", recentLogs: 0, sessionCount: 0)
    ]
}

public struct HarnessDefinition: Codable, Sendable {
    public var id: String
    public var name: String?
    public var format: String?
    public var logs: [String]?
    public var enabled: Bool?
    public init(id: String, name: String? = nil, format: String? = nil, logs: [String]? = nil, enabled: Bool? = nil) {
        self.id = id; self.name = name; self.format = format; self.logs = logs; self.enabled = enabled
    }
}

public struct HarnessSettings: Codable, Sendable {
    public var recentHours: Double?
    public var harnesses: [HarnessDefinition]?
    public init(recentHours: Double? = nil, harnesses: [HarnessDefinition]? = nil) {
        self.recentHours = recentHours; self.harnesses = harnesses
    }
}

public struct Decision: Codable, Sendable {
    public var requestId: String
    public var agentId: String
    public var choiceId: String
    public var createdAt: Double
    public init(requestId: String, agentId: String, choiceId: String, createdAt: Double) {
        self.requestId = requestId; self.agentId = agentId
        self.choiceId = choiceId; self.createdAt = createdAt
    }
}

public enum DecisionError: Error, Equatable { case invalidRequest, expired, invalidChoice }

public enum DecisionWriter {
    public static func write(agent: Agent, choice: String, directory: URL, now: Double) throws {
        guard let request = agent.request, UUID(uuidString: request.id) != nil,
              request.mode == "decision" else { throw DecisionError.invalidRequest }
        guard now.isFinite, now < request.expiresAt,
              request.issuedAt.map({ $0.isFinite && $0 <= now }) ?? true else { throw DecisionError.expired }
        guard request.choices.contains(where: { $0.id == choice }) else { throw DecisionError.invalidChoice }
        let decision = Decision(requestId: request.id, agentId: agent.id, choiceId: choice, createdAt: now)
        let data = try JSONEncoder().encode(decision)
        try PrivateStateFiles.write(data, to: directory.appendingPathComponent(request.id + ".json"))
    }
}
