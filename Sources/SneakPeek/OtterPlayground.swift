import AppKit
import SneakPeekCore
import SwiftUI

enum OtterDemoScene: String, CaseIterable, Identifiable {
    case working = "Working", attention = "Paw up", resting = "Clear queue"
    case unseen = "Can’t see", quiet = "Quiet agent", raft = "Holding paws"
    case drift = "Drift", rejoin = "Rejoin"
    var id: String { rawValue }
    var explanation: String {
        switch self {
        case .working: "Work starts: peek into view, then stay still."
        case .attention: "Needs you: a paw rises above the face, waves twice, then stays up until acknowledged."
        case .resting: "Queue confirmed clear: roll onto your back, close your eyes, and settle."
        case .unseen: "Can’t see: Cove turns its back and withdraws. The crossed eye means status is unavailable."
        case .quiet: "An agent goes quiet: withdraw instead of looking reassuring."
        case .raft: "Fresh on-course reports: reach out and hold paws. These are agent claims."
        case .drift: "Reported risk: one otter drifts away and the paw link opens."
        case .rejoin: "A fresh on-course report: return to the raft and join paws again."
        }
    }

    func feed(now: Double) throws -> Feed {
        func agent(_ id: String, _ name: String, course: String = "onCourse") -> [String: Any] {
            ["id": id, "missionId": "otter-playground", "name": name, "provider": "Example",
             "status": self == .resting ? "done" : "working", "summary": "Synthetic preview only",
             "lastActivity": self == .quiet ? now - 301 : now, "lastProgress": now,
             "evidence": "Example course report, not a verified outcome", "nextStep": "Inspect the evidence",
             "trajectory": course]
        }
        let agents = [agent("a", "Milo"), agent("b", "Pip", course: self == .drift ? "atRisk" : "onCourse")]
        let queue: [[String: Any]] = self == .attention ? [
            ["id": UUID().uuidString, "missionId": "otter-playground", "missionTitle": "Otter playground",
             "kind": "judgment", "title": "Choose the next direction", "why": "A synthetic choice",
             "impact": "Example human judgment", "priority": 1]] : []
        let object: [String: Any] = ["generatedAt": self == .unseen ? 0 : now, "demo": self != .unseen,
            "missions": [["id": "otter-playground", "title": "Otter playground",
                          "goal": "Try every gesture using synthetic events.", "checkpoints": []]],
            "agents": agents, "queue": queue]
        return try JSONDecoder().decode(Feed.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@MainActor final class OtterPlaygroundModel: ObservableObject {
    /// One complete, 32-second presentation. Quiet agents remain available as a
    /// manual scene, while the walkthrough ends where it began: safely linked.
    static let demoSequence: [OtterDemoScene] = [.raft, .working, .attention, .resting, .drift, .rejoin, .unseen, .raft]
    let store: PeekStore
    @Published private(set) var scene: OtterDemoScene = .raft
    @Published private(set) var replay = 0
    @Published private(set) var playing = false
    @Published private(set) var currentStep: Int?
    @Published private(set) var progress = 0.0
    private var playback: Task<Void, Never>?
    private var playbackID = UUID()

    init(store: PeekStore) { self.store = store; apply(.raft) }

    func apply(_ scene: OtterDemoScene) {
        stop()
        currentStep = nil
        progress = 0
        load(scene)
    }

    private func load(_ scene: OtterDemoScene) {
        self.scene = scene
        store.now = Date().timeIntervalSince1970
        do {
            store.feed = try scene.feed(now: store.now)
            store.showingDemo = true
            store.selectedMissionId = "otter-playground"
            store.message = nil
            replay += 1
        } catch { store.message = "The synthetic preview could not be loaded" }
    }

    func select(_ scene: OtterDemoScene) { apply(scene) }

    func stop() {
        playbackID = UUID()
        playback?.cancel()
        playback = nil
        playing = false
    }

    /// Acknowledgement is deliberately local to this synthetic playground. It
    /// never calls PeekStore.answer, writes a decision, or contacts a bridge.
    func acknowledgeExample() {
        guard scene == .attention, store.showingDemo, store.feed.demo,
              store.feed.missions.map(\.id) == ["otter-playground"],
              store.feed.agents.allSatisfy({ $0.missionId == "otter-playground" && $0.provider == "Example" }),
              let queue = store.feed.queue, !queue.isEmpty,
              queue.allSatisfy({ $0.missionId == "otter-playground" }) else { return }
        select(.working)
        store.message = "Example acknowledged · Cove returns to watching."
    }

    func playAll(stepDuration: Duration = .seconds(4)) {
        stop()
        let runID = UUID()
        playbackID = runID
        playing = true
        currentStep = 0
        progress = 0
        load(Self.demoSequence[0])
        playback = Task { @MainActor [weak self] in
            for (index, scene) in Self.demoSequence.enumerated() {
                guard !Task.isCancelled, let self, self.playbackID == runID else { return }
                if index > 0 {
                    self.currentStep = index
                    self.load(scene)
                }
                do { try await Task.sleep(for: max(.zero, stepDuration)) }
                catch { return }
                guard !Task.isCancelled, self.playbackID == runID else { return }
                self.progress = Double(index + 1) / Double(Self.demoSequence.count)
            }
            guard !Task.isCancelled, let self, self.playbackID == runID else { return }
            self.playing = false
            self.playback = nil
        }
    }
}

struct OtterPlayground: View {
    @ObservedObject var model: OtterPlaygroundModel
    let showCompanion: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Meet Cove.").font(.system(size: 29, weight: .medium, design: .rounded))
                        Text("A separate playground · synthetic events only")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Otter only ↗", action: showCompanion).buttonStyle(.bordered)
                        .help("Show just Cove. Drag to move; click or press Space to return here.")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 22) {
                        character
                        sceneDescription
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        character.frame(maxWidth: .infinity)
                        sceneDescription
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button {
                            if model.playing { model.stop() } else { model.playAll() }
                        } label: {
                            Label(model.playing ? "Stop demo" : "Play demo", systemImage: model.playing ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent).tint(Color(red: 0.55, green: 0.36, blue: 0.22))
                        .keyboardShortcut(.space, modifiers: [])
                        .help("Play or stop the 32-second walkthrough. Shortcut: Space.")
                        Button("Replay gesture") { model.select(model.scene) }.buttonStyle(.bordered)
                            .help("Replay this movement once. Stops the walkthrough.")
                        Spacer()
                    }
                    HStack {
                        Text(playbackDescription)
                        Spacer()
                        Text("Space to play / stop")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    if model.currentStep != nil {
                        ProgressView(value: model.progress, total: 1)
                            .tint(Color(red: 0.72, green: 0.54, blue: 0.38))
                            .accessibilityLabel("Demo progress")
                            .accessibilityValue("\(Int(model.progress * 100)) percent")
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135))], spacing: 8) {
                    ForEach(OtterDemoScene.allCases) { scene in
                        Button { model.select(scene) } label: {
                            HStack { Text(scene.rawValue); Spacer(); if scene == model.scene { Image(systemName: "checkmark") } }
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(scene == model.scene ? Color.brown.opacity(0.22) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(scene.rawValue)
                        .accessibilityValue(scene == model.scene ? "Selected" : "")
                        .accessibilityHint("Shows this example and stops the walkthrough")
                    }
                }
                smallSizeComparison
                CoveRaft(store: model.store, replay: model.replay)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Every gesture plays once, then settles.")
                    Text("Your running jobs are not connected to this playground.")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.055, green: 0.06, blue: 0.067))
        .foregroundStyle(Color.white.opacity(0.9))
        .preferredColorScheme(.dark)
    }

