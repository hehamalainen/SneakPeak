import AppKit
import SneakPeekCore
import SwiftUI

let tasteColor = Color(red: 0.77, green: 0.69, blue: 0.91)
private let reviewColor = Color(red: 0.94, green: 0.73, blue: 0.43)
private let checkedColor = Color(red: 0.76, green: 0.88, blue: 0.79)
private let trackingBackground = Color(red: 0.06, green: 0.065, blue: 0.075)

struct QueueRow: View {
    let item: QueueItem
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(item.kindLabel.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(0.8)
                        .foregroundStyle(item.kind == "taste" ? tasteColor : item.needsDecision || item.kind == "drift" ? reviewColor : .secondary)
                    Spacer()
                    Text(item.missionTitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(2)
                Text(item.why).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                HStack {
                    Text(item.needsDecision ? "A person needs to decide" : "Review suggested · no approval requested").font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(trackingBackground, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder((item.kind == "taste" ? tasteColor : reviewColor).opacity(item.needsDecision ? 0.2 : 0.06)))
        }.buttonStyle(.plain)
    }
}

struct MissionInspector: View {
    @ObservedObject var store: PeekStore
    let missionId: String
    private var mission: Mission? { store.feed.missions.first { $0.id == missionId } }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            if let mission {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(mission.title).font(.system(size: 24, weight: .medium, design: .rounded))
                        Text("Owner: \(mission.owner ?? "You")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Taste…") { store.onTaste?(mission, nil) }.foregroundStyle(tasteColor)
                    Button("Ask for judgment…") { store.onJudgment?(mission) }
                }
                Text(mission.goal).font(.system(size: 13)).lineSpacing(3)
                if let assessment = mission.assessment {
                    HStack {
                        Label(assessment.courseLabel, systemImage: assessment.course == "suspectedDrift" ? "arrow.triangle.branch" : "scope")
                        Spacer()
                        Text("\(assessment.verifiedCount) of \(assessment.requiredCount) required checks reviewed")
                    }.font(.caption).foregroundStyle(assessment.course == "suspectedDrift" ? reviewColor : checkedColor)
                    if !assessment.reasons.isEmpty {
                        Text(assessment.reasons.joined(separator: "\n")).font(.caption).foregroundStyle(reviewColor)
                    }
                }
                if let message = store.message { Text(message).font(.caption).foregroundStyle(reviewColor).textSelection(.enabled) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 13) {
                        ForEach(mission.checkpoints) { check in checkpoint(check, mission: mission) }
                        if let notes = mission.tasteNotes, !notes.isEmpty {
                            Text("Human Taste").font(.headline).foregroundStyle(tasteColor).padding(.top, 10)
                            ForEach(notes.prefix(12)) { note in tasteCard(note) }
                        }
                    }
                }
                Text("Evidence and human taste have different origins. A finished agent turn does not establish that these checks are met.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This mission is no longer available.").foregroundStyle(.secondary)
            }
        }.padding(25).frame(width: 590, height: 680).background(trackingBackground).preferredColorScheme(.dark)
    }

    private func checkpoint(_ check: Checkpoint, mission: Mission) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: check.verified ? "checkmark.circle.fill" : check.trackingState == "contradicted" || check.status == "rejected" ? "exclamationmark.circle" : "circle.dotted")
                    .foregroundStyle(check.verified ? checkedColor : reviewColor)
                Text(check.label).font(.system(size: 14, weight: .medium))
                Spacer()
                Text(check.required == false ? "Optional" : "Required").font(.caption2).foregroundStyle(.secondary)
            }
            if check.kind == "taste" {
                Text(check.verified ? "Human taste accepted · subjective judgment" : check.status == "rejected" ? "Human taste rejected" : "Your judgment is still missing")
                    .font(.caption).foregroundStyle(tasteColor)
                Text(check.evidence).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Add your Taste") { store.onTaste?(mission, check) }.buttonStyle(.bordered).foregroundStyle(tasteColor)
            } else {
                if check.records?.isEmpty != false {
                    Text("No inspectable evidence is attached. A text report alone does not verify this check.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array((check.records ?? []).prefix(8))) { evidence in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(evidence.summary).font(.system(size: 12)).textSelection(.enabled)
                        if let actor = evidence.actor { Text(actor).font(.caption2).foregroundStyle(.secondary) }
                        HStack {
                            Text(evidence.stateLabel).font(.caption2).foregroundStyle(evidence.state == "accepted" ? checkedColor : .secondary)
                            Spacer(); Text(store.age(evidence.observedAt)).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let reference = evidence.reference {
                            Text(reference).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                        }
                        HStack {
                            Button("Open reference") { store.openEvidence(evidence) }.disabled(store.showingDemo || evidence.reference == nil)
                            Spacer()
                            Button("Check met") { store.review(evidence, mission: mission, verdict: "accept") }
                            Button("Check not met") { store.review(evidence, mission: mission, verdict: "reject") }
                        }.font(.caption).buttonStyle(.bordered).disabled(store.recording || !evidence.reviewable || store.disconnected)
                    }.padding(11).background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                }
                Button("Attach evidence…") { store.onEvidence?(mission, check) }.font(.caption).buttonStyle(.bordered)
            }
        }.padding(15).background(Color(red: 0.09, green: 0.095, blue: 0.105), in: RoundedRectangle(cornerRadius: 13))
    }

    private func tasteCard(_ note: TasteSignal) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(note.label).font(.system(size: 13, weight: .medium)).foregroundStyle(tasteColor)
                Text(note.strength == "hunch" ? "A hunch" : "A considered preference").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(store.age(note.createdAt)).font(.caption2).foregroundStyle(.secondary)
            }
            if !note.note.isEmpty { Text(note.note).font(.system(size: 12)).lineSpacing(3) }
            Text(note.contextStale == true ? "Recorded for an earlier goal" : note.resolved == true ? "Review resolved: \(note.resolution ?? "recorded")" : note.impact == "review" ? "Human review requested" : "An annotation · no decision requested")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(13).background(tasteColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct QueueInspector: View {
    @ObservedObject var store: PeekStore
    let itemId: String
    private var item: QueueItem? { store.queue.first { $0.id == itemId } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let item, let mission = store.feed.missions.first(where: { $0.id == item.missionId }) {
                Text(item.kindLabel.uppercased()).font(.caption).tracking(1).foregroundStyle(item.kind == "taste" ? tasteColor : reviewColor)
                Text(item.title).font(.system(size: 26, weight: .medium, design: .rounded))
                Text(mission.title + " · " + mission.goal).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(item.why).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                        Text(item.impact).font(.caption).foregroundStyle(.secondary)
                        if item.contextStale == true {
                            Label("This request was recorded for an earlier goal. Dismiss it or create a fresh request.", systemImage: "clock.arrow.circlepath")
                                .font(.caption).foregroundStyle(reviewColor)
                        }
                        if item.kind == "runtime", let agent = store.feed.agents.first(where: { $0.id == item.agentId }),
                           let request = agent.request, request.id == item.requestId {
                            if request.canAnswer(at: store.now) && !store.disconnected {
                                HStack {
                                    ForEach(request.choices) { choice in
                                        Button(choice.label) { store.answer(agent, choice) }
                                            .disabled(store.sentRequests.contains(request.id))
                                    }
                                }.buttonStyle(.borderedProminent)
                                Text("The reply is scoped to this host request. It stays pending until the host confirms.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Open source session") { store.open(agent) }.buttonStyle(.bordered)
                        } else if ["taste", "judgment"].contains(item.kind) {
                            Text("Record your judgment here. Open the source workflow to turn a direction change into agent guidance.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Keep this direction") { store.resolve(item, outcome: "keep") }.disabled(item.contextStale == true)
                                Button("Record a direction change") { store.resolve(item, outcome: "change") }.disabled(item.contextStale == true)
                                Button("Dismiss this concern") { store.resolve(item, outcome: "dismiss") }
                            }.font(.caption).buttonStyle(.bordered).disabled(store.recording || store.disconnected)
                            if let agent = store.feed.agents.first(where: { $0.missionId == mission.id }) {
                                Button("Open source workflow") { store.open(agent) }.buttonStyle(.bordered)
                            }
                        } else {
                            Button("Inspect checkpoints and evidence") { store.onInspectMission?(mission) }.buttonStyle(.borderedProminent)
                            if let agent = store.feed.agents.first(where: { $0.id == item.agentId }) {
                                Button("Open source session") { store.open(agent) }.buttonStyle(.bordered)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("This item is no longer pending.").font(.system(size: 23, weight: .medium, design: .rounded))
                Text("The source or your local judgment record cleared it.").foregroundStyle(.secondary)
            }
            if let message = store.message { Text(message).font(.caption).foregroundStyle(reviewColor).textSelection(.enabled) }
        }.padding(27).frame(width: 570, height: 510).background(trackingBackground).preferredColorScheme(.dark)
    }
}

struct QueueManager: View {
    @ObservedObject var store: PeekStore
    @State private var filter = "decisions"
    private var items: [QueueItem] {
        store.queue.filter { filter == "all" || (filter == "decisions" && $0.needsDecision) || (filter == "review" && !$0.needsDecision) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Your decision queue.").font(.system(size: 26, weight: .medium, design: .rounded))
            Text("\(store.attentionCount) decisions · \(store.queue.filter { !$0.needsDecision }.count) review items")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Show", selection: $filter) {
                Text("Decisions").tag("decisions"); Text("Review suggested").tag("review"); Text("All").tag("all")
            }.pickerStyle(.segmented)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in QueueRow(item: item) { store.onQueue?(item) } }
                    if items.isEmpty { Text("Nothing is waiting in this category.").foregroundStyle(.secondary).padding(.vertical, 35) }
                }
            }
            Text("Missing evidence and suspected drift are review items. Only explicit host requests or human requests enter the decision count.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(25).frame(width: 575, height: 670).background(trackingBackground).preferredColorScheme(.dark)
    }
}

