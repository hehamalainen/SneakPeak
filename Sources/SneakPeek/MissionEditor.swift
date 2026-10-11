import SneakPeekCore
import SwiftUI

struct MissionEditor: View {
    let mission: Mission
    let save: (Mission) -> Void
    @State private var title: String
    @State private var goal: String
    @State private var checks: [Checkpoint]
    init(mission: Mission, save: @escaping (Mission) -> Void) {
        self.mission = mission; self.save = save
        _title = State(initialValue: mission.title)
        _goal = State(initialValue: mission.goal)
        _checks = State(initialValue: mission.checkpoints)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Give this mission a destination.").font(.system(size: 24, weight: .medium, design: .rounded))
            Text("What outcome would make this build worth calling done?").foregroundStyle(.secondary)
            TextField("Mission name", text: $title).textFieldStyle(.roundedBorder)
            Text("The outcome").font(.headline)
            TextEditor(text: $goal).font(.system(size: 13)).frame(height: 100).border(Color.gray.opacity(0.2))
            Text("Landing checks").font(.headline)
            ScrollView {
                ForEach($checks) { $check in
                    HStack {
                        TextField("An observable outcome", text: $check.label).textFieldStyle(.roundedBorder)
                        Button { checks.removeAll { $0.id == check.id } } label: { Image(systemName: "minus.circle") }
                    }
                }
            }.frame(height: 110)
            Button("Add landing check") { checks.append(Checkpoint(id: UUID().uuidString, label: "", status: "pending", evidence: "Awaiting evidence", source: "human")) }
            Text("Use observable outcomes: a test that passes, a flow you can use, or a result you can inspect.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Save mission") {
                var updated = mission
                updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.checkpoints = MissionEditing.nonblank(checks)
                save(updated)
            }.buttonStyle(.borderedProminent).disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 480).preferredColorScheme(.dark)
    }
}
