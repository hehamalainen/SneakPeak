import AppKit
import Foundation
import SneakPeekCore
import SwiftUI

@MainActor final class PeekStore: ObservableObject {
    @Published var feed = Feed.empty
    @Published var expanded = false
    @Published var pinned = false
    @Published var showingDemo = false
    @Published var selectedMissionId: String?
    @Published var selectedAgentId: String?
    @Published var message: String?
    @Published var sentRequests = Set<String>()
    private var sentByMode: [Bool: Set<String>] = [:]
    @Published var providerFilter = "All sources"
    @Published var recording = false
    @Published var now = Date().timeIntervalSince1970
    var onResize: (() -> Void)?
    var onEdit: ((Mission) -> Void)?
    var onManage: (() -> Void)?
    var onSetup: ((HarnessInfo) -> Void)?
    var onInspectMission: ((Mission) -> Void)?
    var onTaste: ((Mission, Checkpoint?) -> Void)?
    var onEvidence: ((Mission, Checkpoint) -> Void)?
    var onJudgment: ((Mission) -> Void)?
    var onQueue: ((QueueItem) -> Void)?
    var onShowQueue: (() -> Void)?
    let stateURL: URL
    private let ownsApprovalSurface: Bool
    private let missionCommandURL: URL?
    private var timer: Timer?
    private var closeTask: Task<Void, Never>?
    private var recordProcess: Process?

