import Foundation
import Testing
import SneakPeekCore
@testable import SneakPeek

private actor GatedFeedReader: FeedReading {
    private var gate: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var paths: [String] = []

    func read(url: URL, journal: HumanJournal?, previous: Feed, now: Double) async -> FeedReadResult {
        paths.append(url.lastPathComponent)
        if paths.count == 1 {
            await withCheckedContinuation { continuation in
                gate = continuation; started?.resume(); started = nil
            }
        }
        var feed = Feed.empty
        feed.generatedAt = now; feed.demo = url.lastPathComponent == "demo-state.json"
        return FeedReadResult(feed: feed, succeeded: true)
    }
    func waitForStart() async {
        if gate != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { gate?.resume(); gate = nil }
}

@Test @MainActor func backgroundReadCoalescesTicksAndCannotPublishThePreviousMode() async {
    let reader = GatedFeedReader()
    let store = PeekStore(stateURL: URL(fileURLWithPath: "/synthetic/state.json"), demo: false,
                          ownsApprovalSurface: false, readInitialFeed: false, feedReader: reader)
    store.reload()
    await reader.waitForStart()
    store.setExpanded(true) // UI remains available while the read is blocked.
    store.reload(); store.reload(); store.toggleMode()
    #expect(store.expanded)
    #expect(await reader.paths == ["state.json"])
    await reader.release()
    await store.waitForRefresh()
    #expect(await reader.paths == ["state.json", "demo-state.json"])
    #expect(store.showingDemo && store.feed.demo)
}

@Test @MainActor func aFailedBackgroundReadImmediatelyShowsUnseenAndRecoversOnTheNextGoodRead() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("state.json")
    var feed = Feed.empty; feed.generatedAt = Date().timeIntervalSince1970; feed.queue = []
    try JSONEncoder().encode(feed).write(to: state)
    let store = PeekStore(stateURL: state, demo: false, ownsApprovalSurface: false)
    await store.waitForRefresh()
    #expect(!store.disconnected && store.otterStatus.pose == .resting)
    try Data("broken".utf8).write(to: state)
    store.reload(); await store.waitForRefresh()
    #expect(store.feedReadFailed && store.disconnected && store.otterStatus.pose == .unseen)
    var synthetic = feed; synthetic.demo = true
    #expect(!store.loadSyntheticPreview(synthetic)) // A live reader cannot mask its read failure with a preview.
    #expect(store.feedReadFailed)
    try JSONEncoder().encode(feed).write(to: state)
    store.reload(); await store.waitForRefresh()
    #expect(!store.feedReadFailed && !store.disconnected && store.message == nil)
}

@Test func heartbeatAvoidsRepeatedWritesButRefreshesBeforeExpiryAndRevokesInOrder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = ApprovalSurfacePublisher(directory: root)
    let value = ApprovalSurfaceValue(live: true, statePath: root.appendingPathComponent("state.json").path, provider: "All sources")
    let file = root.appendingPathComponent("approval-surface.json")
    func surface() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }
    publisher.publish(value, at: 100, synchronously: true)
    let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
    for t in [101.0, 102, 103] { publisher.publish(value, at: t, synchronously: true) }
    #expect(try surface()["generatedAt"] as? Double == 100)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber == inode)
    publisher.publish(value, at: 104, synchronously: true)
    #expect(try surface()["generatedAt"] as? Double == 104)
    let filtered = ApprovalSurfaceValue(live: true, statePath: value.statePath, provider: "Claude")
    publisher.publish(filtered, at: 104.1, synchronously: true)
    #expect(try surface()["provider"] as? String == "Claude")
    publisher.publish(value, at: 104.2, synchronously: false)
    publisher.publish(ApprovalSurfaceValue(live: false, statePath: value.statePath, provider: value.provider), at: 104.3, synchronously: true)
    #expect(try surface()["live"] as? Bool == false)
}
