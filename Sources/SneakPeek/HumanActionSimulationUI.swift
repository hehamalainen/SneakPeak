import AppKit
import CryptoKit
import Darwin
import Foundation
import SneakPeekCore

enum HumanActionSimulationFixture {
    /// No caller-selected path: this app always starts in a newly created temp directory.
    static func create() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SneakPeek-human-actions-simulation-" + UUID().uuidString)
        let artifact = directory.appendingPathComponent("example-result.txt")
        let bytes = Data("Synthetic result: all three example checks passed.\n".utf8)
        try PrivateStateFiles.write(bytes, to: artifact)
        var attributes = stat()
        guard lstat(artifact.path, &attributes) == 0 else { throw HumanActionError.invalid("Could not prepare simulation fixture") }
        let now = Date().timeIntervalSince1970
        let raw: [String: Any] = ["generatedAt": now, "demo": false, "agents": [], "missions": [[
            "id": "simulation-mission", "title": "Human-action signing experiment", "goal": "Review the synthetic result and its presentation",
            "goalOrigin": "simulation", "constraints": ["This exercise grants no host permissions"], "checkpoints": [
                ["id": "result", "label": "The local example result is satisfactory", "kind": "evidence", "required": true,
                 "status": "pending", "evidence": "Synthetic report", "source": "simulation"],
                ["id": "presentation", "label": "The presentation feels clear", "kind": "taste", "required": true,
                 "status": "pending", "evidence": "", "source": "simulation"]]]]]
        var feed = try JSONDecoder().decode(Feed.self, from: JSONSerialization.data(withJSONObject: raw))
        var mission = feed.missions[0]
        mission.goalRevision = try HumanContext.sourceGoalRevision(mission)
        let record: [String: Any] = ["id": UUID().uuidString, "missionId": mission.id, "checkpointId": "result",
            "goalRevision": mission.goalRevision!, "summary": "The synthetic example reports three passing checks.",
            "reference": artifact.path, "verdict": "supports", "observedAt": now, "source": "simulation fixture", "actor": "example agent",
            "digest": HumanCanonical.digest(bytes), "localFile": ["size": Int(attributes.st_size),
                "modifiedNS": String(Int64(attributes.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(attributes.st_mtimespec.tv_nsec))]]
        mission.checkpoints[0].records = [try JSONDecoder().decode(EvidenceRecord.self, from: JSONSerialization.data(withJSONObject: record))]
        feed.missions = [mission]
        let state = directory.appendingPathComponent("state.json")
        try PrivateStateFiles.write(JSONEncoder().encode(feed), to: state)
        return state
    }
}

@MainActor extension PeekStore {
    var isHumanActionSimulation: Bool { humanActionSimulation != nil }
    var humanActionAvailability: String {
        isHumanActionSimulation ? "SIMULATION · software key and simulated Touch ID · 0 authenticated human approvals"
            : "Human authentication unavailable · signed release and Touch ID integration required"
    }

    func confirmHumanDefinition(_ mission: Mission) { performHumanAction(.confirmDefinition, mission: mission) }

    func performHumanAction(_ kind: HumanActionKind, mission: Mission, checkpointID: String = "", subjectID: String = "",
                            subjectDigest: String = "", value: String = "", note: String = "", valence: String = "",
                            strength: String = "", impact: String = "", completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard !recording, let simulation = humanActionSimulation else {
            message = humanActionAvailability; completion?(false); return
        }
        recording = true
        defer { recording = false }
        do {
            let action = try simulation.prepare(kind: kind, mission: mission, now: Date().timeIntervalSince1970,
                checkpointID: checkpointID, subjectID: subjectID, subjectDigest: subjectDigest, value: value, note: note,
                valence: valence, strength: strength, impact: impact)
            let alert = NSAlert()
            alert.messageText = "SIMULATION · confirm this action"
            alert.informativeText = "This exercises a software signature. The next button simulates successful Touch ID; it does not authenticate a person."
            alert.addButton(withTitle: "Simulate successful Touch ID")
            alert.addButton(withTitle: "Cancel")
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 310))
            text.isEditable = false; text.isSelectable = true; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            let checks = mission.checkpoints.map { "\($0.id): \($0.label) [\($0.kind ?? "evidence"), \($0.required == false ? "optional" : "required"), age \($0.maxAgeSeconds ?? mission.evidenceMaxAgeSeconds ?? 86400)s]" }.joined(separator: "\n")
            let evidence = mission.checkpoints.flatMap { $0.records ?? [] }.first { $0.id == subjectID }
            text.string = "Action: \(kind.rawValue)\nDecision: \(value)\nMission: \(mission.title) [\(mission.id)]\nGoal: \(mission.goal)\nOwner: \(mission.owner ?? "You")\nWorkspace: \(mission.workspace ?? "none")\nConstraints: \((mission.constraints ?? []).joined(separator: "\n"))\nChecks:\n\(checks)\nTarget check: \(checkpointID)\nSubject: \(subjectID)\nEvidence: \(evidence?.summary ?? "")\nReference: \(evidence?.reference ?? "")\nArtifact SHA-256: \(evidence?.digest ?? "")\nNote / request: \(note)\nTaste: \(valence), \(strength), \(impact)\n\nDefinition digest: \(action.definitionDigest)\nSubject digest: \(subjectDigest)\nAction digest: \(action.digest)\nExpires in two minutes."
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 310))
            scroll.hasVerticalScroller = true; scroll.documentView = text
            text.isVerticallyResizable = true
            text.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
            alert.accessoryView = scroll
            let confirmed = alert.runModal() == .alertFirstButtonReturn
            let raw = try JSONDecoder().decode(Feed.self, from: Data(contentsOf: stateURL))
            guard raw.missions.filter({ $0.id == mission.id }).count == 1,
                  let current = raw.missions.first(where: { $0.id == mission.id }) else { throw HumanActionError.invalid("Mission changed during confirmation") }
            if kind == .resolve {
                let projected = HumanProjection.project(raw, simulationJournal: simulation.journal, now: Date().timeIntervalSince1970)
                guard projected.queue?.contains(where: { ["taste", "judgment"].contains($0.kind) && $0.id == subjectID && HumanContext.requestDigest($0) == subjectDigest }) == true else {
                    throw HumanActionError.invalid("Request changed during confirmation")
                }
            }
            try simulation.finish(action, mockBiometrySucceeded: confirmed, currentMission: current, now: Date().timeIntervalSince1970)
            reload()
            message = "SIMULATION · signature recorded for this session only"; completion?(true)
        } catch { message = error.localizedDescription; completion?(false) }
    }
}
