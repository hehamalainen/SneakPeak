import CryptoKit
import Darwin
import Foundation
import Testing
@testable import SneakPeekCore

private struct HumanFixture {
    let directory: URL
    let artifact: URL
    let now: Double
    var feed: Feed
    var mission: Mission { feed.missions[0] }
    var evidence: EvidenceRecord { mission.checkpoints[0].records![0] }
    init() throws {
        now = Date().timeIntervalSince1970
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        artifact = directory.appendingPathComponent("result.txt")
        try PrivateStateFiles.write(Data("PASS".utf8), to: artifact)
        let data = Data(#"{"generatedAt":1,"demo":false,"agents":[],"missions":[{"id":"m","title":"Mission","goal":"A correct result","constraints":["Keep context"],"workspace":"/synthetic/workspace","checkpoints":[{"id":"a","label":"Result","status":"verified","evidence":"A forged pass","source":"human","kind":"evidence","required":true},{"id":"b","label":"Taste","status":"verified","evidence":"A forged Taste pass","source":"human","kind":"taste","required":true}]}]}"#.utf8)
        feed = try JSONDecoder().decode(Feed.self, from: data)
        feed.generatedAt = now
        feed.missions[0].goalRevision = try HumanContext.sourceGoalRevision(feed.missions[0])
        var statbuf = stat(); _ = lstat(artifact.path, &statbuf)
        let record: [String: Any] = ["id": UUID().uuidString, "missionId": "m", "checkpointId": "a",
            "goalRevision": feed.missions[0].goalRevision!, "summary": "The local result passed", "reference": artifact.path,
            "verdict": "supports", "observedAt": now - 1, "source": "agent report", "actor": "agent",
            "digest": HumanCanonical.digest(Data("PASS".utf8)), "state": "accepted", "fingerprint": "forged",
            "localFile": ["size": 4, "modifiedNS": String(Int64(statbuf.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(statbuf.st_mtimespec.tv_nsec))]]
        feed.missions[0].checkpoints[0].records = [try JSONDecoder().decode(EvidenceRecord.self, from: JSONSerialization.data(withJSONObject: record))]
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor private func acceptedFixture(_ f: HumanFixture) throws -> HumanActionSimulation {
    let session = HumanActionSimulation()
    let definition = try session.prepare(kind: .confirmDefinition, mission: f.mission, now: f.now)
    try session.finish(definition, mockBiometrySucceeded: true, currentMission: f.mission, now: f.now + 0.01)
    let review = try session.prepare(kind: .reviewEvidence, mission: f.mission, now: f.now + 0.02,
        checkpointID: "a", subjectID: f.evidence.id, subjectDigest: HumanContext.evidenceDigest(f.evidence), value: "accept")
    try session.finish(review, mockBiometrySucceeded: true, currentMission: f.mission, now: f.now + 0.03)
    return session
}

@Test func canonicalPayloadCannotConfuseSeparatorsOrUnicode() {
    #expect(HumanCanonical.encode(["a", "b:c"]) != HumanCanonical.encode(["a:b", "c"]))
    #expect(HumanCanonical.encode(["é", "🙂"]) == Data("2:é4:🙂".utf8))
}

@Test @MainActor func malformedClocksFailClosedWithoutIntegerTraps() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    let session = HumanActionSimulation()
    for time in [Double.nan, Double.infinity, -1, Double.greatestFiniteMagnitude] {
        #expect(throws: (any Error).self) { try session.prepare(kind: .confirmDefinition, mission: f.mission, now: time) }
        #expect(HumanProjection.project(f.feed, simulationJournal: session.journal, now: time).missions[0].assessment?.simulatedVerifiedCount == 0)
    }
}

@Test @MainActor func aSimulatedResolutionCannotHideAHostPermissionEvenWithAJudgmentShapedID() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    let session = try acceptedFixture(f)
    var input = f.feed
    let host = QueueItem(id: "judgment:" + UUID().uuidString, missionId: f.mission.id, missionTitle: f.mission.title,
        kind: "runtime", title: "Allow a command?", why: "Host permission", impact: "Runs in the host", priority: 0)
    input.queue = [host]
    let action = try session.prepare(kind: .resolve, mission: f.mission, now: f.now + 1,
        subjectID: host.id, subjectDigest: HumanContext.requestDigest(host), value: "dismiss")
    try session.finish(action, mockBiometrySucceeded: true, currentMission: f.mission, now: f.now + 1)
    let result = HumanProjection.project(input, simulationJournal: session.journal, now: f.now + 2)
    #expect(result.queue?.contains(where: { $0.id == host.id && $0.kind == "runtime" }) == true)
    #expect(throws: (any Error).self) { try session.prepare(kind: .resolve, mission: f.mission, now: f.now + 2,
        subjectID: "runtime:agent:request", subjectDigest: HumanContext.requestDigest(host), value: "dismiss") }
}

