import Foundation
import Testing
import SneakPeekCore
@testable import SneakPeek

private func fixture(_ directory: URL, demo: Bool = false) throws -> Feed {
    let now = Date().timeIntervalSince1970
    let data: [String: Any] = ["generatedAt": now, "demo": demo,
        "missions": [["id": "m", "title": "Mission", "goal": "An inspectable outcome", "checkpoints": [
            ["id": "a", "label": "Check", "status": "reported", "evidence": "Original A", "source": "agent"],
            ["id": "b", "label": "Check", "status": "reported", "evidence": "Original B", "source": "agent"]]]],
        "agents": demo ? [] : [["id": "claude:one", "missionId": "m", "name": "One", "provider": "Claude",
            "status": "attention", "summary": "Waiting", "lastActivity": now, "lastProgress": now,
            "evidence": "Original A", "nextStep": "Review", "trajectory": "unknown",
            "request": ["id": UUID().uuidString, "title": "Allow?", "detail": "A synthetic command", "mode": "decision", "transport": "trusted-local-file",
                        "choices": [["id": "accept", "label": "Allow once"]], "expiresAt": now + 300]]]]
    let encoded = try JSONSerialization.data(withJSONObject: data)
    try encoded.write(to: directory.appendingPathComponent(demo ? "demo-state.json" : "state.json"))
    return try JSONDecoder().decode(Feed.self, from: encoded)
}

@Test @MainActor func demoAndUnreadableFeedDisableApprovalSurface() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory); _ = try fixture(directory, demo: true)
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: false)
    func surface() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("approval-surface.json"))) as! [String: Any]
    }
    #expect(try surface()["live"] as? Bool == true)
    _ = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: true, ownsApprovalSurface: false)
    #expect(try surface()["live"] as? Bool == true) // previews never overwrite the real surface
    store.toggleMode()
    #expect(try surface()["live"] as? Bool == false)
    store.toggleMode()
    try Data("[]".utf8).write(to: directory.appendingPathComponent("state.json"))
    store.reload()
    #expect(try surface()["live"] as? Bool == false)
}

@Test @MainActor func sentDecisionRemainsBoundToLiveContext() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory); _ = try fixture(directory, demo: true)
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: false)
    let agent = store.feed.agents[0]
    store.answer(agent, agent.request!.choices[0])
    #expect(store.sentRequests.contains(agent.request!.id))
    store.toggleMode()
    #expect(store.sentRequests.isEmpty)
    #expect(store.message != "The example agent received your decision.")
    store.toggleMode()
    #expect(store.sentRequests.contains(agent.request!.id))
    var cleared = store.feed
    cleared.agents[0].request = nil
    try JSONEncoder().encode(cleared).write(to: store.stateURL)
    store.reload()
    #expect(store.sentRequests.isEmpty)
    #expect(store.message == "Request cleared by the source · check the latest agent status")
}

@Test @MainActor func titleEditAndVerificationMergeLatestEvidence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let feed = try fixture(directory)
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: false)
    let folder = directory.appendingPathComponent("missions")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = folder.appendingPathComponent(MissionPersistence.fileName("m"))
    var latest = feed.missions[0]
    latest.checkpoints[1].evidence = "New B from an agent"
    try JSONEncoder().encode(latest).write(to: path, options: .atomic)
    store.verify(feed.missions[0].checkpoints[0])
    latest = try JSONDecoder().decode(Mission.self, from: Data(contentsOf: path))
    #expect(latest.checkpoints[0].verified)
    #expect(latest.checkpoints[1].evidence == "New B from an agent")
    var edited = feed.missions[0]; edited.title = "Only title changed"
    #expect(store.saveMission(edited, base: feed.missions[0]))
    latest = try JSONDecoder().decode(Mission.self, from: Data(contentsOf: path))
    #expect(latest.checkpoints[0].verified)
    #expect(latest.checkpoints[1].evidence == "New B from an agent")
    #expect(!store.saveMission(edited, base: feed.missions[0])) // stale definition revision
}

@Test func changedEvidenceCannotBeVerifiedFromLaggingFeed() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = try fixture(directory).missions[0]
    var latest = base; latest.checkpoints[0].evidence = "Changed report"
    try JSONEncoder().encode(latest).write(to: directory.appendingPathComponent(MissionPersistence.fileName("m")))
    #expect(throws: MissionSaveError.self) {
        try MissionPersistence.verify(base.checkpoints[0], base: base, directory: directory)
    }
}

@Test func rowEditingKeepsDuplicateLabelsIndependentAndFiltersBlanks() {
    let rows = [Checkpoint(id: "a", label: "Same", status: "pending", evidence: "A", source: "human"),
                Checkpoint(id: "b", label: "Same", status: "pending", evidence: "B", source: "human"),
                Checkpoint(id: "c", label: "  ", status: "pending", evidence: "C", source: "human")]
    let edited = MissionEditing.nonblank(rows)
    #expect(edited.map(\.id) == ["a", "b"])
    #expect(edited.map(\.evidence) == ["A", "B"])
}

@Test @MainActor func unmarkedLiveRequestCannotWriteUnsignedDecision() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory)
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: false)
    var agent = store.feed.agents[0]
    agent.request?.transport = nil
    store.answer(agent, agent.request!.choices[0])
    #expect(store.sentRequests.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("decisions").path))
    #expect(store.message == "Answer this permission in its source session")
}
