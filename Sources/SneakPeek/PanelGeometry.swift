import SwiftUI

@MainActor final class PanelGeometry: ObservableObject {
    @Published var cameraHeight: CGFloat = 30
}

struct LivePeekRoot: View {
    @ObservedObject var store: PeekStore
    @ObservedObject var geometry: PanelGeometry
    var showRaft: Bool

    var body: some View {
        PeekView(store: store, cameraHeight: geometry.cameraHeight, showRaft: showRaft)
    }
}