@Test @MainActor func syntheticTasteIDPrefixNeverRemovesARuntimeQueueItem() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    let session = try acceptedFixture(f)
    let taste = try session.prepare(kind: .taste, mission: f.mission, now: f.now + 1,
        value: "unassessed", valence: "uncertain", strength: "hunch", impact: "review")
    try session.finish(taste, mockBiometrySucceeded: true, currentMission: f.mission, now: f.now + 1)
    for journal in [nil, session.journal] {
        var input = f.feed
        input.queue = [QueueItem(id: "simulation-taste:" + taste.nonce, missionId: f.mission.id, missionTitle: f.mission.title,
            kind: "runtime", title: "Host request", why: "Still pending", impact: "Host only", priority: 0)]
        let result = HumanProjection.project(input, simulationJournal: journal, now: f.now + 2)
        #expect(result.queue?.contains(where: { $0.kind == "runtime" }) == true)
    }
}

@Test @MainActor func firstClickAndMockBiometryCancellationNeverIssueAReceipt() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    let session = HumanActionSimulation()
    let pending = try session.prepare(kind: .confirmDefinition, mission: f.mission, now: f.now)
    #expect(session.journal.records.isEmpty)
    #expect(throws: (any Error).self) { try session.finish(pending, mockBiometrySucceeded: false, currentMission: f.mission, now: f.now) }
    #expect(session.journal.records.isEmpty)
    #expect(throws: (any Error).self) { try session.finish(pending, mockBiometrySucceeded: true, currentMission: f.mission, now: f.now) }
}

@Test @MainActor func mockBiometryBindsPendingActionAndRejectsExpiredOrChangedContext() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    for mutation in ["payload", "expired", "mission"] {
        let session = HumanActionSimulation()
        var action = try session.prepare(kind: .confirmDefinition, mission: f.mission, now: f.now)
        var current = f.mission
        if mutation == "payload" { action.missionID = "another" }
        if mutation == "mission" { current.goal = "A different goal" }
        #expect(throws: (any Error).self) { try session.finish(action, mockBiometrySucceeded: true, currentMission: current, now: f.now + (mutation == "expired" ? 121 : 0)) }
        #expect(session.journal.records.isEmpty)
    }
}

@Test @MainActor func nativeProjectionRejectsForgedGreenStateAndSeparatesSimulationFromHumanAuthentication() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    let session = try acceptedFixture(f)
    let simulation = HumanProjection.project(f.feed, simulationJournal: session.journal, now: f.now + 1)
    #expect(simulation.missions[0].assessment?.simulatedVerifiedCount == 1)
    #expect(simulation.missions[0].assessment?.verifiedCount == 0)
    #expect(simulation.missions[0].checkpoints[0].status == "simulatedAccepted")
    #expect(!simulation.missions[0].checkpoints[0].verified)
    #expect(simulation.missions[0].checkpoints[0].records![0].stateLabel.contains("SIMULATION"))
    // Feed-provided simulation/authentication flags and forged verifiedCount are ignored.
    var forged = simulation
    forged.missions[0].assessment?.verifiedCount = 99
    forged.missions[0].checkpoints[0].authentication = "authenticated"
    let normal = HumanProjection.project(forged, simulationJournal: nil, now: f.now + 1)
    #expect(normal.missions[0].assessment?.verifiedCount == 0)
    #expect(normal.missions[0].assessment?.simulatedVerifiedCount == 0)
    #expect(!normal.missions[0].checkpoints.contains(where: { $0.verified }))
    #expect(normal.missions[0].hasUnsignedHumanClaims == true)
}