struct TasteEditor: View {
    @ObservedObject var store: PeekStore
    let mission: Mission
    let close: @MainActor @Sendable () -> Void
    @State private var valence = "uncertain"
    @State private var strength = "hunch"
    @State private var note = ""
    @State private var review = false
    @State private var target = ""
    @State private var acceptance = "unassessed"
    init(store: PeekStore, mission: Mission, checkpoint: Checkpoint?, close: @escaping @MainActor @Sendable () -> Void) {
        self.store = store; self.mission = mission; self.close = close
        _target = State(initialValue: checkpoint?.id ?? "")
    }
    private var tasteChecks: [Checkpoint] { mission.checkpoints.filter { $0.kind == "taste" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a little Taste.").font(.system(size: 27, weight: .medium, design: .rounded)).foregroundStyle(tasteColor)
            Text("A hunch is welcome. Words are optional.").foregroundStyle(.secondary)
            Text(mission.title).font(.caption).foregroundStyle(.secondary)
            Picker("How it feels", selection: $valence) {
                Text("Feels right").tag("right"); Text("Feels off").tag("off"); Text("Not sure").tag("uncertain")
            }.pickerStyle(.segmented)
            Picker("Strength", selection: $strength) {
                Text("A hunch").tag("hunch"); Text("A considered preference").tag("conviction")
            }.pickerStyle(.segmented)
            Text("What feels right or wrong?").font(.headline)
            TextEditor(text: $note).font(.system(size: 13)).frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.1)))
            if !tasteChecks.isEmpty {
                Picker("Context", selection: $target) {
                    Text("The whole workflow").tag("")
                    ForEach(tasteChecks) { check in Text(check.label).tag(check.id) }
                }
                if !target.isEmpty {
                    Picker("Taste check", selection: $acceptance) {
                        Text("Just a note").tag("unassessed")
                        Text("This check feels met").tag("accept")
                        Text("This check feels unmet").tag("reject")
                    }
                }
            }
            Toggle("Ask for a human review", isOn: $review)
            Text("A Taste note is human judgment. It changes only a check explicitly defined as human taste; objective evidence keeps its own status.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            if let message = store.message { Text(message).font(.caption).foregroundStyle(reviewColor) }
            HStack {
                Button("Cancel", action: close); Spacer()
                Button(review ? "Add Taste and request review" : "Keep this Taste note") {
                    store.post("taste", payload: ["missionId": mission.id, "goalRevision": mission.goalRevision ?? "",
                               "checkpointId": target, "valence": valence, "strength": strength,
                               "note": note, "impact": review ? "review" : "note",
                               "acceptance": target.isEmpty ? "unassessed" : acceptance]) { success in if success { close() } }
                }.buttonStyle(.borderedProminent).tint(tasteColor).disabled(store.recording || store.disconnected)
            }
        }.padding(27).frame(width: 550).background(trackingBackground).preferredColorScheme(.dark)
    }
}

