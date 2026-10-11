import AppKit
import SneakPeekCore
import SwiftUI

struct HarnessManager: View {
    @ObservedObject var store: PeekStore
    @State private var adding = false
    @State private var name = ""
    @State private var eventPath = ""
    @State private var format = "sneakpeek"
    @State private var historyHours = 24.0
    @State private var expandedLocations = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your harnesses.").font(.system(size: 27, weight: .medium, design: .rounded))
                    Text("A connection stays visible even between builds.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(adding ? "Cancel" : "Add harness…") { adding.toggle() }.buttonStyle(.bordered)
            }
            if let message = store.message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text("Show sessions updated within").font(.caption).foregroundStyle(.secondary)
                Picker("History window", selection: $historyHours) {
                    Text("24 hours").tag(24.0)
                    Text("7 days").tag(168.0)
                    Text("30 days").tag(720.0)
                }.labelsHidden().frame(width: 125)
                Spacer()
            }
            .onAppear { historyHours = store.settings.recentHours ?? 24 }
            .onChange(of: historyHours) { _, value in store.setHistoryHours(value) }
            if adding { addForm }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.harnesses) { harness in card(harness) }
                }
            }
            Text("Local observation is automatic. Optional project hooks provide clearer completion signals. Permission requests are answered in their source UI unless an approval adapter is connected.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }.padding(25).frame(width: 565, height: 670)
            .background(Color(red: 0.045, green: 0.050, blue: 0.055)).preferredColorScheme(.dark)
    }

    private func card(_ harness: HarnessInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle().fill(harness.status == "ready" ? Color.green.opacity(0.7) : Color.gray).frame(width: 7, height: 7)
                Text(harness.name).font(.headline)
                Button {
                    if expandedLocations.contains(harness.id) { expandedLocations.remove(harness.id) }
                    else { expandedLocations.insert(harness.id) }
                } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Show event log locations")
                Spacer()
                Toggle("Observe", isOn: Binding(get: { harness.enabled }, set: { store.enableHarness(harness, enabled: $0) }))
                    .toggleStyle(.switch).labelsHidden().help("Observe \(harness.name)")
            }
            Text(harness.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
            HStack {
                if let last = harness.lastSeen { Text("Last log update: \(store.age(last))").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if ["antigravity", "copilot"].contains(harness.id) {
                    Button("Set up in a project…") { store.onSetup?(harness) }.font(.caption).buttonStyle(.bordered)
                }
                if !harness.builtin && harness.format == "sneakpeek" {
                    Button("Copy event command") { store.copyPublishingCommand(harness.id) }.font(.caption).buttonStyle(.bordered)
                }
            }
            if expandedLocations.contains(harness.id) {
                ForEach(harness.logs, id: \.self) { path in Text(path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }.padding(12).background(Color(red: 0.080, green: 0.085, blue: 0.095), in: RoundedRectangle(cornerRadius: 13))
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Harness name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Event format", selection: $format) {
                Text("SneakPeek events · any harness").tag("sneakpeek")
                Text("Codex session format").tag("codex")
                Text("Claude session format").tag("claude")
                Text("Copilot session format").tag("copilot")
                Text("Antigravity transcript format").tag("antigravity")
            }
            HStack {
                TextField("Event log path · leave empty to create a local feed", text: $eventPath).textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.canChooseFiles = true
                    picker.allowsMultipleSelection = false
                    if picker.runModal() == .OK { eventPath = picker.url?.path ?? "" }
                }
            }
            Text("Use the standard event format for a new harness, or point to an existing log in a supported format. No rebuild needed.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy event publishing help") {
                    store.copyPublishingCommand()
                }.font(.caption)
                Spacer()
                Button("Add harness") {
                    if store.addHarness(name: name, eventPath: eventPath, format: format) {
                        adding = false; name = ""; eventPath = ""; format = "sneakpeek"
                    }
                }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(15).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))
    }
}