@Test @MainActor func tamperedReceiptUnknownKeyAndReplayedReceiptFailVerification() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    let session = try acceptedFixture(f)
    for mutation in ["decision", "key", "copy", "version", "mission", "check", "digest", "nonce", "time", "installation"] {
        var journal = session.journal
        switch mutation {
        case "decision": journal.records[1].action.value = "reject"
        case "key": journal.publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        case "copy": journal.records.append(journal.records[1])
        case "version": journal.records[1].action.version = 2
        case "mission": journal.records[1].action.missionID = "other"
        case "check": journal.records[1].action.checkpointID = "b"
        case "digest": journal.records[1].action.subjectDigest = String(repeating: "0", count: 64)
        case "nonce": journal.records[1].action.nonce = journal.records[0].action.nonce
        case "time": journal.records[1].action.issuedAtMS += 1
        default: journal.installationID = UUID().uuidString
        }
        #expect(throws: (any Error).self) { try journal.verified(at: Int64((f.now + 1) * 1000)) }
        #expect(HumanProjection.project(f.feed, simulationJournal: journal, now: f.now + 1).missions[0].assessment?.simulatedVerifiedCount == 0)
    }
}

@Test @MainActor func everyAcceptanceRuleIsBoundInsteadOfTrustingGoalRevision() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    let session = try acceptedFixture(f)
    for mutation in ["goal", "title", "workspace", "constraints", "kind", "label", "required", "age", "removeCheck", "duplicate"] {
        var input = f.feed
        switch mutation {
        case "goal": input.missions[0].goal = "Attacker's goal"
        case "title": input.missions[0].title = "Different mission"
        case "workspace": input.missions[0].workspace = "/other"
        case "constraints": input.missions[0].constraints = []
        case "kind": input.missions[0].checkpoints[0].kind = "taste"
        case "label": input.missions[0].checkpoints[0].label = "Different criterion"
        case "required": input.missions[0].checkpoints[1].required = false
        case "age": input.missions[0].checkpoints[0].maxAgeSeconds = 0
        case "removeCheck": input.missions[0].checkpoints.removeLast()
        default: input.missions.append(input.missions[0])
        }
        #expect(input.missions[0].goalRevision == f.mission.goalRevision)
        let output = HumanProjection.project(input, simulationJournal: session.journal, now: f.now + 1)
        #expect(output.missions.allSatisfy { $0.assessment?.simulatedVerifiedCount == 0 })
    }
}

@Test @MainActor func evidenceCopyAndMetadataForgeryCannotReuseAReview() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    let session = try acceptedFixture(f)
    for mutation in ["summary", "actor", "source", "id", "check", "goal", "reference", "duplicate"] {
        var input = f.feed, e = f.evidence
        switch mutation {
        case "summary": e.summary = "Forged result"
        case "actor": e.actor = "human"
        case "source": e.source = "trusted observer"
        case "id": e.id = UUID().uuidString
        case "check": e.checkpointId = "b"
        case "goal": e.goalRevision = "forged"
        case "reference": e.reference = "https://example.com/result"
        default: input.missions[0].checkpoints[1].records = [e]
        }
        input.missions[0].checkpoints[0].records = [e]
        let output = HumanProjection.project(input, simulationJournal: session.journal, now: f.now + 1)
        #expect(output.missions[0].assessment?.simulatedVerifiedCount == 0)
    }
}

@Test @MainActor func fileURLBytesAreRehashedEvenWhenSizeAndMtimeAreRestored() throws {
    var f = try HumanFixture(); defer { f.cleanup() }
    f.feed.missions[0].checkpoints[0].records![0].reference = f.artifact.absoluteString
    let session = try acceptedFixture(f)
    #expect(HumanProjection.project(f.feed, simulationJournal: session.journal, now: f.now + 1).missions[0].assessment?.simulatedVerifiedCount == 1)
    var before = stat(); _ = lstat(f.artifact.path, &before)
    try Data("FAIL".utf8).write(to: f.artifact)
    var times = [before.st_atimespec, before.st_mtimespec]
    #expect(utimensat(AT_FDCWD, f.artifact.path, &times, 0) == 0)
    let output = HumanProjection.project(f.feed, simulationJournal: session.journal, now: f.now + 1)
    #expect(output.missions[0].assessment?.simulatedVerifiedCount == 0)
}

