import Foundation
import Combine
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

@Test @MainActor func otterAppearancePersistsAndPreviewOverrideDoesNotSave() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory)
    let state = directory.appendingPathComponent("state.json")
    let store = PeekStore(stateURL: state, demo: false, ownsApprovalSurface: false)
    #expect(store.companionMode == .native)
    var resized = false
    store.onResize = { resized = true }
    store.setCompanionMode(.otter)
    #expect(resized)
    let restored = PeekStore(stateURL: state, demo: false, ownsApprovalSurface: false)
    #expect(restored.companionMode == .otter)
    restored.setCompanionMode(.native, persist: false)
    #expect(restored.companionMode == .native)
    #expect(PeekStore(stateURL: state, demo: false, ownsApprovalSurface: false).companionMode == .otter)
    store.setCompanionMode(.native)
    #expect(PeekStore(stateURL: state, demo: false, ownsApprovalSurface: false).companionMode == .native)
}

@Test @MainActor func otterSeparatesAttentionActivityAndUnverifiedRest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory)
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: false, ownsApprovalSurface: false)
    #expect(store.otterStatus.pose == .attention)
    // Filtering never hides a decision in another source from the companion.
    store.filterProvider("Codex")
    #expect(store.otterStatus.title == "One decision needs you")
    store.feed.agents[0].request = nil
    store.feed.agents[0].status = "working"
    #expect(store.otterStatus.pose == .peeking)
    #expect(store.otterStatus.tone == .working)
    store.feed.agents[0].status = "done"
    #expect(store.otterStatus.pose == .unseen) // Legacy feed has no confirmed queue.
    store.feed.queue = []
    #expect(store.otterStatus.pose == .resting)
    #expect(store.otterStatus.title == "Room to focus")
    #expect(!store.feed.missions[0].checkpoints[0].verified)
    store.feed.agents[0].status = "working"
    store.feed.agents[0].lastActivity = store.now - 301
    #expect(store.otterStatus.pose == .unseen)
    #expect(store.otterStatus.title == "An agent has gone quiet")
    store.feed.agents[0].status = "done"
    store.feed.warnings = ["Some sessions were omitted"]
    #expect(store.otterStatus.pose == .unseen)
    #expect(store.otterStatus.title == "Coverage incomplete")
    store.feed.generatedAt = store.now - 11
    #expect(store.otterStatus.tone == .muted)
    #expect(store.otterStatus.pose == .unseen)
    #expect(store.otterStatus.title == "I can’t see right now")
}

@Test @MainActor func raftLinksOnlyFreshReportedCourseAndKeepsEvidenceGapsVisible() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory)
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: false, ownsApprovalSurface: false)
    store.feed.queue = []
    var agent = store.feed.agents[0]
    agent.request = nil; agent.status = "working"; agent.trajectory = "onCourse"
    #expect(raftCourse(agent, store: store) == .onCourse)
    agent.trajectory = "atRisk"
    #expect(raftCourse(agent, store: store) == .atRisk)
    agent.lastProgress = store.now - 301
    #expect(raftCourse(agent, store: store) == .unknown)
    agent.lastProgress = store.now; agent.progressFreshness = "stale"
    #expect(raftCourse(agent, store: store) == .unknown)
    agent.progressFreshness = nil; agent.lastActivity = store.now - 301
    #expect(raftCourse(agent, store: store) == .unknown)
    agent.lastActivity = store.now; store.feed.generatedAt = store.now - 11
    #expect(raftCourse(agent, store: store) == .unknown)
    store.feed.generatedAt = store.now
    store.feed.agents = []
    let assessment: [String: Any] = ["goalRevision": "r", "course": "unknown", "evidence": "missing",
        "requiredCount": 1, "verifiedCount": 0, "reportedCount": 0, "missingCount": 1,
        "staleCount": 0, "conflictCount": 0, "decisionCount": 0, "coverageIncomplete": false, "reasons": []]
    store.feed.missions[0].assessment = try JSONDecoder().decode(MissionAssessment.self, from: JSONSerialization.data(withJSONObject: assessment))
    #expect(store.otterStatus.pose == .peeking)
    #expect(store.otterStatus.title == "Evidence needs a look")
    store.feed.missions[0].assessment?.course = "suspectedDrift"
    #expect(store.otterStatus.title == "A course concern")
}

