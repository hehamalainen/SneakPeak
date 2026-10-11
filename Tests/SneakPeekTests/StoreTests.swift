import Foundation
import Testing
import SneakPeekCore
import CryptoKit
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

@Test @MainActor func titleEditUsesSidecarWriterAndVerificationRequiresInspection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let state = directory.appendingPathComponent("state.json")
    let project = Process()
    project.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    project.arguments = ["python3", "-c", #"import sys,json; from pathlib import Path; sys.path.insert(0,sys.argv[1]); from mission_tracking import project; p=Path(sys.argv[2]); p.write_text(json.dumps(project(json.loads(p.read_text()),p.parent)))"#, root.appendingPathComponent("bridge").path, state.path]
    try project.run(); project.waitUntilExit()
    #expect(project.terminationStatus == 0)
    let store = PeekStore(stateURL: state, demo: false, missionCommandURL: root.appendingPathComponent("bridge/mission_commands.py"))
    let feed = store.feed
    let folder = directory.appendingPathComponent("missions")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = SHA256.hash(data: Data("m".utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    let path = folder.appendingPathComponent(name)
    var latest = feed.missions[0]
    latest.checkpoints[1].evidence = "New B from an agent"
    try JSONEncoder().encode(latest).write(to: path, options: .atomic)
    var inspected = false
    store.onInspectMission = { _ in inspected = true }
    store.verify(feed.missions[0].checkpoints[0])
    latest = try JSONDecoder().decode(Mission.self, from: Data(contentsOf: path))
    #expect(inspected)
    #expect(!latest.checkpoints[0].verified)
    #expect(latest.checkpoints[1].evidence == "New B from an agent")
    var edited = feed.missions[0]; edited.title = "Only title changed"
    let saved = await withCheckedContinuation { continuation in
        store.saveMission(edited) { continuation.resume(returning: $0) }
    }
    #expect(saved)
    latest = try JSONDecoder().decode(Mission.self, from: Data(contentsOf: path))
    #expect(!latest.checkpoints[0].verified)
    #expect(latest.checkpoints[1].evidence == "New B from an agent")
    let stale = await withCheckedContinuation { continuation in
        store.saveMission(edited) { continuation.resume(returning: $0) }
    }
    #expect(!stale)
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
