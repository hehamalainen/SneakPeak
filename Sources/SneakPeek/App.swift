import AppKit
import Combine
import SneakPeekCore
import SwiftUI

@MainActor final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel!
    private var store: PeekStore!
    private var statusItem: NSStatusItem!
    private var bridge: Process?
    private var editor: NSWindow?
    private var manager: NSWindow?
    private var setupProcess: Process?
    private var subscription: AnyCancellable?
    private var keyMonitor: Any?
    private var cameraHeight: CGFloat = 30
    private var screen: NSScreen?
    private var previewOnly = false
    private var renderingHarnesses = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let args = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let dataDirectory = bundleParent.lastPathComponent == "dist"
            ? bundleParent.deletingLastPathComponent().appendingPathComponent("runtime")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SneakPeek")
        let defaultURL = dataDirectory.appendingPathComponent("state.json")
        let stateURL = argument("--state").map { URL(fileURLWithPath: $0) } ?? defaultURL
        store = PeekStore(stateURL: stateURL, demo: args.contains("--demo"))
        previewOnly = argument("--render-preview") != nil
        renderingHarnesses = args.contains("--render-harnesses")
        if !previewOnly, let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.sneakpeek.show"), object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        if !args.contains("--no-bridge") && !previewOnly { startBridge(stateURL: stateURL, project: argument("--project")) }
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        cameraHeight = max(28, screen?.safeAreaInsets.top ?? 0)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isMovable = false; panel.isReleasedWhenClosed = false
        if previewOnly && renderingHarnesses { panel.contentView = NSHostingView(rootView: HarnessManager(store: store)) }
        else { panel.contentView = NSHostingView(rootView: PeekView(store: store, cameraHeight: cameraHeight)) }
        store.onResize = { [weak self] in self?.position(animated: true) }
        store.onEdit = { [weak self] mission in self?.edit(mission) }
        store.onManage = { [weak self] in self?.manage() }
        store.onSetup = { [weak self] harness in self?.setup(harness) }
        if previewOnly {
            store.pinned = true; store.setExpanded(true); position(animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.render(to: argument("--render-preview")!)
                NSApp.terminate(nil)
            }
            return
        }
        if args.contains("--expanded") { store.pinned = true; store.setExpanded(true) }
        position(animated: false); panel.orderFrontRegardless()
        makeMenu()
        subscription = store.$feed.sink { [weak self] _ in
            Task { @MainActor in self?.updateMenuIcon() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.store.pinned = false; self?.store.setExpanded(false) }
                return nil
            }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showPeek), name: Notification.Name("local.sneakpeek.show"), object: nil)
    }

    private func startBridge(stateURL: URL, project: String?) {
        guard let resources = Bundle.main.resourceURL else { return }
        let script = resources.appendingPathComponent("bridge/peek.py")
        guard FileManager.default.fileExists(atPath: script.path) else { store.message = "Observer missing. Rebuild the app bundle."; return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path, "watch", "--state", stateURL.path, "--owner-pid", String(ProcessInfo.processInfo.processIdentifier)]
            if let project { process.arguments! += ["--project", project] }
            process.standardOutput = FileHandle.nullDevice
            let logURL = stateURL.deletingLastPathComponent().appendingPathComponent("observer.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: logURL)
            try process.run(); bridge = process
        } catch { store.message = "Observer could not start: \(error.localizedDescription)" }
    }

    private func position(animated: Bool) {
        guard let screen = screen ?? NSScreen.main else { return }
        let width: CGFloat = renderingHarnesses ? 615 : store.expanded ? 470 : 320
        let height: CGFloat = renderingHarnesses ? 720 : store.expanded ? min(710, screen.frame.height - 80) : cameraHeight + 33
        let rect = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(rect, display: true)
            }
        } else { panel.setFrame(rect, display: true) }
    }

    @objc private func displayChanged() {
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        cameraHeight = max(28, screen?.safeAreaInsets.top ?? 0)
        panel.contentView = NSHostingView(rootView: PeekView(store: store, cameraHeight: cameraHeight))
        position(animated: false)
    }

    private func makeMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        let mainQuit = applicationMenu.addItem(withTitle: "Quit SneakPeek", action: #selector(quit), keyEquivalent: "q")
        mainQuit.target = self
        applicationItem.submenu = applicationMenu
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "SneakPeek")
        let menu = NSMenu()
        menu.addItem(withTitle: "SneakPeek · mission glance", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let peek = menu.addItem(withTitle: "Peek at agents", action: #selector(togglePeek), keyEquivalent: "p"); peek.target = self
        let demo = menu.addItem(withTitle: "Switch live / example", action: #selector(toggleDemo), keyEquivalent: "d"); demo.target = self
        let harnesses = menu.addItem(withTitle: "Manage harnesses…", action: #selector(manage), keyEquivalent: "h"); harnesses.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit SneakPeek", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        statusItem.menu = menu
    }
    private func updateMenuIcon() {
        statusItem?.button?.contentTintColor = store.attentionCount > 0 ? NSColor.systemOrange : NSColor.secondaryLabelColor
        statusItem?.button?.toolTip = store.attentionCount > 0 ? "\(store.attentionCount) agents need you" : "SneakPeek · room to focus"
    }
    @objc private func togglePeek() { store.pinned = !store.expanded; store.setExpanded(!store.expanded) }
    @objc private func toggleDemo() { store.toggleMode(); store.pinned = true; store.setExpanded(true) }
    @objc private func showPeek() { store.pinned = true; store.setExpanded(true); panel.orderFrontRegardless() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func manage() {
        store.pinned = true
        if let manager, manager.isVisible { manager.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 615, height: 720), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SneakPeek · harness connections"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HarnessManager(store: store))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        manager = window
    }

    private func setup(_ harness: HarnessInfo) {
        guard setupProcess?.isRunning != true, let resources = Bundle.main.resourceURL else { return }
        let picker = NSOpenPanel()
        picker.title = "Set up \(harness.name) observation"
        picker.message = "Choose the project for your test. SneakPeek adds local observer hooks and preserves the other project hooks. Start or resume the harness after setup."
        picker.prompt = "Set up observer"
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let project = picker.url else { return }
        do {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", resources.appendingPathComponent("bridge/connect.py").path, "--provider", harness.id, "--project", project.path, "--state", store.stateURL.path]
            process.standardOutput = output; process.standardError = errors
            process.terminationHandler = { [weak self] task in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                let result = task.terminationStatus == 0 ? "\(harness.name) observer hooks configured · start or resume a session in the selected project" : (String(data: errorData, encoding: .utf8) ?? "Hook setup failed")
                Task { @MainActor [weak self] in self?.store.message = result }
                _ = data
            }
            store.message = "Preparing \(harness.name) project observation…"
            setupProcess = process; try process.run()
        } catch { store.message = "Setup could not start: \(error.localizedDescription)" }
    }

    private func edit(_ mission: Mission) {
        store.pinned = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 536, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SneakPeek · mission destination"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MissionEditor(mission: mission) { [weak self, weak window] updated in
            self?.store.saveMission(updated); window?.close()
        })
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        editor = window
    }

    private func render(to path: String) {
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let bridge, bridge.isRunning { bridge.terminate() }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

@main enum SneakPeekApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