@Test @MainActor func playgroundGesturesUseSyntheticMemoryWithoutTouchingState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory)
    let state = directory.appendingPathComponent("state.json")
    let original = try Data(contentsOf: state)
    let store = PeekStore(stateURL: state, demo: false, ownsApprovalSurface: false, automaticReload: false)
    let preview = OtterPlaygroundModel(store: store)
    #expect(store.feed.agents.allSatisfy { $0.provider == "Example" })
    preview.select(.attention)
    #expect(store.otterStatus.pose == .attention)
    let firstRequest = store.otterAttentionSignature
    preview.select(.attention)
    #expect(store.otterAttentionSignature != firstRequest)
    preview.select(.unseen)
    #expect(store.disconnected)
    #expect(store.otterStatus.pose == .unseen)
    preview.select(.quiet)
    #expect(!store.disconnected)
    #expect(store.otterStatus.pose == .unseen)
    preview.select(.resting)
    #expect(store.otterStatus.pose == .resting)
    preview.select(.drift)
    #expect(store.feed.agents.filter { raftCourse($0, store: store) == .atRisk }.count == 1)
    preview.select(.rejoin)
    #expect(store.feed.agents.allSatisfy { raftCourse($0, store: store) == .onCourse })
    #expect(try Data(contentsOf: state) == original)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("approval-surface.json").path))
}

@Test @MainActor func coveSleepingPairRequiresFreshClearQueueAndTwoFreshReports() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: true,
                          ownsApprovalSurface: false, automaticReload: false)
    let preview = OtterPlaygroundModel(store: store)
    let first = store.feed.agents[0], second = store.feed.agents[1]
    #expect(coveMaySleep(store: store, first: first, second: second))
    #expect(!coveMaySleep(store: store, first: first, second: nil))
    store.feed.queue = nil
    #expect(!coveMaySleep(store: store, first: first, second: second))
    preview.select(.attention)
    #expect(!coveMaySleep(store: store, first: store.feed.agents[0], second: store.feed.agents[1]))
    preview.select(.drift)
    #expect(!coveMaySleep(store: store, first: store.feed.agents[0], second: store.feed.agents[1]))
    preview.select(.quiet)
    #expect(!coveMaySleep(store: store, first: store.feed.agents[0], second: store.feed.agents[1]))
    preview.select(.unseen)
    #expect(!coveMaySleep(store: store, first: store.feed.agents[0], second: store.feed.agents[1]))
    preview.select(.raft)
    store.feed.generatedAt = store.now - 11 // Demo mode is no excuse for stale sleep.
    #expect(!coveMaySleep(store: store, first: store.feed.agents[0], second: store.feed.agents[1]))
    preview.select(.raft)
    store.feed.warnings = ["Some sessions were omitted"]
    #expect(!coveMaySleep(store: store, first: store.feed.agents[0], second: store.feed.agents[1]))
}

@Test @MainActor func manualGestureSelectionCancelsAutoplay() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: true,
                          ownsApprovalSurface: false, automaticReload: false)
    let preview = OtterPlaygroundModel(store: store)
    preview.playAll(stepDuration: .milliseconds(20))
    try await waitForDemo { (preview.currentStep ?? 0) >= 1 }
    preview.select(.unseen)
    let replay = preview.replay
    #expect(!preview.playing)
    try await Task.sleep(for: .milliseconds(200))
    #expect(preview.scene == .unseen)
    #expect(preview.replay == replay)
    #expect(store.otterStatus.pose == .unseen)
}

@MainActor private func waitForDemo(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !condition(), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition(), "The synthetic demo did not reach the expected state.")
}

