import AppKit
import SneakPeekCore
import SwiftUI

private let ink = Color(red: 0.055, green: 0.060, blue: 0.067)
private let muted = Color(red: 0.56, green: 0.58, blue: 0.60)
private let mint = Color(red: 0.76, green: 0.88, blue: 0.79)
private let amber = Color(red: 0.94, green: 0.73, blue: 0.43)
private let blue = Color(red: 0.52, green: 0.68, blue: 0.94)

private func agentColor(_ agent: Agent, now: Double) -> Color {
    if agent.needsHuman(at: now) { return amber }
    if agent.isQuiet(at: now) { return muted }
    if agent.status == "done" { return mint }
    if agent.status == "working" { return blue }
    return muted
}

struct PeekView: View {
    @ObservedObject var store: PeekStore
    let cameraHeight: CGFloat
    @State private var pane = "queue"
    init(store: PeekStore, cameraHeight: CGFloat, showRaft: Bool = false) {
        self.store = store
        self.cameraHeight = cameraHeight
        _pane = State(initialValue: showRaft ? "team" : "queue")
    }
    var body: some View {
        VStack(spacing: 0) {
            cameraRow
            if store.expanded { expandedView }
            else if store.companionMode == .otter { OtterGlance(store: store).padding(.bottom, 8) }
            else { glance }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: store.expanded ? 26 : 18, bottomTrailingRadius: store.expanded ? 26 : 18))
        .overlay(alignment: .bottom) {
            Capsule().fill(Color.white.opacity(0.14)).frame(width: 30, height: 3).padding(.bottom, 6)
        }
        .foregroundStyle(Color(red: 0.92, green: 0.93, blue: 0.91))
        .font(.system(size: 12))
        .preferredColorScheme(.dark)
        .onHover { inside in
            if store.companionMode == .native || store.expanded { store.hover(inside) }
        }
    }

    private var cameraRow: some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: "eye").font(.system(size: 11, weight: .medium))
                if store.expanded { Text("sneakpeek").font(.system(size: 11, weight: .semibold)) }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 9))
            }.foregroundStyle(muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(PanelDragRegion(began: { store.beginPanelDrag() },
                                         ended: { store.endPanelDrag(moved: $0) }))
                .help("Drag the header to move SneakPeek")
            if store.expanded {
                Button { store.pinned.toggle() } label: {
                    Image(systemName: store.pinned ? "pin.fill" : "pin").foregroundStyle(store.pinned ? mint : muted)
                }.buttonStyle(.plain).help("Keep this peek open")
                Button { store.pinned = false; store.setExpanded(false) } label: {
                    Image(systemName: "chevron.up").foregroundStyle(muted)
                }.buttonStyle(.plain).padding(.leading, 8).help("Collapse")
            } else {
                Text(store.disconnected ? "···" : store.attentionCount > 0 ? "\(store.attentionCount)" : "·")
                    .foregroundStyle(store.attentionCount > 0 ? amber : mint)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 19)
        .frame(height: cameraHeight)
    }

    private var glance: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(Array(store.feed.agents.prefix(6))) { agent in
                    Circle().fill(store.disconnected ? muted : agentColor(agent, now: store.now)).frame(width: 5, height: 5)
                }
                if store.feed.agents.count > 6 { Text("+\(store.feed.agents.count - 6)").font(.system(size: 9)).foregroundStyle(muted) }
            }
            Text(store.disconnected ? "Connection quiet" : store.attentionCount > 0 ? "\(store.attentionCount) decisions" : store.driftCount > 0 ? "\(store.driftCount) course concerns" : store.evidenceGapCount > 0 ? "Evidence incomplete" : store.feed.agents.isEmpty ? "Ready when you are" : "Room to focus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(store.disconnected ? muted : store.attentionCount > 0 ? amber : mint)
            if !store.showingDemo, store.hasUnsignedReviews {
                Text("UNSIGNED").font(.system(size: 7, weight: .semibold)).foregroundStyle(muted)
            }
            if store.showingDemo { Text("DEMO").font(.system(size: 7, weight: .bold)).foregroundStyle(muted) }
        }
        .frame(maxWidth: .infinity).frame(height: 25).padding(.bottom, 8)
        .contentShape(Rectangle()).onTapGesture { store.setExpanded(true) }
        .accessibilityElement(children: .combine)
    }

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("YOUR FOCUS, PROTECTED").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(muted)
                Spacer()
                Menu {
                    Button("All sources") { store.filterProvider("All sources") }
                    Divider()
                    ForEach(store.harnesses) { harness in
                        Button(harness.name) { store.filterProvider(harness.provider) }
                    }
                    Divider()
                    Button("Manage harnesses…") { store.manageHarnesses() }
                } label: {
                    Text(store.providerFilter == "All sources" ? (store.showingDemo ? "EXAMPLE · ALL SOURCES" : "LIVE · ALL SOURCES") : store.providerFilter.uppercased())
                        .font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(store.showingDemo ? amber : mint)
                }.menuStyle(.borderlessButton).fixedSize().help("Choose or connect an agent harness")
            }.padding(.top, 17)
            HStack(alignment: .bottom) {
                Text(headline).font(.system(size: 27, weight: .medium, design: .rounded)).tracking(-0.7).lineSpacing(-1)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(store.visibleAgents.count)").font(.system(size: 25, weight: .light, design: .rounded))
                    Text(store.visibleAgents.count == 1 ? "agent connected" : "agents connected").font(.system(size: 9)).foregroundStyle(muted)
                }.padding(.bottom, 3)
            }.padding(.top, 11).padding(.bottom, 19)

            if store.disconnected {
                Label("The observer is quiet. Status may be out of date.", systemImage: "wifi.slash")
                    .font(.system(size: 10)).foregroundStyle(amber).padding(.bottom, 10)
            }
            if let warning = store.feed.warnings?.first {
                Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(amber).padding(.bottom, 8)
            }

            if let mission = store.mission {
                missionCard(mission)
                HStack(spacing: 20) {
                    tab("Queue", selected: pane == "queue") { pane = "queue" }
                    tab("Checkpoints", selected: pane == "checks") { pane = "checks" }
                    tab(store.companionMode == .otter ? "Raft" : "Team", selected: pane == "team") { pane = "team" }
                    Spacer()
                    Text("\(mission.checkpoints.filter(\.verified).count) checked").font(.system(size: 9)).foregroundStyle(muted)
                }.padding(.top, 18).padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 9) {
                        if pane == "checks" { checkpointView(mission) }
                        else if pane == "team" {
                            if store.companionMode == .otter { RaftView(store: store) }
                            ForEach(store.agents) { agent in
                                agentCard(agent)
                                if store.selectedAgent?.id == agent.id { detail(agent) }
                            }
                        } else {
                            ForEach(Array(store.visibleQueue.prefix(5))) { item in QueueRow(item: item) { store.onQueue?(item) } }
                            if store.visibleQueue.isEmpty {
                                Text("No decisions or review items are waiting.").font(.system(size: 12)).foregroundStyle(muted).padding(.vertical, 20)
                            }
                            Button("Open the full decision queue ↗") { store.onShowQueue?() }
                                .buttonStyle(PeekButtonStyle(color: mint))
                        }
                    }.padding(.bottom, 8)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "sparkle").font(.system(size: 30, weight: .light)).foregroundStyle(mint)
                    Text("Your next build,\na little more in view.").font(.system(size: 23, weight: .light, design: .rounded))
                    Text(store.filteredHarness?.detail ?? "Start a Codex, Claude Code, Antigravity, or Copilot session. Recent local sessions appear here automatically.")
                        .foregroundStyle(muted).lineSpacing(4)
                    if let harness = store.filteredHarness, let last = harness.lastSeen {
                        Text("Last event log update: \(store.age(last))").font(.system(size: 10)).foregroundStyle(muted)
                    }
                    Button("Manage harnesses…") { store.manageHarnesses() }.buttonStyle(PeekButtonStyle(color: mint))
                    Button(store.providerFilter == "All sources" ? "Try the example mission" : "Show all sources") {
                        if store.providerFilter == "All sources" { store.toggleMode() } else { store.filterProvider("All sources") }
                    }.buttonStyle(PeekButtonStyle(color: mint))
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.vertical, 25)
            }
            footer
        }.padding(.horizontal, 22).padding(.bottom, 18)
    }

    private var headline: String {
        if store.disconnected { return "A quiet connection.\nTake a closer look." }
        if store.visibleAttentionCount == 1 { return "One decision.\nThen back to flow." }
        if store.visibleAttentionCount > 1 { return "A few decisions.\nOne place to land." }
        if store.driftCount > 0 { return "A course concern.\nLook at the evidence." }
        if store.evidenceGapCount > 0 { return "A clearer checkpoint.\nEvidence still missing." }
        return "Room to focus.\nA glance when you need it."
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : muted)
                .padding(.bottom, 6).overlay(alignment: .bottom) {
                    if selected { Capsule().fill(mint).frame(height: 2) }
                }
        }.buttonStyle(.plain)
    }

    private func missionCard(_ mission: Mission) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "scope").foregroundStyle(mint)
                if store.missions.count > 1 {
                    Menu {
                        ForEach(store.missions) { item in
                            Button(item.title) { store.selectedMissionId = item.id; store.selectedAgentId = nil }
                        }
                    } label: { Text(mission.title).font(.system(size: 12, weight: .semibold)) }
                        .menuStyle(.borderlessButton).fixedSize()
                } else { Text(mission.title).font(.system(size: 12, weight: .semibold)) }
                Spacer()
                Button { store.onEdit?(mission) } label: { Image(systemName: "pencil").foregroundStyle(muted) }
                    .buttonStyle(.plain).disabled(store.showingDemo).help("Define the goal and landing checks")
            }
            if mission.goalOrigin == "first-prompt" {
                Text("Inferred from the first prompt · edit to confirm the goal").font(.system(size: 9)).foregroundStyle(muted)
            }
            Text(mission.goal).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.78)).lineLimit(3).lineSpacing(3)
            HStack(spacing: 5) {
                Circle().fill(mission.checkpoints.isEmpty ? muted : mint).frame(width: 4, height: 4)
                Text(mission.assessment?.courseLabel ?? "Destination needs a checkpoint")
                    .font(.system(size: 9)).foregroundStyle(muted)
                Spacer()
                Button("Taste…") { store.onTaste?(mission, nil) }.font(.system(size: 9)).foregroundStyle(tasteColor).buttonStyle(.plain)
            }.padding(.top, 2)
            if let assessment = mission.assessment {
                HStack {
                    Text(assessment.evidenceLabel).font(.system(size: 9)).foregroundStyle(assessment.evidence == "conflicting" ? amber : muted)
                    Spacer()
                    Button("Inspect ↗") { store.onInspectMission?(mission) }.font(.system(size: 9)).foregroundStyle(mint).buttonStyle(.plain)
                }
            }
        }.padding(14).background(ink, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.07)))
    }

    private func agentCard(_ agent: Agent) -> some View {
        let selected = store.selectedAgent?.id == agent.id
        return Button {
            store.selectedAgentId = selected && !agent.needsHuman(at: store.now) ? nil : agent.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(agentColor(agent, now: store.now)).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(agent.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(agent.provider.uppercased()).font(.system(size: 7, weight: .medium)).tracking(0.7).foregroundStyle(muted)
                        Spacer()
                        Text(agent.statusLabel(at: store.now)).font(.system(size: 9)).foregroundStyle(agentColor(agent, now: store.now))
                    }
                    Text(agent.summary).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.60)).lineLimit(2).multilineTextAlignment(.leading)
                    if agent.isQuiet(at: store.now) {
                        Text("Last observed \(store.age(agent.lastActivity)) · still working or disconnected")
                            .font(.system(size: 9)).foregroundStyle(muted)
                    }
                }
                Image(systemName: selected ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundStyle(muted).padding(.top, 4)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.white.opacity(0.055) : ink.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? agentColor(agent, now: store.now).opacity(0.28) : .clear))
        }.buttonStyle(.plain)
    }

    private func detail(_ agent: Agent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let request = agent.request {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised").font(.system(size: 11))
                    Text(request.title).font(.system(size: 12, weight: .semibold))
                }.foregroundStyle(amber)
                Text(request.detail).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.75)).lineSpacing(3).textSelection(.enabled)
                if request.canAnswer(at: store.now) && !store.disconnected && (store.showingDemo || request.transport == "trusted-local-file") {
                    if !store.showingDemo {
                        Text("Trusted local mode · anyone able to write this state can forge a reply").font(.system(size: 9)).foregroundStyle(amber)
                    }
                    HStack(spacing: 8) {
                        ForEach(request.choices) { choice in
                            Button(choice.label) { store.answer(agent, choice) }
                                .buttonStyle(PeekButtonStyle(color: choice.id == "accept" ? amber : muted))
                                .disabled(store.sentRequests.contains(request.id))
                        }
                    }
                    if store.sentRequests.contains(request.id) {
                        Text("Sent. Waiting for confirmation from the agent.").font(.system(size: 9)).foregroundStyle(muted)
                    }
                } else {
                    Text(request.mode == "handoff" || request.transport != "trusted-local-file" && !store.showingDemo ? "This session needs your answer at its source." : !request.hasValidLifetime ? "This request needs a fresh update. Answer at the source." : "Request expired. Check the source session.")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
            }
            HStack {
                Text(agent.progressFreshness == "stale" ? "PROGRESS CLAIM IS STALE" : agent.trajectory == "atRisk" ? "COURSE NEEDS REVIEW" : agent.trajectory == "onCourse" ? "PROGRESS · AGENT REPORTED" : "COURSE NOT YET CHECKED")
                    .font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(agent.trajectory == "atRisk" ? amber : muted)
                Spacer()
                Text(store.age(agent.lastProgress)).font(.system(size: 8)).foregroundStyle(muted)
            }
            Text(agent.evidence).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.70)).lineSpacing(3)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(mint)
                Text(agent.nextStep).font(.system(size: 10)).foregroundStyle(muted)
            }
            Button { store.open(agent) } label: {
                HStack { Text(agent.provider == "Claude" || agent.provider == "GitHub Copilot" ? "Copy session resume command" : agent.provider == "Antigravity" ? "Open artifacts · copy conversation ID" : agent.handoffKind == "copy-id" ? "Copy source session ID" : "Open exact session"); Spacer(); Image(systemName: "arrow.up.right") }
            }.buttonStyle(PeekButtonStyle(color: mint)).disabled(store.showingDemo)
        }.padding(14).background(ink, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func checkpointView(_ mission: Mission) -> some View {
        if mission.checkpoints.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Where should this mission land?").font(.system(size: 17, weight: .medium, design: .rounded))
                Text("Define two or three observable checks. Activity alone does not tell us whether the goal is being reached.")
                    .foregroundStyle(muted).lineSpacing(4)
                Button("Define landing checks") { store.onEdit?(mission) }.buttonStyle(PeekButtonStyle(color: mint))
            }.padding(.vertical, 16)
        } else {
            ForEach(mission.checkpoints) { checkpoint in
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: checkpoint.verified ? "checkmark.circle.fill" : checkpoint.status == "reported" ? "circle.dotted" : "circle")
                        .foregroundStyle(checkpoint.verified ? mint : muted).font(.system(size: 17))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(checkpoint.label).font(.system(size: 12, weight: .medium))
                        Text(checkpoint.evidence).font(.system(size: 10)).foregroundStyle(muted).lineSpacing(3)
                        Text(checkpoint.kind == "taste" ? (checkpoint.verified ? "Human taste accepted" : "Needs human taste judgment") : checkpoint.verified ? "Local evidence review recorded" : checkpoint.status == "reported" ? "Evidence reported · awaiting review" : checkpoint.status == "rejected" ? "A check was contradicted" : "Evidence missing or stale")
                            .font(.system(size: 9)).foregroundStyle(checkpoint.verified ? mint : muted)
                        Button(checkpoint.kind == "taste" ? "Add Taste" : "Inspect evidence") {
                            if checkpoint.kind == "taste" { store.onTaste?(mission, checkpoint) }
                            else { store.onInspectMission?(mission) }
                        }.buttonStyle(PeekButtonStyle(color: checkpoint.kind == "taste" ? tasteColor : mint))
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(ink, in: RoundedRectangle(cornerRadius: 12))
            }
            Text("A finished turn is a handoff. These checks define a finished mission.")
                .font(.system(size: 10)).foregroundStyle(muted).lineSpacing(3).padding(.top, 5)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = store.message { Text(message).font(.system(size: 9)).foregroundStyle(amber).lineLimit(2) }
            if store.attentionCount > store.visibleAttentionCount {
                Button("\(store.attentionCount - store.visibleAttentionCount) needs you in another source ↗") { store.filterProvider("All sources") }
                    .font(.system(size: 9)).foregroundStyle(amber).buttonStyle(.plain)
            }
            HStack {
                Circle().fill(store.disconnected ? amber : mint).frame(width: 4, height: 4)
                Text(store.showingDemo ? "Example data · try a decision" : "On this Mac · no account connection").font(.system(size: 9)).foregroundStyle(muted)
                Spacer()
                Menu {
                    Button { store.setCompanionMode(.native) } label: {
                        Label("Native", systemImage: store.companionMode == .native ? "checkmark" : "eye")
                    }
                    Button { store.setCompanionMode(.otter) } label: {
                        Label("Otter", systemImage: store.companionMode == .otter ? "checkmark" : "pawprint")
                    }
                } label: { Image(systemName: store.companionMode == .otter ? "pawprint" : "paintbrush") }
                    .menuStyle(.borderlessButton).fixedSize().help("Choose Native or Otter appearance")
                Button { store.manageHarnesses() } label: { Image(systemName: "slider.horizontal.3") }
                    .font(.system(size: 10)).foregroundStyle(muted).buttonStyle(.plain).help("Manage harnesses and add another")
                Button(store.showingDemo ? "Go live ↗" : "Try demo ↗") { store.toggleMode() }
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(mint).buttonStyle(.plain)
            }
        }.padding(.top, 12)
    }
}

struct PeekButtonStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(color)
            .background(color.opacity(configuration.isPressed ? 0.22 : 0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.15)))
    }
}
