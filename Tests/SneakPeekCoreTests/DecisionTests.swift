import Foundation
import Testing
@testable import SneakPeekCore

private func waitingAgent(requestID: String = UUID().uuidString, expiry: Double = 200) throws -> Agent {
    let json: [String: Any] = ["id": "agent-a", "missionId": "mission-a", "name": "Validator", "provider": "Codex", "status": "attention", "summary": "Waiting", "lastActivity": 100, "lastProgress": 0, "evidence": "No checkpoint", "nextStep": "Review command", "trajectory": "unknown", "request": ["id": requestID, "title": "Allow?", "detail": "Exact command", "choices": [["id": "accept", "label": "Allow once"]], "mode": "decision", "expiresAt": expiry]]
    return try JSONDecoder().decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
}

@Test func responseContainsExactScopeAndChoice() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let agent = try waitingAgent()
    try DecisionWriter.write(agent: agent, choice: "accept", directory: directory, now: 101)
    let file = directory.appendingPathComponent(agent.request!.id + ".json")
    let result = try JSONDecoder().decode(Decision.self, from: Data(contentsOf: file))
    #expect(result.agentId == "agent-a")
    #expect(result.requestId == agent.request!.id)
    #expect(result.choiceId == "accept")
}

@Test func expiredAndMalformedRequestsNeverWriteDecisions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let expired = try waitingAgent(expiry: 99)
    #expect(throws: DecisionError.expired) { try DecisionWriter.write(agent: expired, choice: "accept", directory: directory, now: 100) }
    let malformed = try waitingAgent(requestID: "../../escape")
    #expect(throws: DecisionError.invalidRequest) { try DecisionWriter.write(agent: malformed, choice: "accept", directory: directory, now: 100) }
    let valid = try waitingAgent()
    #expect(throws: DecisionError.invalidChoice) { try DecisionWriter.write(agent: valid, choice: "allow-everything", directory: directory, now: 100) }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func quietWorkingAgentIsNotAutomaticallyAHumanDecision() throws {
    var agent = try waitingAgent()
    agent.request = nil; agent.status = "working"
    #expect(agent.isQuiet(at: 1000))
    #expect(!agent.needsHuman(at: 1000))
    agent.trajectory = "atRisk"
    #expect(agent.needsHuman(at: 1000))
}
