import AppKit

enum NativeWindowTool: Hashable, Sendable {
    case missionInspector, queueInspector, decisionQueue, connections
    case missionEditor, tasteEditor, evidenceEditor, judgmentEditor

    var preservesDraft: Bool {
        switch self {
        case .missionEditor, .tasteEditor, .evidenceEditor, .judgmentEditor: true
        case .missionInspector, .queueInspector, .decisionQueue, .connections: false
        }
    }
}

enum NativeWindowTarget: Hashable, Sendable {
    case none
    case mission(String)
    case checkpoint(mission: String, checkpoint: String)
    case queueItem(String)
}

@MainActor protocol NativeWindowSurface: AnyObject {
    var onClose: (@MainActor () -> Void)? { get set }
    func prepareForFirstPresentation()
    func bringToFront()
}

/// Inspectors retarget in place. Editors retain a separate draft for each target
/// until the user closes it, so another click cannot erase unsaved input.
@MainActor final class NativeWindowCoordinator<Window: NativeWindowSurface> {
    private struct Key: Hashable {
        let tool: NativeWindowTool
        let draftTarget: NativeWindowTarget
    }
    private struct Entry {
        let window: Window
        var target: NativeWindowTarget
    }
    private var entries: [Key: Entry] = [:]
    private let willBegin: () -> Void
    private let willPresent: () -> Void
    private let didFinish: () -> Void

    init(willBegin: @escaping () -> Void = {}, willPresent: @escaping () -> Void = {},
         didFinish: @escaping () -> Void = {}) {
        self.willBegin = willBegin
        self.willPresent = willPresent
        self.didFinish = didFinish
    }

    var windowCount: Int { entries.count }

    @discardableResult func present(tool: NativeWindowTool, target: NativeWindowTarget = .none,
                                   makeWindow: () -> Window, configure: (Window) -> Void) -> Window {
        let key = Key(tool: tool, draftTarget: tool.preservesDraft ? target : .none)
        if var entry = entries[key] {
            willPresent()
            if entry.target != target {
                configure(entry.window)
                entry.target = target
                entries[key] = entry
            }
            entry.window.bringToFront()
            return entry.window
        }
        if entries.isEmpty { willBegin() }
        willPresent()
        let window = makeWindow()
        configure(window)
        window.onClose = { [weak self, weak window] in
            guard let self, let window, self.entries[key]?.window === window else { return }
            self.entries.removeValue(forKey: key)
            window.onClose = nil
            if self.entries.isEmpty { self.didFinish() }
        }
        entries[key] = Entry(window: window, target: target)
        window.prepareForFirstPresentation()
        window.bringToFront()
        return window
    }
}

@MainActor final class NativeAuxiliaryWindow: NSWindow, NSWindowDelegate, NativeWindowSurface {
    var onClose: (@MainActor () -> Void)?

    init(title: String, width: CGFloat, height: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        delegate = self
    }

    func prepareForFirstPresentation() { center() }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