@Test @MainActor func presenterWalkthroughFinishesOnceWithPawsHeld() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: true,
                          ownsApprovalSurface: false, automaticReload: false)
    let preview = OtterPlaygroundModel(store: store)
    #expect(preview.scene == .raft)
    #expect(coveMaySleep(store: store, first: store.feed.agents[0], second: store.feed.agents[1]))
    var shownScenes: [OtterDemoScene] = []
    let subscription = preview.$scene.dropFirst().sink { shownScenes.append($0) }
    defer { subscription.cancel() }
    preview.playAll(stepDuration: .milliseconds(20))
    #expect(preview.playing)
    try await waitForDemo { !preview.playing }
    #expect(preview.scene == .raft)
    #expect(preview.progress == 1)
    #expect(shownScenes.first == .raft)
    #expect(shownScenes.last == .raft)
    for gesture in [OtterDemoScene.working, .attention, .resting, .drift, .rejoin, .unseen] {
        #expect(shownScenes.filter { $0 == gesture }.count == 1)
    }
    #expect(store.showingDemo)
    #expect(store.feed.agents.allSatisfy { $0.provider == "Example" })
    #expect(coveMaySleep(store: store, first: store.feed.agents[0], second: store.feed.agents[1]))
    let replay = preview.replay
    try await Task.sleep(for: .milliseconds(60))
    #expect(!preview.playing)
    #expect(preview.scene == .raft)
    #expect(preview.replay == replay)
}

@Test @MainActor func stoppingPresenterWalkthroughKeepsTheCurrentScene() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: true,
                          ownsApprovalSurface: false, automaticReload: false)
    let preview = OtterPlaygroundModel(store: store)
    preview.playAll(stepDuration: .milliseconds(20))
    try await waitForDemo { (preview.currentStep ?? 0) >= 1 }
    preview.stop()
    let scene = preview.scene
    let replay = preview.replay
    let step = preview.currentStep
    let progress = preview.progress
    #expect(!preview.playing)
    try await Task.sleep(for: .milliseconds(200))
    #expect(!preview.playing)
    #expect(preview.scene == scene)
    #expect(preview.replay == replay)
    #expect(preview.currentStep == step)
    #expect(preview.progress == progress)
}

@Test @MainActor func acknowledgingCoveExampleClearsThePawWithoutWritingDecisions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory)
    _ = try fixture(directory, demo: true)
    let state = directory.appendingPathComponent("state.json")
    let demoState = directory.appendingPathComponent("demo-state.json")
    let surface = directory.appendingPathComponent("approval-surface.json")
    try Data(#"{"live":true,"owner":"existing app"}"#.utf8).write(to: surface)
    let originals = try [state, demoState, surface].map { try Data(contentsOf: $0) }
    let store = PeekStore(stateURL: state, demo: false, ownsApprovalSurface: false, automaticReload: false)
    let preview = OtterPlaygroundModel(store: store)
    preview.select(.attention)
    #expect(store.attentionCount == 1)
    #expect(store.otterStatus.pose == .attention)
    preview.acknowledgeExample()
    #expect(preview.scene == .working)
    #expect(store.attentionCount == 0)
    #expect(store.otterStatus.pose == .peeking)
    #expect(store.showingDemo)
    #expect(try [state, demoState, surface].map { try Data(contentsOf: $0) } == originals)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("decisions").path))
    let replay = preview.replay
    preview.acknowledgeExample()
    #expect(preview.replay == replay)
    preview.select(.attention)
    store.feed.agents[0].provider = "Live source"
    let guardedReplay = preview.replay
    preview.acknowledgeExample()
    #expect(preview.scene == .attention)
    #expect(store.attentionCount == 1)
    #expect(preview.replay == guardedReplay)
    #expect(try [state, demoState, surface].map { try Data(contentsOf: $0) } == originals)
}

