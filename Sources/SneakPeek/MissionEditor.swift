import SneakPeekCore
import SwiftUI

struct MissionEditor: View {
    let mission: Mission
    let save: (Mission) -> Void
    @State private var title: String
    @State private var goal: String
    @State private var checks: String
    init(mission: Mission, save: @escaping (Mission) -> Void) {
        self.mission = mission; self.save = save
        _title = State(initialValue: mission.title)
        _goal = State(initialValue: mission.goal)
        _checks = State(initialValue: mission.checkpoints.map(\.label).joined(separator: "\n"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Give this mission a destination.").font(.system(size: 24, weight: .medium, design: .rounded))
            Text("What outcome would make this build worth calling done?").foregroundStyle(.secondary)
            TextField("Mission name", text: $title).textFieldStyle(.roundedBorder)
            Text("The outcome").font(.headline)
            TextEditor(text: $goal).font(.system(size: 13)).frame(height: 100).border(Color.gray.opacity(0.2))
            Text("Landing checks · one per line").font(.headline)
            TextEditor(text: $checks).font(.system(size: 13)).frame(height: 110).border(Color.gray.opacity(0.2))
            Text("Use observable outcomes: a test that passes, a flow you can use, or a result you can inspect.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Save mission") {
                var updated = mission
                updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.checkpoints = checks.split(separator: "\n").map { line in
                    let label = String(line).trimmingCharacters(in: .whitespaces)
                    if let old = mission.checkpoints.first(where: { $0.label == label }) { return old }
                    return Checkpoint(id: UUID().uuidString, label: label, status: "pending", evidence: "Awaiting evidence", source: "human")
                }
                save(updated)
            }.buttonStyle(.borderedProminent).disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 480).preferredColorScheme(.dark)
    }
}
