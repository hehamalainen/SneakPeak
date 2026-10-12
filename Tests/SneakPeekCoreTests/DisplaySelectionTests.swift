import Testing
import SneakPeekCore

@Test func displaySelectionUsesActiveDisplayAndPreservesItAcrossTopologyChanges() {
    // Laptop is first; the user is working on an external display.
    #expect(DisplaySelection.choose(available: [1, 2], preferred: nil, active: 2) == 2)
    // A new screen does not hijack the currently selected display.
    #expect(DisplaySelection.choose(available: [1, 2, 3], preferred: 2, active: 3) == 2)
    // Disconnection falls back to an available active screen.
    #expect(DisplaySelection.choose(available: [1, 3], preferred: 2, active: 3) == 3)
    #expect(DisplaySelection.choose(available: [], preferred: 2, active: 3) == nil)
}