@Test(arguments: [CoveLaunchConfiguration.previewIdentifier, CoveLaunchConfiguration.demoIdentifier, CoveLaunchConfiguration.gestureIdentifier])
func isolatedCoveLaunchCannotUseLiveStateOrStartAnObserver(bundleIdentifier: String) {
    let previewState = URL(fileURLWithPath: "/tmp/cove-demo/state.json")
    let liveState = "/tmp/live-jobs/state.json"
    let interactive = CoveLaunchConfiguration(bundleIdentifier: bundleIdentifier, defaultStateURL: previewState,
                                               stateOverride: liveState, renderOnly: false)
    #expect(interactive.isolated)
    #expect(!interactive.renderOnly)
    #expect(interactive.stateURL == previewState)
    #expect(!interactive.startsObserver)
    #expect(!interactive.ownsApprovalSurface)
    #expect(!interactive.reloadsFeed)
    #expect(!interactive.loadsInitialFeed)
    #expect(!interactive.persistsAppearance)

    let render = CoveLaunchConfiguration(bundleIdentifier: bundleIdentifier, defaultStateURL: previewState,
                                        stateOverride: "/tmp/render-fixture/state.json", renderOnly: true)
    #expect(render.isolated)
    #expect(render.renderOnly)
    #expect(render.stateURL == URL(fileURLWithPath: "/tmp/render-fixture/state.json"))
    #expect(render.loadsInitialFeed)
    #expect(!render.startsObserver)
    #expect(!render.ownsApprovalSurface)
    #expect(!render.reloadsFeed)
    #expect(!render.persistsAppearance)
}

@Test func nativeLaunchKeepsItsLiveConnectionAndCoveNotificationsStaySeparate() {
    let defaultState = URL(fileURLWithPath: "/tmp/native-state.json")
    let override = "/tmp/requested-live-state.json"
    let native = CoveLaunchConfiguration(bundleIdentifier: "local.sneakpeek.mission", defaultStateURL: defaultState,
                                        stateOverride: override, renderOnly: false)
    #expect(!native.isolated)
    #expect(native.stateURL == URL(fileURLWithPath: override))
    #expect(native.startsObserver)
    #expect(native.ownsApprovalSurface)
    #expect(native.reloadsFeed)
    #expect(native.loadsInitialFeed)
    #expect(native.persistsAppearance)
    let identifiers = [CoveLaunchConfiguration.previewIdentifier, CoveLaunchConfiguration.demoIdentifier, CoveLaunchConfiguration.gestureIdentifier,
                       "local.sneakpeek.mission"]
    #expect(Set(identifiers.map { CoveLaunchConfiguration.notificationName(for: $0) }).count == identifiers.count)
    #expect(!CoveLaunchConfiguration.isIsolated(nil))
    #expect(CoveLaunchConfiguration.notificationName(for: nil) == "local.sneakpeek.show")
}

@Test @MainActor func isolatedStoreDoesNotReadExistingLiveFeedOrAppearance() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory)
    let state = directory.appendingPathComponent("state.json")
    let appearance = directory.appendingPathComponent("appearance.json")
    let surface = directory.appendingPathComponent("approval-surface.json")
    try JSONEncoder().encode(CompanionSettings(mode: .otter)).write(to: appearance)
    try Data(#"{"live":true,"owner":"running app"}"#.utf8).write(to: surface)
    let originals = try [state, appearance, surface].map { try Data(contentsOf: $0) }
    let store = PeekStore(stateURL: state, demo: true, ownsApprovalSurface: false, automaticReload: false,
                          readInitialFeed: false)
    #expect(store.feed.generatedAt == 0)
    #expect(store.feed.agents.isEmpty)
    #expect(store.feed.missions.isEmpty)
    #expect(store.companionMode == .native)
    let preview = OtterPlaygroundModel(store: store)
    store.setCompanionMode(.otter, persist: false)
    preview.select(.attention)
    preview.acknowledgeExample()
    #expect(preview.scene == .working)
    #expect(store.feed.demo)
    #expect(store.feed.missions.map(\.id) == ["otter-playground"])
    #expect(store.feed.agents.allSatisfy { $0.provider == "Example" })
    #expect(try [state, appearance, surface].map { try Data(contentsOf: $0) } == originals)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("decisions").path))
}