struct EvidenceEditor: View {
    @ObservedObject var store: PeekStore
    let mission: Mission
    let checkpoint: Checkpoint
    let close: @MainActor @Sendable () -> Void
    @State private var summary = ""
    @State private var reference = ""
    @State private var verdict = "supports"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Give this check evidence.").font(.system(size: 25, weight: .medium, design: .rounded))
            Text(checkpoint.label).font(.headline)
            Text("What does this record show?").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $summary).font(.system(size: 13)).frame(height: 120).border(Color.white.opacity(0.1))
            Picker("Claim", selection: $verdict) {
                Text("Supports the check").tag("supports")
                Text("Contradicts the check").tag("contradicts")
                Text("Still uncertain").tag("unknown")
            }
            HStack {
                TextField("Artifact file or HTTPS reference", text: $reference).textFieldStyle(.roundedBorder)
                Button("Choose file…") {
                    let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false
                    picker.allowsMultipleSelection = false
                    if picker.runModal() == .OK { reference = picker.url?.path ?? "" }
                }
            }
            Text("Local files are recorded with a content digest and file version. A report remains a claim until a person reviews whether it meets the check.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            if let message = store.message { Text(message).font(.caption).foregroundStyle(reviewColor) }
            HStack {
                Button("Cancel", action: close); Spacer()
                Button("Attach this evidence") {
                    store.post("evidence", payload: ["missionId": mission.id, "goalRevision": mission.goalRevision ?? "",
                               "checkpointId": checkpoint.id, "summary": summary, "reference": reference, "verdict": verdict]) { success in if success { close() } }
                }.buttonStyle(.borderedProminent).disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reference.isEmpty || store.recording || store.disconnected)
            }
        }.padding(27).frame(width: 550).background(trackingBackground).preferredColorScheme(.dark)
    }
}