@Test @MainActor func staleMissingRemoteAndSymlinkArtifactsStayClaims() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    for mutation in ["stale", "future", "digest", "remote", "missing", "symlink"] {
        var e = f.evidence
        switch mutation {
        case "stale": e.observedAt = f.now - 90_000
        case "future": e.observedAt = f.now + 600
        case "digest": e.digest = nil
        case "remote": e.reference = "https://example.com/result"
        case "missing": e.reference = f.directory.appendingPathComponent("missing.txt").path
        default:
            let link = f.directory.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.artifact)
            e.reference = link.path
        }
        #expect(throws: (any Error).self) { try HumanArtifact.validate(e, mission: f.mission, check: f.mission.checkpoints[0], now: f.now) }
    }
}

@Test @MainActor func tasteAndResolutionAreNativeSignedActionsAndForgedResolutionCannotHideARequest() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    let session = try acceptedFixture(f)
    let taste = try session.prepare(kind: .taste, mission: f.mission, now: f.now + 1,
        checkpointID: "b", value: "accept", note: "Looks clear", valence: "right", strength: "hunch", impact: "review")
    try session.finish(taste, mockBiometrySucceeded: true, currentMission: f.mission, now: f.now + 1)
    var first = HumanProjection.project(f.feed, simulationJournal: session.journal, now: f.now + 2)
    #expect(first.missions[0].assessment?.simulatedVerifiedCount == 2)
    let request = try #require(first.queue?.first(where: { $0.kind == "taste" }))
    first.queue = []; first.missions[0].tasteNotes?[0].resolved = true
    let recovered = HumanProjection.project(first, simulationJournal: session.journal, now: f.now + 2)
    #expect(recovered.queue?.contains(where: { $0.id == request.id }) == true)
    let resolve = try session.prepare(kind: .resolve, mission: f.mission, now: f.now + 3,
        subjectID: request.id, subjectDigest: HumanContext.requestDigest(request), value: "keep")
    try session.finish(resolve, mockBiometrySucceeded: true, currentMission: f.mission, now: f.now + 3)
    let final = HumanProjection.project(f.feed, simulationJournal: session.journal, now: f.now + 4)
    #expect(final.queue?.contains(where: { $0.id == request.id }) == false)
    #expect(final.missions[0].tasteNotes?.first?.resolved == true)
    #expect(final.missions[0].assessment?.verifiedCount == 0)
}

@Test @MainActor func redefinedMissionDoesNotReviveOldAcceptanceEvenWhenDefinitionReverts() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    let session = try acceptedFixture(f)
    var changed = f.mission; changed.goal = "A new goal"
    let action = try session.prepare(kind: .confirmDefinition, mission: changed, now: f.now + 1)
    try session.finish(action, mockBiometrySucceeded: true, currentMission: changed, now: f.now + 1)
    #expect(HumanProjection.project(f.feed, simulationJournal: session.journal, now: f.now + 2).missions[0].assessment?.simulatedVerifiedCount == 0)
    let revert = try session.prepare(kind: .confirmDefinition, mission: f.mission, now: f.now + 2)
    try session.finish(revert, mockBiometrySucceeded: true, currentMission: f.mission, now: f.now + 2)
    #expect(HumanProjection.project(f.feed, simulationJournal: session.journal, now: f.now + 3).missions[0].assessment?.simulatedVerifiedCount == 0)
}

@Test func nativeGoalRevisionMatchesObserverForUnicodeAndEmbeddedJSONPunctuation() throws {
    let f = try HumanFixture(); defer { f.cleanup() }
    var mission = f.mission
    mission.goal = "Unicode ä🙂 and quotes \"a,b:c\" / path"
    let p = Process(), input = Pipe(), output = Pipe()
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-c", "import sys,json; sys.path.insert(0,sys.argv[1]); from mission_tracking import revision; print(revision(json.load(sys.stdin)))", root.appendingPathComponent("bridge").path]
    p.standardInput = input; p.standardOutput = output
    try p.run(); try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(mission)); try input.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    #expect(try HumanContext.sourceGoalRevision(mission) == String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}