@Test @MainActor func incompleteCoverageWithdrawsCoveAndUnsignedChecksAreVisible() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory)
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: false,
                          ownsApprovalSurface: false, automaticReload: false)
    store.feed.agents = []; store.feed.queue = []
    store.feed.warnings = ["Some logs were omitted"]
    #expect(store.otterStatus.pose == .unseen)
    #expect(store.otterStatus.title == "Coverage incomplete")
    #expect(store.otterStatus.tone == .muted)
    store.feed.warnings = []
    let assessment: [String: Any] = ["goalRevision": "r", "course": "readyForReview", "evidence": "verified",
        "requiredCount": 1, "verifiedCount": 1, "reportedCount": 0, "missingCount": 0,
        "staleCount": 0, "conflictCount": 0, "decisionCount": 0, "coverageIncomplete": true, "reasons": []]
    store.feed.missions[0].assessment = try JSONDecoder().decode(MissionAssessment.self,
                                                                from: JSONSerialization.data(withJSONObject: assessment))
    #expect(store.otterStatus.pose == .unseen)
    #expect(store.hasUnsignedReviews)
}

@Test @MainActor func nativePrivateStateFilesAreNotWorldReadable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: false, automaticReload: false)
    store.setCompanionMode(.otter)
    store.setHistoryHours(168)
    func mode(_ path: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber).intValue & 0o777
    }
    #expect(try mode(directory) == 0o700)
    for name in ["appearance.json", "harnesses.json", "approval-surface.json"] {
        #expect(try mode(directory.appendingPathComponent(name)) == 0o600)
    }
}

@Test @MainActor func respondingUsesTheClickTimeInsteadOfTheLastFeedTick() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory)
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: false,
                          ownsApprovalSurface: false, automaticReload: false)
    let issued = Date().timeIntervalSince1970 - 0.01
    store.feed.agents[0].request?.issuedAt = issued
    store.now = issued - 1 // The observer tick can predate a newly received request.
    let agent = store.feed.agents[0]
    store.answer(agent, agent.request!.choices[0])
    let path = directory.appendingPathComponent("decisions/\(agent.request!.id).json")
    let decision = try JSONDecoder().decode(Decision.self, from: Data(contentsOf: path))
    #expect(decision.createdAt >= issued)
    #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber).intValue & 0o777 == 0o600)
}

@Test(arguments: [0, 1]) @MainActor func recordCommandDrainsLargeOutputWithoutBlockingTheUI(exitCode: Int) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try fixture(directory)
    let script = directory.appendingPathComponent("synthetic-writer.py")
    // Emit more than a pipe buffer on both streams BEFORE consuming large stdin.
    // The old runner deadlocked here and blocked the main actor writing its input.
    let code = """
    import sys,json
    sys.stdout.write('x' * 262144); sys.stdout.flush()
    sys.stderr.write('Synthetic failure: ' + 'e' * 262144); sys.stderr.flush()
    payload=json.load(sys.stdin)
    assert len(payload['large']) == 262144
    sys.exit(\(exitCode))
    """
    try Data(code.utf8).write(to: script)
    let store = PeekStore(stateURL: directory.appendingPathComponent("state.json"), demo: false,
                          ownsApprovalSurface: false, missionCommandURL: script, automaticReload: false)
    let success = await withCheckedContinuation { continuation in
        store.post("synthetic-test", payload: ["large": String(repeating: "p", count: 262144)]) {
            continuation.resume(returning: $0)
        }
    }
    #expect(success == (exitCode == 0))
    #expect(!store.recording)
    #expect((store.message ?? "").utf8.count <= 32_768)
    if exitCode == 1 { #expect(store.message?.hasPrefix("Synthetic failure:") == true) }
}