    private var character: some View {
        ZStack(alignment: .topTrailing) {
            CoveDemoCharacter(model: model)
                .frame(width: 260, height: 196)
                .padding(18)
            Circle().fill(model.store.otterStatus.color).frame(width: 9, height: 9).padding(20)
        }
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
    }

    private var sceneDescription: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.scene.rawValue).font(.system(size: 23, weight: .medium, design: .rounded))
            Text(model.scene.explanation).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if model.scene == .attention {
                Button("Acknowledge example") { model.acknowledgeExample() }
                    .buttonStyle(.bordered).tint(.orange)
                    .help("Clear this synthetic request. No message is sent to a running agent.")
                Text("Clears this example only.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let message = model.store.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if reduceMotion {
                Text("Reduce Motion is on: gestures settle immediately.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var smallSizeComparison: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("At a glance").font(.system(size: 11, weight: .medium))
                Text("Same gesture, actual sizes").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach([32, 64], id: \.self) { size in
                VStack(spacing: 5) {
                    CoveDemoCharacter(model: model)
                        .frame(width: CGFloat(size) * 1.35, height: CGFloat(size))
                    Text("\(size) pt").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var playbackDescription: String {
        guard let step = model.currentStep else { return "32-second walkthrough · choose any scene below" }
        if model.progress == 1 { return "Demo complete · holding paws" }
        return "\(model.playing ? "Step" : "Paused at step") \(step + 1) of \(OtterPlaygroundModel.demoSequence.count) · \(model.scene.rawValue)"
    }
}

/// Scene-aware in both the playground and floating companion. A raft scene must
/// actually show the pair; a single reclining otter cannot communicate holding paws.
struct CoveDemoCharacter: View {
    @ObservedObject var model: OtterPlaygroundModel

    var body: some View {
        switch model.scene {
        case .raft, .rejoin:
            CovePairActor(linked: true, replay: model.replay)
        case .drift:
            CovePairActor(linked: false, drifting: true, replay: model.replay)
        default:
            OtterActor(store: model.store, replay: model.replay)
        }
    }
}

struct FloatingOtterPreview: View {
    @ObservedObject var model: OtterPlaygroundModel
    let move: ((CGSize, Bool) -> Void)?
    let open: () -> Void
    @State private var dragStart: CGPoint?

    init(model: OtterPlaygroundModel, move: ((CGSize, Bool) -> Void)? = nil, open: @escaping () -> Void) {
        self.model = model
        self.move = move
        self.open = open
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CoveDemoCharacter(model: model)
                .frame(width: 240, height: 180)
            Circle().fill(model.store.otterStatus.color).frame(width: 7, height: 7).padding(8)
        }
        .padding(12).contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { gesture in
                    let mouse = NSEvent.mouseLocation
                    let start = dragStart ?? CGPoint(x: mouse.x - gesture.translation.width,
                                                     y: mouse.y + gesture.translation.height)
                    dragStart = start
                    move?(CGSize(width: mouse.x - start.x, height: start.y - mouse.y), false)
                }
                .onEnded { gesture in
                    let mouse = NSEvent.mouseLocation
                    let translation = dragStart.map { CGSize(width: mouse.x - $0.x, height: $0.y - mouse.y) }
                        ?? gesture.translation
                    move?(translation, true)
                    dragStart = nil
                }
                .exclusively(before: TapGesture().onEnded { open() })
        )
        .focusable()
        .onKeyPress(keys: [.return, .space]) { _ in open(); return .handled }
        .help("Example · \(model.store.otterStatus.title). Drag to move. Click or press Space to open the raft and controls.")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Example otter. \(model.store.otterStatus.title)")
        .accessibilityHint("Opens the preview’s raft and gesture controls")
        .accessibilityAction { open() }
    }
}
