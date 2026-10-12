import Foundation
import Testing
import SneakPeekCore
@testable import SneakPeek

@Test @MainActor func unreadableFeedClearsPreviouslySimulatedAcceptance() throws {
    let state = try HumanActionSimulationFixture.create()
    defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
    let input = try JSONDecoder().decode(Feed.self, from: Data(contentsOf: state))
    let mission = input.missions[0], evidence = mission.checkpoints[0].records![0]
    let session = HumanActionSimulation(), time = Date().timeIntervalSince1970
    let definition = try session.prepare(kind: .confirmDefinition, mission: mission, now: time)
    try session.finish(definition, mockBiometrySucceeded: true, currentMission: mission, now: time)
    let review = try session.prepare(kind: .reviewEvidence, mission: mission, now: time + 0.1,
        checkpointID: evidence.checkpointId, subjectID: evidence.id,
        subjectDigest: HumanContext.evidenceDigest(evidence), value: "accept")
    try session.finish(review, mockBiometrySucceeded: true, currentMission: mission, now: time + 0.1)
    let store = PeekStore(stateURL: state, demo: false, ownsApprovalSurface: false, automaticReload: false, humanActionSimulation: session)
    #expect(store.feed.missions[0].assessment?.simulatedVerifiedCount == 1)
    try Data("broken JSON".utf8).write(to: state)
    try FileManager.default.removeItem(atPath: evidence.reference!)
    store.reload()
    #expect(store.feed.missions[0].assessment?.simulatedVerifiedCount == 0)
    #expect(store.feed.missions[0].assessment?.verifiedCount == 0)
    #expect(store.message?.contains("could not be read") == true)
}

@Test @MainActor func normalStoreCannotEnableSimulationFromFeedOrWriteUnsignedHumanActions() throws {
    let state = try HumanActionSimulationFixture.create()
    defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
    var input = try JSONDecoder().decode(Feed.self, from: Data(contentsOf: state))
    input.missions[0].checkpoints[0].status = "verified"
    input.missions[0].checkpoints[0].authentication = "authenticated"
    try JSONEncoder().encode(input).write(to: state)
    let store = PeekStore(stateURL: state, demo: false, ownsApprovalSurface: false, automaticReload: false)
    #expect(!store.isHumanActionSimulation)
    #expect(store.feed.missions[0].assessment?.verifiedCount == 0)
    let mission = store.feed.missions[0], evidence = mission.checkpoints[0].records![0]
    store.review(evidence, mission: mission, verdict: "accept")
    #expect(store.message?.contains("unavailable") == true)
    store.post("taste", payload: ["missionId": mission.id, "goalRevision": mission.goalRevision!,
        "checkpointId": "presentation", "acceptance": "accept", "valence": "right", "strength": "hunch", "impact": "note"])
    #expect(!store.recording)
    #expect(store.message?.contains("unavailable") == true)
    #expect(!FileManager.default.fileExists(atPath: state.deletingLastPathComponent().appendingPathComponent("taste").path))
    #expect(!FileManager.default.fileExists(atPath: state.deletingLastPathComponent().appendingPathComponent("evidence-reviews").path))
    #expect(!FileManager.default.fileExists(atPath: state.deletingLastPathComponent().appendingPathComponent("approval-surface.json").path))
}
