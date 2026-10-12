import SneakPeekCore
import SwiftUI

enum RaftCourse { case onCourse, atRisk, unknown }

@MainActor func raftCourse(_ agent: Agent, store: PeekStore) -> RaftCourse {
    guard !store.disconnected, !agent.isQuiet(at: store.now), agent.progressFreshness != "stale",
          agent.lastProgress > 0, store.now - agent.lastProgress <= 300 else { return .unknown }
    if agent.trajectory == "atRisk" { return .atRisk }
    if agent.trajectory == "onCourse" { return .onCourse }
    return .unknown
}

struct RaftView: View {
    @ObservedObject var store: PeekStore
    var body: some View { CoveRaft(store: store) }
}
