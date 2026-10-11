import SneakPeekCore
import SwiftUI

struct MissionEditor: View {
    @ObservedObject var store: PeekStore
    @State private var mission: Mission
    let save: (Mission) -> Void
    @State private var title: String
    @State private var goal: String
    @State private var owner: String
    @State private var constraints: String
    @State private var checks: [Checkpoint]
    @State private var evidenceAge: Double
    @State private var pinned: Bool
    init(store: PeekStore, mission: Mission, save: @escaping (Mission) -> Void) {
        self.store = store; _mission = State(initialValue: mission); self.save = save
        _title = State(initialValue: mission.title)
        _goal = State(initialValue: mission.goal)
        _owner = State(initialValue: mission.owner ?? "You")
        _constraints = State(initialValue: (mission.constraints ?? []).joined(separator: "\n"))
        _checks = State(initialValue: mission.checkpoints)
        _evidenceAge = State(initialValue: mission.evidenceMaxAgeSeconds ?? 86400)
        _pinned = State(initialValue: mission.pinned ?? true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Give this mission a destination.").font(.system(size: 24, weight: .medium, design: .rounded))
            Text("Evidence and human taste can both matter. Give each check a clear origin.").font(.caption).foregroundStyle(.secondary)
            if let message = store.message {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    Spacer()
                    Button("Reload latest") {
                        if let latest = store.feed.missions.first(where: { $0.id == mission.id }) {
                            mission = latest; title = latest.title; goal = latest.goal
                            owner = latest.owner ?? "You"; constraints = (latest.constraints ?? []).joined(separator: "\n")
                            checks = latest.checkpoints; evidenceAge = latest.evidenceMaxAgeSeconds ?? 86400
                            pinned = latest.pinned ?? true
                        }
                    }.font(.caption)
                }
            }
            HStack {
                TextField("Mission name", text: $title).textFieldStyle(.roundedBorder)
                TextField("Owner", text: $owner).textFieldStyle(.roundedBorder).frame(width: 140)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("The outcome").font(.headline)
                    TextEditor(text: $goal).font(.system(size: 13)).frame(height: 85).border(Color.gray.opacity(0.2))
                    Text("Constraints · one per line").font(.headline)
                    TextEditor(text: $constraints).font(.system(size: 12)).frame(height: 65).border(Color.gray.opacity(0.2))
                    HStack {
                        Text("Acceptance checks").font(.headline)
                        Spacer()
                        Button("Add check") { checks.append(Checkpoint(id: UUID().uuidString, label: "", status: "pending", evidence: "Awaiting evidence", source: "human", kind: "evidence", required: true)) }
                    }
                    ForEach($checks) { $check in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("What would count as success?", text: $check.label).textFieldStyle(.roundedBorder)
                                Button { checks.removeAll { $0.id == check.id } } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }.buttonStyle(.plain)
                            }
                            HStack {
                                Picker("Origin", selection: Binding(get: { check.kind ?? "evidence" }, set: { check.kind = $0 })) {
                                    Text("Inspectable evidence").tag("evidence")
                                    Text("Human Taste").tag("taste")
                                }.labelsHidden()
                                Spacer()
                                Toggle("Required", isOn: Binding(get: { check.required != false }, set: { check.required = $0 })).toggleStyle(.checkbox)
                            }.font(.caption)
                        }.padding(11).background(Color(red: 0.09, green: 0.095, blue: 0.105), in: RoundedRectangle(cornerRadius: 9))
                    }
                    Picker("Evidence freshness", selection: $evidenceAge) {
                        Text("1 hour").tag(3600.0)
                        Text("24 hours").tag(86400.0)
                        Text("7 days").tag(604800.0)
                        Text("Until goal or artifact changes").tag(0.0)
                    }
                    Toggle("Keep this mission visible between builds", isOn: $pinned)
                    Text("Changing the outcome, constraints, or checks requires fresh evidence and taste context. A Taste check records your subjective acceptance; it does not turn a hunch into a factual measurement.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                }
            }
            HStack {
                Spacer()
                Button("Save mission") {
                    var updated = mission
                    updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.owner = owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You" : owner
                    updated.constraints = constraints.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    updated.evidenceMaxAgeSeconds = evidenceAge
                    updated.pinned = pinned
                    updated.checkpoints = MissionEditing.nonblank(checks)
                    save(updated)
                }.buttonStyle(.borderedProminent).disabled(store.recording || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(27).frame(width: 570, height: 660).background(Color(red: 0.055, green: 0.060, blue: 0.067)).preferredColorScheme(.dark)
    }
}
