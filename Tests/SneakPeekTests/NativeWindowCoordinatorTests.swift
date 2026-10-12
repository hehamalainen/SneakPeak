import Testing
@testable import SneakPeek

@MainActor private final class TestToolWindow: NativeWindowSurface {
    var onClose: (@MainActor () -> Void)?
    var prepareCount = 0
    var focusCount = 0
    var draft = ""
    var position = "original"
    func prepareForFirstPresentation() { prepareCount += 1; position = "centered" }
    func bringToFront() { focusCount += 1 }
    func close() { onClose?() }
}

@Test @MainActor func repeatedInspectorClicksFocusWithoutReplacingOrRecentering() {
    var created = 0, configured = 0
    let coordinator = NativeWindowCoordinator<TestToolWindow>()
    func present() -> TestToolWindow {
        coordinator.present(tool: .missionInspector, target: .mission("one"), makeWindow: {
            created += 1; return TestToolWindow()
        }, configure: { _ in configured += 1 })
    }
    let first = present()
    first.position = "moved by user"
    let reopened = present()
    #expect(reopened === first)
    #expect(created == 1)
    #expect(configured == 1)
    #expect(reopened.prepareCount == 1)
    #expect(reopened.focusCount == 2)
    #expect(reopened.position == "moved by user")
    #expect(coordinator.windowCount == 1)
}

@Test(arguments: [NativeWindowTool.missionInspector, .queueInspector])
@MainActor func inspectorRetargetsOneWindowAndClosingReleasesIt(tool: NativeWindowTool) {
    let coordinator = NativeWindowCoordinator<TestToolWindow>()
    var created = 0
    func present(_ id: String) -> TestToolWindow {
        coordinator.present(tool: tool, target: .mission(id), makeWindow: {
            created += 1; return TestToolWindow()
        }, configure: { $0.draft = id })
    }
    let first = present("first")
    let retargeted = present("second")
    #expect(first === retargeted)
    #expect(retargeted.draft == "second")
    #expect(retargeted.prepareCount == 1)
    #expect(retargeted.focusCount == 2)
    #expect(created == 1)
    first.close()
    #expect(coordinator.windowCount == 0)
    let reopened = present("second")
    #expect(reopened !== first)
    #expect(created == 2)
    #expect(reopened.prepareCount == 1)
}

@Test(arguments: [NativeWindowTool.missionEditor, .tasteEditor, .evidenceEditor, .judgmentEditor])
@MainActor func editorClicksPreserveBothTargetsUnsavedDrafts(tool: NativeWindowTool) {
    let coordinator = NativeWindowCoordinator<TestToolWindow>()
    var created = 0
    func present(_ target: NativeWindowTarget) -> TestToolWindow {
        coordinator.present(tool: tool, target: target, makeWindow: {
            created += 1; return TestToolWindow()
        }, configure: { $0.draft = "initial contents" })
    }
    let firstTarget = NativeWindowTarget.checkpoint(mission: "a:b", checkpoint: "c")
    let secondTarget = NativeWindowTarget.checkpoint(mission: "a", checkpoint: "b:c")
    let first = present(firstTarget)
    first.draft = "unfinished first draft"
    let second = present(secondTarget)
    second.draft = "unfinished second draft"
    #expect(first !== second)
    #expect(present(firstTarget) === first)
    #expect(present(secondTarget) === second)
    #expect(first.draft == "unfinished first draft")
    #expect(second.draft == "unfinished second draft")
    #expect(first.focusCount == 2)
    #expect(second.focusCount == 2)
    #expect(created == 2)
    #expect(coordinator.windowCount == 2)
}

@Test(arguments: [NativeWindowTool.decisionQueue, .connections])
@MainActor func managerClicksPreserveExistingFormAndSelection(tool: NativeWindowTool) {
    let coordinator = NativeWindowCoordinator<TestToolWindow>()
    func present() -> TestToolWindow {
        coordinator.present(tool: tool, makeWindow: { TestToolWindow() }, configure: { $0.draft = "empty" })
    }
    let first = present()
    first.draft = "new harness input or selected queue filter"
    #expect(present() === first)
    #expect(first.draft == "new harness input or selected queue filter")
    #expect(first.focusCount == 2)
    #expect(coordinator.windowCount == 1)
}

@Test @MainActor func notchHandoffLastsUntilEveryToolCloses() {
    var begins = 0, hides = 0, restores = 0
    let coordinator = NativeWindowCoordinator<TestToolWindow>(willBegin: { begins += 1 },
                                                              willPresent: { hides += 1 },
                                                              didFinish: { restores += 1 })
    func present(_ tool: NativeWindowTool) -> TestToolWindow {
        coordinator.present(tool: tool, makeWindow: { TestToolWindow() }, configure: { _ in })
    }
    let inspector = present(.missionInspector)
    let form = present(.tasteEditor)
    #expect(present(.missionInspector) === inspector)
    #expect(begins == 1)
    #expect(hides == 3)
    form.close()
    #expect(restores == 0)
    #expect(coordinator.windowCount == 1)
    inspector.close()
    #expect(restores == 1)
    #expect(coordinator.windowCount == 0)
    inspector.close()
    #expect(restores == 1)
    let next = present(.decisionQueue)
    #expect(begins == 2)
    #expect(hides == 4)
    next.close()
    #expect(restores == 2)
}

@Test @MainActor func lateCloseNotificationCannotRemoveReplacementWindow() {
    var restores = 0
    let coordinator = NativeWindowCoordinator<TestToolWindow>(didFinish: { restores += 1 })
    func present() -> TestToolWindow {
        coordinator.present(tool: .decisionQueue, makeWindow: { TestToolWindow() }, configure: { _ in })
    }
    let first = present()
    let delayedClose = first.onClose
    first.close()
    let replacement = present()
    delayedClose?()
    #expect(coordinator.windowCount == 1)
    #expect(restores == 1)
    #expect(present() === replacement)
    replacement.close()
    #expect(coordinator.windowCount == 0)
    #expect(restores == 2)
}