struct JudgmentEditor: View {
    @ObservedObject var store: PeekStore
    let mission: Mission
    let close: @MainActor @Sendable () -> Void
    @State private var title = ""
    @State private var why = ""
    @State private var impact = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A decision worth your attention.").font(.system(size: 23, weight: .medium, design: .rounded))
            Text(mission.title).foregroundStyle(.secondary)
            TextField("What needs human judgment?", text: $title).textFieldStyle(.roundedBorder)
            Text("Why now?").font(.headline)
            TextEditor(text: $why).font(.system(size: 13)).frame(height: 120).border(Color.white.opacity(0.1))
            TextField("What is affected, or what happens if this waits?", text: $impact).textFieldStyle(.roundedBorder)
            Text("This creates a local judgment request. It does not pause an agent or grant a runtime permission.").font(.caption).foregroundStyle(.secondary)
            if let message = store.message { Text(message).font(.caption).foregroundStyle(reviewColor) }
            HStack {
                Button("Cancel", action: close); Spacer()
                Button("Add to the decision queue") {
                    store.post("judgment", payload: ["missionId": mission.id, "goalRevision": mission.goalRevision ?? "",
                               "title": title, "why": why, "impact": impact]) { success in if success { close() } }
                }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.recording || store.disconnected)
            }
        }.padding(27).frame(width: 560).background(trackingBackground).preferredColorScheme(.dark)
    }
}
