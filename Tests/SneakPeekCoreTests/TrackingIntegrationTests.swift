import Foundation
import Testing
@testable import SneakPeekCore

@Test func pythonProjectionDecodesInNativeClientWithoutConflatingJudgmentAndApproval() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = #"""
    import json, sys
    from pathlib import Path
    sys.path.insert(0, sys.argv[1])
    from peek import Demo, decorate_demo
    from mission_tracking import project
    directory = Path(sys.argv[2])
    demo = Demo()
    feed = demo.feed(directory)
    decorate_demo(feed, demo.started)
    print(json.dumps(project(feed, directory)))
    """#
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", script, root.appendingPathComponent("bridge").path, directory.path]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let feed = try JSONDecoder().decode(Feed.self, from: data)
    let mission = try #require(feed.missions.first)
    #expect(mission.assessment?.verifiedCount == 1)
    #expect(mission.assessment?.decisionCount == 2)
    #expect(mission.checkpoints.first?.records?.first?.state == "accepted")
    let queue = try #require(feed.queue)
    let host = try #require(queue.first { $0.kind == "runtime" })
    let taste = try #require(queue.first { $0.kind == "taste" })
    let evidence = try #require(queue.first { $0.kind == "evidence" })
    #expect(host.requestId == feed.agents.first { $0.id == host.agentId }?.request?.id)
    #expect(taste.requestId == nil && taste.agentId == nil)
    #expect(host.needsDecision && taste.needsDecision && !evidence.needsDecision)
}
