import Foundation
import Testing
@testable import SneakPeek

@Test @MainActor func draggingCancelsPendingHoverCollapseAndSuppressesHoverResize() async throws {
    let store = PeekStore(stateURL: URL(fileURLWithPath: "/unused-panel-drag-state.json"), demo: true,
                          ownsApprovalSurface: false, automaticReload: false, readInitialFeed: false)
    store.setExpanded(true)
    store.hover(false)
    var began = false
    var moved: Bool?
    store.onPanelDragBegan = { began = true }
    store.onPanelDragEnded = { moved = $0 }
    store.beginPanelDrag()
    #expect(began)
    store.hover(false)
    try await Task.sleep(for: .milliseconds(750))
    #expect(store.expanded)
    store.setExpanded(false)
    store.hover(true)
    #expect(!store.expanded)
    store.endPanelDrag(moved: true)
    #expect(moved == true)
    store.hover(true)
    #expect(store.expanded)
}