    init(stateURL: URL, demo: Bool, ownsApprovalSurface: Bool = true, missionCommandURL: URL? = nil) {
        self.ownsApprovalSurface = ownsApprovalSurface
        self.missionCommandURL = missionCommandURL
        self.stateURL = stateURL; showingDemo = demo
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }
    var directory: URL { stateURL.deletingLastPathComponent() }
    var harnesses: [HarnessInfo] { (feed.harnesses?.isEmpty == false ? feed.harnesses : nil) ?? HarnessInfo.defaults }
    var filteredHarness: HarnessInfo? { harnesses.first { $0.provider == providerFilter } }
    var settings: HarnessSettings {
        get {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("harnesses.json")),
                  let value = try? JSONDecoder().decode(HarnessSettings.self, from: data) else { return HarnessSettings() }
            return value
        }
    }
    var visibleAgents: [Agent] { providerFilter == "All sources" ? feed.agents : feed.agents.filter { $0.provider == providerFilter } }
    var missions: [Mission] {
        if providerFilter == "All sources" { return feed.missions }
        let ids = Set(visibleAgents.map(\.missionId))
        return feed.missions.filter { ids.contains($0.id) }
    }
    var mission: Mission? { missions.first { $0.id == selectedMissionId } ?? missions.first }
    var agents: [Agent] {
        visibleAgents.filter { $0.missionId == mission?.id }.sorted {
            if $0.needsHuman(at: now) != $1.needsHuman(at: now) { return $0.needsHuman(at: now) }
            return $0.lastActivity > $1.lastActivity
        }
    }
    var selectedAgent: Agent? { agents.first { $0.id == selectedAgentId } ?? agents.first { $0.needsHuman(at: now) } }
    var queue: [QueueItem] { feed.queue ?? [] }
    var visibleQueue: [QueueItem] {
        if providerFilter == "All sources" { return queue }
        let ids = Set(missions.map(\.id))
        return queue.filter { ids.contains($0.missionId) }
    }
    var attentionCount: Int { feed.queue == nil ? feed.agents.filter { $0.needsHuman(at: now) }.count : queue.filter(\.needsDecision).count }
    var visibleAttentionCount: Int { feed.queue == nil ? visibleAgents.filter { $0.needsHuman(at: now) }.count : visibleQueue.filter(\.needsDecision).count }
    var driftCount: Int { missions.filter { $0.assessment?.course == "suspectedDrift" }.count }
    var evidenceGapCount: Int { missions.filter { ["missing", "stale"].contains($0.assessment?.evidence ?? "") || $0.assessment?.coverageIncomplete == true }.count }
    var disconnected: Bool { feed.isDisconnected(at: now) }

    func reload() {
        now = Date().timeIntervalSince1970
        let url = showingDemo ? directory.appendingPathComponent("demo-state.json") : stateURL
        do {
            let newFeed = try JSONDecoder().decode(Feed.self, from: Data(contentsOf: url))
            feed = newFeed
            if message == "Connecting to local sessions…" { message = nil }
            let pendingIDs = Set(newFeed.agents.compactMap { $0.request?.id })
            if !sentRequests.subtracting(pendingIDs).isEmpty {
                sentRequests.formIntersection(pendingIDs)
                sentByMode[showingDemo] = sentRequests
                message = showingDemo ? "The example agent received your decision." : "Request cleared by the source · check the latest agent status"
            }
            if !newFeed.missions.contains(where: { $0.id == selectedMissionId }) { selectedMissionId = newFeed.missions.first?.id }
            if !agents.contains(where: { $0.id == selectedAgentId }) { selectedAgentId = nil }
        } catch {
            if feed.generatedAt == 0 { message = "Connecting to local sessions…" }
            else { message = "The local feed could not be read. Check the bridge." }
            publishApprovalSurface(live: false)
            return
        }
        publishApprovalSurface()
    }
    func publishApprovalSurface(live: Bool? = nil) {
        guard ownsApprovalSurface else { return }
        let value: [String: Any] = ["generatedAt": Date().timeIntervalSince1970,
                                   "live": live ?? (!showingDemo && !feed.demo && !disconnected && feed.generatedAt > 0),
                                   "statePath": stateURL.standardizedFileURL.resolvingSymlinksInPath().path,
                                   "provider": providerFilter]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: value) {
            try? data.write(to: directory.appendingPathComponent("approval-surface.json"), options: .atomic)
        }
    }
    func setExpanded(_ value: Bool) {
        closeTask?.cancel()
        guard expanded != value else { return }
        expanded = value
        onResize?()
    }
    func hover(_ inside: Bool) {
        closeTask?.cancel()
        if inside { setExpanded(true) }
        else if !pinned {
            closeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                self?.setExpanded(false)
            }
        }
    }
    func toggleMode() {
        publishApprovalSurface(live: false)
        sentByMode[showingDemo] = sentRequests
        showingDemo.toggle(); selectedMissionId = nil; selectedAgentId = nil; message = nil
        sentRequests = sentByMode[showingDemo] ?? []
        feed = .empty; reload()
    }
    func filterProvider(_ provider: String) {
        providerFilter = provider
        publishApprovalSurface()
        selectedMissionId = missions.first?.id; selectedAgentId = nil
    }
    func manageHarnesses() { storeFocus(); onManage?() }
    private func storeFocus() { pinned = true }
    func writeSettings(_ value: HarnessSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("harnesses.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("harnesses.json").path)
    }
    func enableHarness(_ harness: HarnessInfo, enabled: Bool) {
        var value = settings
        var definitions = value.harnesses ?? []
        if let i = definitions.firstIndex(where: { $0.id == harness.id }) { definitions[i].enabled = enabled }
        else { definitions.append(HarnessDefinition(id: harness.id, enabled: enabled)) }
        value.harnesses = definitions
        do { try writeSettings(value); message = "Harness settings saved · discovery refreshes within 8 seconds" }
        catch { message = "Could not save harness settings: \(error.localizedDescription)" }
    }
    func setHistoryHours(_ hours: Double) {
        var value = settings; value.recentHours = hours
        do { try writeSettings(value); message = "History window saved · discovery refreshes within 8 seconds" }
        catch { message = "Could not save the history window" }
    }
    func addHarness(name: String, eventPath: String, format: String) -> Bool {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = label.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        guard !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy({ $0.isASCII }),
              !harnesses.contains(where: { $0.id == id || $0.provider == label }),
              ["sneakpeek", "codex", "claude", "copilot", "antigravity"].contains(format) else {
            message = "Choose a unique harness name (up to 64 ASCII letters and digits)."; return false
        }
        let path = eventPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = path.isEmpty ? directory.appendingPathComponent("custom/\(id)/events.jsonl").path : (path as NSString).expandingTildeInPath
        guard file.hasPrefix("/") else { message = "Choose an absolute event log path"; return false }
        var value = settings; var definitions = value.harnesses ?? []
        guard !definitions.contains(where: { $0.id == id }) else { message = "That harness is already registered"; return false }
        definitions.append(HarnessDefinition(id: id, name: label, format: format, logs: [file], enabled: true))
        value.harnesses = definitions
        do {
            try writeSettings(value)
            message = "\(label) added · publish events to connect its sessions"
            return true
        } catch { message = "Harness could not be saved: \(error.localizedDescription)"; return false }
    }
    func copyPublishingCommand(_ id: String = "HARNESS_ID") {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = Bundle.main.resourceURL?.appendingPathComponent("bridge/peek.py").path ?? "bridge/peek.py"
        let command = "python3 \(quote(script)) emit --state \(quote(stateURL.path)) --harness \(quote(id)) --session SESSION_ID --event started --goal 'The intended outcome'"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        message = "Example event command copied · set the session ID and intended outcome"
    }
    func answer(_ agent: Agent, _ choice: Choice) {
        guard !disconnected, let request = agent.request else { return }
        guard showingDemo || request.transport == "trusted-local-file" else {
            message = "Answer this permission in its source session"; return
        }
        do {
            try DecisionWriter.write(agent: agent, choice: choice.id,
                                     directory: directory.appendingPathComponent("decisions"), now: now)
            sentRequests.insert(request.id)
            sentByMode[showingDemo] = sentRequests
            message = "Decision sent · waiting for the agent to confirm"
        } catch { message = "This request is no longer available. Open the source session." }
    }
    func open(_ agent: Agent) {
        guard let id = agent.sessionId else { message = "This is an example agent. Switch to Live for your sessions."; return }
        if agent.handoffKind == "copy-id" || !["Codex", "Claude", "Antigravity", "GitHub Copilot"].contains(agent.provider) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string)
            message = "Session ID copied · open it in \(agent.provider)"
            return
        }
        guard UUID(uuidString: id) != nil || id.hasPrefix("agent-") && id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            message = "The session identifier is unavailable."; return
        }
        if agent.provider == "Antigravity" {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string)
            if let path = agent.artifactPath {
                let folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                let allowed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini").path + "/"
                if folder.path.hasPrefix(allowed) { NSWorkspace.shared.open(folder) }
            }
            message = "Conversation ID copied · choose it in \(agent.sourceApp ?? "Antigravity"). Artifacts opened when available."
            return
        }
        let command = agent.provider == "Claude" ? "claude --resume \(id)" : agent.provider == "GitHub Copilot" ? "copilot --resume \(id)" : "codex resume \(id)"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        if agent.provider == "Codex", let url = URL(string: "codex://threads/\(id)"), NSWorkspace.shared.open(url) {
            message = "Opened Codex · resume command also copied"
        } else { message = "Resume command copied · paste it in the session’s project terminal" }
    }
    func saveMission(_ mission: Mission, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        do {
            var definition = mission
            definition.assessment = nil; definition.tasteNotes = nil; definition.goalRevision = nil; definition.definitionRevision = nil
            definition.pinned = mission.pinned ?? true
            for i in definition.checkpoints.indices {
                definition.checkpoints[i].records = nil; definition.checkpoints[i].trackingState = nil
            }
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition))
            post("definition", payload: ["missionId": mission.id, "definitionRevision": mission.definitionRevision ?? "", "definition": object], completion: completion)
        } catch { message = "Mission could not be saved: \(error.localizedDescription)"; completion?(false) }
    }
    func verify(_ checkpoint: Checkpoint) {
        guard let mission else { return }
        onInspectMission?(mission)
    }
    var currentFeedURL: URL { showingDemo ? directory.appendingPathComponent("demo-state.json") : stateURL }
    func post(_ action: String, payload: [String: Any], completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard !recording, let script = missionCommandURL ?? Bundle.main.resourceURL?.appendingPathComponent("bridge/mission_commands.py") else { completion?(false); return }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path, "--state", currentFeedURL.path, "--action", action]
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            process.terminationHandler = { [weak self] task in
                _ = output.fileHandleForReading.readDataToEndOfFile()
                let failure = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "The record could not be saved"
                let success = task.terminationStatus == 0
                Task { @MainActor [weak self] in
                    self?.recording = false
                    self?.message = success ? "Recorded · the mission view will refresh" : failure
                    completion?(success)
                }
            }
            recording = true; recordProcess = process
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
        } catch {
            recording = false; message = "Could not save this record: \(error.localizedDescription)"
            completion?(false)
        }
    }
    func review(_ evidence: EvidenceRecord, mission: Mission, verdict: String) {
        guard let fingerprint = evidence.fingerprint, let goal = mission.goalRevision else { return }
        post("review-evidence", payload: ["missionId": mission.id, "goalRevision": goal,
             "evidenceId": evidence.id, "fingerprint": fingerprint, "verdict": verdict])
    }
    func resolve(_ item: QueueItem, outcome: String) {
        guard let id = item.recordId, let mission = feed.missions.first(where: { $0.id == item.missionId }) else { return }
        let note = mission.tasteNotes?.first { $0.id == id }
        let revision = item.recordGoalRevision ?? note?.goalRevision ?? mission.goalRevision ?? ""
        post("resolve", payload: ["missionId": mission.id, "recordId": id, "recordGoalRevision": revision, "outcome": outcome])
        if outcome == "change" { message = "Guidance recorded locally · open the source session to direct the change" }
    }
    func openEvidence(_ evidence: EvidenceRecord) {
        guard !showingDemo, let reference = evidence.reference else { return }
        if reference.hasPrefix("/") {
            let url = URL(fileURLWithPath: reference)
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: reference), url.scheme == "https" || (url.scheme == "file" && (url.host == nil || url.host == "" || url.host == "localhost")) {
            NSWorkspace.shared.open(url)
        } else { message = "This reference cannot be opened. Inspect it at the source." }
    }
    func age(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "No checkpoint" }
        let seconds = Int(max(0, now - timestamp))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds >= 86400 { return "\(seconds / 86400)d ago" }
        return "\(seconds / 3600)h ago"
    }
}
