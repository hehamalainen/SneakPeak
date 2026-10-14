import AppKit
import Foundation
import SneakPeekCore
import SwiftUI

@MainActor final class PeekStore: ObservableObject {
    @Published var feed = Feed.empty
    @Published var expanded = false
    @Published var pinned = false
    @Published var showingDemo = false
    @Published private(set) var companionMode: CompanionMode = .native
    @Published var selectedMissionId: String?
    @Published var selectedAgentId: String?
    @Published var message: String?
    @Published var sentRequests = Set<String>()
    private var sentByMode: [Bool: Set<String>] = [:]
    @Published var providerFilter = "All sources"
    @Published var recording = false
    @Published var now = Date().timeIntervalSince1970
    var onResize: (() -> Void)?
    var onPanelDragBegan: (() -> Void)?
    var onPanelDragEnded: ((Bool) -> Void)?
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
    private var draggingPanel = false
    private var recordProcess: Process?
    let humanActionSimulation: HumanActionSimulation?
    private let backgroundReload: Bool
    private let feedReader: any FeedReading
    private let surfacePublisher: ApprovalSurfacePublisher
    private let surfaceStatePath: String
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var feedEpoch = 0
    @Published private(set) var feedReadFailed = false

    init(stateURL: URL, demo: Bool, ownsApprovalSurface: Bool = true, missionCommandURL: URL? = nil, automaticReload: Bool = true, readInitialFeed: Bool = true, humanActionSimulation: HumanActionSimulation? = nil, feedReader: any FeedReading = LocalFeedReader()) {
        self.backgroundReload = automaticReload
        self.feedReader = feedReader
        surfacePublisher = ApprovalSurfacePublisher(directory: stateURL.deletingLastPathComponent())
        surfaceStatePath = stateURL.standardizedFileURL.resolvingSymlinksInPath().path
        self.humanActionSimulation = humanActionSimulation
        self.ownsApprovalSurface = ownsApprovalSurface
        self.missionCommandURL = missionCommandURL
        self.stateURL = stateURL; showingDemo = demo
        if readInitialFeed, let data = try? Data(contentsOf: directory.appendingPathComponent("appearance.json")),
           let settings = try? JSONDecoder().decode(CompanionSettings.self, from: data) {
            companionMode = settings.mode
        }
        if readInitialFeed { reload() }
        if automaticReload {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
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
    var disconnected: Bool { feedReadFailed || (!isHumanActionSimulation && feed.isDisconnected(at: now)) }
    var hasUnsignedReviews: Bool {
        feed.missions.contains { $0.hasUnsignedHumanClaims == true || (($0.assessment?.verifiedCount ?? 0) > 0 && $0.assessment?.authentication == nil) }
    }
    var otterAttentionSignature: String {
        if let queue = feed.queue { return queue.filter(\.needsDecision).map(\.id).sorted().joined(separator: "|") }
        return feed.agents.filter { $0.needsHuman(at: now) }.map { $0.request?.id ?? $0.id }.sorted().joined(separator: "|")
    }

    var otterStatus: OtterStatus {
        if disconnected { return OtterStatus(pose: .unseen, title: "I can’t see right now", detail: "Connection quiet · status unavailable", tone: .muted) }
        if attentionCount > 0 {
            let decisionsConfirmed = feed.queue != nil || feed.agents.filter { $0.needsHuman(at: now) }.allSatisfy { $0.request?.canAnswer(at: now) == true }
            let title = decisionsConfirmed
                ? (attentionCount == 1 ? "One decision needs you" : "\(attentionCount) decisions need you")
                : (attentionCount == 1 ? "One agent needs you" : "\(attentionCount) agents need you")
            return OtterStatus(pose: .attention, title: title, detail: "A paw, then back to your day", tone: .attention)
        }
        if feed.warnings?.isEmpty == false {
            return OtterStatus(pose: .unseen, title: "Coverage incomplete", detail: "Some sources are unavailable", tone: .muted)
        }
        if feed.missions.contains(where: { $0.assessment?.course == "suspectedDrift" }) {
            return OtterStatus(pose: .peeking, title: "A course concern", detail: "Look at the evidence", tone: .attention)
        }
        if feed.missions.contains(where: { ["missing", "stale"].contains($0.assessment?.evidence ?? "") || $0.assessment?.coverageIncomplete == true }) {
            if feed.missions.contains(where: { $0.assessment?.coverageIncomplete == true }) {
                return OtterStatus(pose: .unseen, title: "Coverage incomplete", detail: "Some sources are unavailable", tone: .muted)
            }
            return OtterStatus(pose: .peeking, title: "Evidence needs a look", detail: "The outcome is still unverified", tone: .attention)
        }
        if !queue.isEmpty {
            return OtterStatus(pose: .peeking, title: "A few things to review", detail: "Open the queue when ready", tone: .attention)
        }
        if feed.agents.contains(where: { $0.isQuiet(at: now) }) {
            return OtterStatus(pose: .unseen, title: "An agent has gone quiet", detail: "Open the source to check", tone: .muted)
        }
        if feed.agents.contains(where: { $0.status == "working" }) {
            return OtterStatus(pose: .peeking, title: "Keeping an eye on things", detail: "Agents are working", tone: .working)
        }
        guard feed.queue != nil else {
            return OtterStatus(pose: .unseen, title: "The queue isn’t confirmed", detail: "Take a closer look", tone: .muted)
        }
        return OtterStatus(pose: .resting, title: feed.agents.isEmpty ? "Ready when you are" : "Room to focus", detail: "No decisions waiting", tone: .resting)
    }

    func setCompanionMode(_ mode: CompanionMode, persist: Bool = true) {
        if persist {
            do {
                try writePrivate(JSONEncoder().encode(CompanionSettings(mode: mode)), name: "appearance.json")
            } catch { message = "Could not save the appearance preference"; return }
        }
        guard companionMode != mode else { return }
        companionMode = mode
        onResize?()
    }

    func reload() {
        now = Date().timeIntervalSince1970
        let url = showingDemo ? directory.appendingPathComponent("demo-state.json") : stateURL
        let journal = humanActionSimulation?.journal
        guard backgroundReload else {
            applyRefresh(LocalFeedReader.readSynchronously(url: url, journal: journal, previous: feed, now: now))
            return
        }
        guard refreshTask == nil else { refreshAgain = true; return }
        let epoch = feedEpoch, mode = showingDemo, receiptCount = journal?.records.count
        let previous = feed, readTime = now, reader = feedReader
        refreshTask = Task { @MainActor [weak self] in
            let result = await reader.read(url: url, journal: journal, previous: previous, now: readTime)
            guard let self else { return }
            self.refreshTask = nil
            // A previous mode or signing context cannot publish late over the
            // current one. At most one read runs; additional ticks coalesce.
            if self.feedEpoch == epoch && self.showingDemo == mode && self.humanActionSimulation?.journal.records.count == receiptCount {
                self.applyRefresh(result)
            } else { self.refreshAgain = true }
            if self.refreshAgain { self.refreshAgain = false; self.reload() }
        }
    }

    func waitForRefresh() async {
        while let task = refreshTask { await task.value }
    }

    func loadSyntheticPreview(_ snapshot: Feed) -> Bool {
        guard !ownsApprovalSurface, !backgroundReload,
              snapshot.missions.map(\.id) == ["otter-playground"],
              snapshot.agents.allSatisfy({ $0.provider == "Example" && $0.missionId == "otter-playground" }) else { return false }
        // This non-polling playground's fresh in-memory snapshot replaces its
        // previous source, including any initial missing-file error.
        feedEpoch += 1
        feedReadFailed = false
        showingDemo = true
        feed = snapshot
        return true
    }

    private func applyRefresh(_ result: FeedReadResult) {
        feed = result.feed
        feedReadFailed = !result.succeeded
        if result.succeeded {
            if message == "Connecting to local sessions…" || message == "The local feed could not be read. Check the bridge." { message = nil }
            let pendingIDs = Set(feed.agents.compactMap { $0.request?.id })
            if !sentRequests.subtracting(pendingIDs).isEmpty {
                sentRequests.formIntersection(pendingIDs)
                sentByMode[showingDemo] = sentRequests
                message = showingDemo ? "The example agent received your decision." : "Request cleared by the source · check the latest agent status"
            }
            if !feed.missions.contains(where: { $0.id == selectedMissionId }) { selectedMissionId = feed.missions.first?.id }
            if !agents.contains(where: { $0.id == selectedAgentId }) { selectedAgentId = nil }
        } else {
            if feed.generatedAt == 0 { message = "Connecting to local sessions…" }
            else { message = "The local feed could not be read. Check the bridge." }
            publishApprovalSurface(live: false)
            return
        }
        publishApprovalSurface()
    }
    func publishApprovalSurface(live: Bool? = nil, synchronously: Bool = false) {
        guard ownsApprovalSurface else { return }
        let value = ApprovalSurfaceValue(live: live ?? (!showingDemo && !feed.demo && !disconnected && feed.generatedAt > 0),
                                         statePath: surfaceStatePath, provider: providerFilter)
        surfacePublisher.publish(value, at: Date().timeIntervalSince1970, synchronously: synchronously || !backgroundReload)
    }
    func setExpanded(_ value: Bool) {
        closeTask?.cancel()
        guard expanded != value else { return }
        expanded = value
        onResize?()
    }
    func hover(_ inside: Bool) {
        guard !draggingPanel else { return }
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
    func beginPanelDrag() {
        closeTask?.cancel()
        draggingPanel = true
        onPanelDragBegan?()
    }
    func endPanelDrag(moved: Bool) {
        draggingPanel = false
        onPanelDragEnded?(moved)
    }
    func toggleMode() {
        guard !isHumanActionSimulation else { return }
        publishApprovalSurface(live: false)
        sentByMode[showingDemo] = sentRequests
        showingDemo.toggle(); selectedMissionId = nil; selectedAgentId = nil; message = nil
        feedEpoch += 1
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
    private func writePrivate(_ data: Data, name: String) throws {
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SneakPeek").standardizedFileURL
        try PrivateStateFiles.write(data, to: directory.appendingPathComponent(name),
                                    repairDirectory: directory.standardizedFileURL == defaultDirectory)
    }
    func writeSettings(_ value: HarnessSettings) throws {
        try writePrivate(JSONEncoder().encode(value), name: "harnesses.json")
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
        guard file.hasPrefix("/"), !file.contains(where: { "*?[".contains($0) }) else {
            message = "Choose one absolute event log file, without wildcard patterns"; return false
        }
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
                                     directory: directory.appendingPathComponent("decisions"), now: Date().timeIntervalSince1970)
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
                if folder.path.hasPrefix(allowed), FileManager.default.fileExists(atPath: folder.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            message = "Conversation ID copied · choose it in \(agent.sourceApp ?? "Antigravity"). Artifacts shown in Finder when available."
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
        if action == "taste" {
            guard let mission = feed.missions.first(where: { $0.id == payload["missionId"] as? String }),
                  mission.goalRevision == payload["goalRevision"] as? String else { message = "Mission context changed"; completion?(false); return }
            performHumanAction(.taste, mission: mission, checkpointID: payload["checkpointId"] as? String ?? "",
                value: payload["acceptance"] as? String ?? "unassessed", note: payload["note"] as? String ?? "",
                valence: payload["valence"] as? String ?? "", strength: payload["strength"] as? String ?? "",
                impact: payload["impact"] as? String ?? "", completion: completion)
            return
        }
        guard !["review-evidence", "resolve"].contains(action), !isHumanActionSimulation else {
            message = isHumanActionSimulation ? "The simulation uses its fixed synthetic fixture." : humanActionAvailability
            completion?(false); return
        }
        guard !recording, let script = missionCommandURL ?? Bundle.main.resourceURL?.appendingPathComponent("bridge/mission_commands.py") else { completion?(false); return }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path, "--state", currentFeedURL.path, "--action", action]
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            let drain = CommandPipeDrain(stdout: output, stderr: errors, stdin: input)
            process.terminationHandler = { [weak self] task in
                let (success, failure) = drain.result(exitCode: task.terminationStatus)
                Task { @MainActor [weak self] in
                    self?.recording = false
                    self?.recordProcess = nil
                    self?.message = success ? "Recorded · the mission view will refresh" : failure
                    completion?(success)
                }
            }
            recording = true; recordProcess = process
            do { try process.run() }
            catch { drain.abandon(); throw error }
            drain.start(input: data, process: process)
        } catch {
            recording = false; recordProcess = nil; message = "Could not save this record: \(error.localizedDescription)"
            completion?(false)
        }
    }
    func review(_ evidence: EvidenceRecord, mission: Mission, verdict: String) {
        performHumanAction(.reviewEvidence, mission: mission, checkpointID: evidence.checkpointId,
                           subjectID: evidence.id, subjectDigest: HumanContext.evidenceDigest(evidence), value: verdict)
    }
    func resolve(_ item: QueueItem, outcome: String) {
        guard ["taste", "judgment"].contains(item.kind), let mission = feed.missions.first(where: { $0.id == item.missionId }) else { return }
        performHumanAction(.resolve, mission: mission, subjectID: item.id, subjectDigest: HumanContext.requestDigest(item),
                           value: outcome, note: item.title + "\n" + item.why + "\n" + item.impact)
    }
    func openEvidence(_ evidence: EvidenceRecord) {
        guard !showingDemo, let reference = evidence.reference else { return }
        switch EvidenceReference(reference) {
        case .reveal(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                message = "This local reference is no longer available."; return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            message = "Local reference shown in Finder"
        case .website(let url):
            NSWorkspace.shared.open(url)
        case .unsupported:
            message = "This reference cannot be opened. Inspect it at the source."
        }
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
