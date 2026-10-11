import Foundation

public struct MissionAssessment: Codable, Sendable {
    public var goalRevision: String
    public var course: String
    public var evidence: String
    public var requiredCount: Int
    public var verifiedCount: Int
    public var reportedCount: Int
    public var missingCount: Int
    public var staleCount: Int
    public var conflictCount: Int
    public var decisionCount: Int
    public var coverageIncomplete: Bool
    public var reasons: [String]
    public var courseLabel: String {
        switch course {
        case "suspectedDrift": return "Drift suspected"
        case "supportedProgress": return "Progress has evidence"
        case "readyForReview": return "Checks met · review outcome"
        default: return "Course unproven"
        }
    }
    public var evidenceLabel: String {
        switch evidence {
        case "conflicting": return "A check was contradicted"
        case "stale": return "Evidence is stale"
        case "verified": return "Checks reviewed"
        case "reported": return "Evidence awaits review"
        default: return "Evidence missing"
        }
    }
}

public struct LocalSnapshot: Codable, Sendable {
    public var size: Int
    public var modifiedNS: String
}

public struct EvidenceRecord: Codable, Identifiable, Sendable {
    public var id: String
    public var missionId: String
    public var checkpointId: String
    public var goalRevision: String
    public var summary: String
    public var reference: String?
    public var verdict: String
    public var observedAt: Double
    public var source: String?
    public var actor: String?
    public var digest: String?
    public var localFile: LocalSnapshot?
    public var state: String?
    public var fingerprint: String?
    public var reviewedAt: Double?
    public var stateLabel: String {
        switch state {
        case "accepted": return "Check met · local review"
        case "rejected": return "Check not met · human review"
        case "stale": return "Evidence aged beyond its window"
        case "goalChanged": return "Evidence refers to an earlier goal"
        case "artifactChanged": return "Referenced artifact changed"
        case "missingArtifact": return "Referenced artifact unavailable"
        case "missingTime": return "Evidence time is unproven"
        case "missingReference": return "Needs an inspectable reference"
        default: return "Reported evidence · awaiting review"
        }
    }
    public var reviewable: Bool { state == "reported" || state == "accepted" || state == "rejected" }
}

public struct TasteSignal: Codable, Identifiable, Sendable {
    public var id: String
    public var missionId: String
    public var goalRevision: String
    public var checkpointId: String?
    public var valence: String
    public var strength: String
    public var note: String
    public var impact: String
    public var acceptance: String
    public var createdAt: Double
    public var contextStale: Bool?
    public var resolved: Bool?
    public var resolution: String?
    public var label: String {
        valence == "right" ? "Feels right" : valence == "off" ? "Feels off" : "Not sure yet"
    }
}

public struct QueueItem: Codable, Identifiable, Sendable {
    public var id: String
    public var missionId: String
    public var missionTitle: String
    public var kind: String
    public var title: String
    public var why: String
    public var impact: String
    public var priority: Int
    public var recordId: String?
    public var recordGoalRevision: String?
    public var contextStale: Bool?
    public var agentId: String?
    public var requestId: String?
    public var needsDecision: Bool { ["runtime", "taste", "judgment"].contains(kind) }
    public var kindLabel: String {
        switch kind {
        case "runtime": return "Host decision"
        case "taste": return "Taste · human judgment"
        case "judgment": return "Human guidance"
        case "drift": return "Drift suspected"
        case "evidence": return "Evidence missing or stale"
        default: return "Source needs inspection"
        }
    }
}
