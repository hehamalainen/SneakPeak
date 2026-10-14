import AppKit
import Combine
import ImageIO
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
    private var nativeAppearanceItem: NSMenuItem?
    private var otterAppearanceItem: NSMenuItem?
    private var bridge: Process?
    private var nativePanelState: (visible: Bool, level: NSWindow.Level, pinned: Bool)?
    private lazy var nativeWindows = NativeWindowCoordinator<NativeAuxiliaryWindow>(willBegin: { [weak self] in
        guard let self, let panel = self.panel, let store = self.store else { return }
        self.nativePanelState = (panel.isVisible, panel.level, store.pinned)
        store.pinned = true
        store.setExpanded(store.expanded)
        panel.level = .normal
    }, willPresent: { [weak self] in
        self?.panel?.orderOut(nil)
    }, didFinish: { [weak self] in
        guard let self, let state = self.nativePanelState, let panel = self.panel else { return }
        self.nativePanelState = nil
        self.store.pinned = state.pinned
        panel.level = state.level
        if state.visible { panel.orderFrontRegardless() }
    })
    private var setupProcess: Process?
    private var subscription: AnyCancellable?
    private var keyMonitor: Any?
    private let panelGeometry = PanelGeometry()
    private var cameraHeight: CGFloat { panelGeometry.cameraHeight }
    private var screen: NSScreen?
    private var floatingPanelAnchor: NSPoint?
    private var draggingGlance = false
    private var previewOnly = false
    private var renderingHarnesses = false
    private var trackingPreview = ""
    private var playgroundWindow: NSWindow?
    private var companionPanel: NotchPanel?
    private var companionDragOrigin: NSPoint?
    private var playgroundModel: OtterPlaygroundModel?
    private var renderingPlayground = false
    private var renderingCove = false
    private var renderingCoveRaft = false
    private var isolatedCompanionPreview: Bool { CoveLaunchConfiguration.isIsolated(Bundle.main.bundleIdentifier) }
    private var showNotification: Notification.Name {
        Notification.Name(CoveLaunchConfiguration.notificationName(for: Bundle.main.bundleIdentifier))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if Bundle.main.bundleIdentifier == HumanActionSimulation.bundleIdentifier {
            do { try launchHumanActionSimulation() }
            catch { let alert = NSAlert(error: error); alert.runModal(); NSApp.terminate(nil) }
            return
        }
        let args = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        let dataDirectory = isolatedCompanionPreview ? Bundle.main.bundleURL.deletingLastPathComponent() : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SneakPeek")
        let defaultURL = dataDirectory.appendingPathComponent("state.json")
        previewOnly = argument("--render-preview") != nil
        let launch = CoveLaunchConfiguration(bundleIdentifier: Bundle.main.bundleIdentifier,
                                             defaultStateURL: defaultURL, stateOverride: argument("--state"), renderOnly: previewOnly)
        let stateURL = launch.stateURL
        renderingPlayground = args.contains("--render-playground")
        renderingCove = args.contains("--render-cove-only")
        renderingCoveRaft = args.contains("--render-cove-raft")
        renderingHarnesses = args.contains("--render-harnesses")
        trackingPreview = args.contains("--render-inspector") ? "inspector" : args.contains("--render-taste") ? "taste" : args.contains("--render-queue") ? "queue" : ""
        if !previewOnly, let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        store = PeekStore(stateURL: stateURL, demo: args.contains("--demo") || launch.isolated,
                          ownsApprovalSurface: launch.ownsApprovalSurface, automaticReload: launch.reloadsFeed,
                          readInitialFeed: launch.loadsInitialFeed)
        if args.contains("--otter") || (launch.isolated && !args.contains("--native")) { store.setCompanionMode(.otter, persist: launch.persistsAppearance) }
        else if args.contains("--native") { store.setCompanionMode(.native, persist: launch.persistsAppearance) }
        if isolatedCompanionPreview && !previewOnly {
            openPlayground()
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(showPeek), name: showNotification, object: nil)
            if args.contains("--play-all") { playgroundModel?.playAll() }
            return
        }
        if !args.contains("--no-bridge") && launch.startsObserver { startBridge(stateURL: stateURL, project: argument("--project")) }
        screen = chooseScreen()
        panelGeometry.cameraHeight = max(28, screen?.safeAreaInsets.top ?? 0)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isMovable = true; panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        if renderingPlayground || renderingCove || renderingCoveRaft {
            let model = OtterPlaygroundModel(store: store); playgroundModel = model
            if let name = argument("--render-scene"), let scene = OtterDemoScene(rawValue: name) {
                if let from = argument("--render-from-scene"), let initial = OtterDemoScene(rawValue: from) {
                    model.select(initial)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.select(scene) }
                } else { model.select(scene) }
            }
            if renderingCove {
                panel.contentView = NSHostingView(rootView: CoveDemoCharacter(model: model).padding(16))
            } else if renderingCoveRaft {
                panel.contentView = NSHostingView(rootView: CoveRaft(store: store, replay: model.replay)
                    .padding(12).background(Color(red: 0.055, green: 0.06, blue: 0.067)))
            } else {
                panel.contentView = NSHostingView(rootView: OtterPlayground(model: model, showCompanion: {}))
            }
        }
        else if previewOnly && renderingHarnesses { panel.contentView = NSHostingView(rootView: HarnessManager(store: store)) }
        else if previewOnly && trackingPreview == "inspector", let mission = store.mission { panel.contentView = NSHostingView(rootView: MissionInspector(store: store, missionId: mission.id)) }
        else if previewOnly && trackingPreview == "taste", let mission = store.mission { panel.contentView = NSHostingView(rootView: TasteEditor(store: store, mission: mission, checkpoint: nil, close: {})) }
        else if previewOnly && trackingPreview == "queue" { panel.contentView = NSHostingView(rootView: QueueManager(store: store)) }
        else { panel.contentView = NSHostingView(rootView: LivePeekRoot(store: store, geometry: panelGeometry, showRaft: args.contains("--render-raft"))) }
        store.onResize = { [weak self] in self?.position(animated: true); self?.updateAppearanceMenu() }
        store.onPanelDragBegan = { [weak self] in
            guard let self else { return }
            self.draggingGlance = true
            // Stop an in-flight hover expansion before AppKit takes over the drag.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                self.panel.animator().setFrame(self.panel.frame, display: true)
            }
        }
        store.onPanelDragEnded = { [weak self] moved in
            guard let self else { return }
            self.draggingGlance = false
            if moved {
                self.floatingPanelAnchor = NSPoint(x: self.panel.frame.midX, y: self.panel.frame.maxY)
                self.screen = self.panel.screen ?? self.chooseScreen()
                self.panelGeometry.cameraHeight = 28
            }
            self.position(animated: false)
        }
        store.onEdit = { [weak self] mission in self?.edit(mission) }
        store.onManage = { [weak self] in self?.manage() }
        store.onSetup = { [weak self] harness in self?.setup(harness) }
        store.onInspectMission = { [weak self] mission in self?.inspect(mission) }
        store.onTaste = { [weak self] mission, checkpoint in self?.taste(mission, checkpoint: checkpoint) }
        store.onEvidence = { [weak self] mission, checkpoint in self?.evidence(mission, checkpoint: checkpoint) }
        store.onJudgment = { [weak self] mission in self?.judgment(mission) }
        store.onQueue = { [weak self] item in self?.inspectQueue(item) }
        store.onShowQueue = { [weak self] in self?.queueManager() }
        if previewOnly {
            store.pinned = true; store.setExpanded(!args.contains("--render-collapsed")); position(animated: false)
            if let animationPath = argument("--render-gif") {
                if let screen {
                    panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 20,
                                                 y: screen.visibleFrame.minY + 20))
                }
                panel.orderFrontRegardless()
                Task { @MainActor [weak self] in
                    await self?.renderGesture(to: animationPath)
                    self?.render(to: argument("--render-preview")!)
                    NSApp.terminate(nil)
                }
                return
            }
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
            if event.keyCode == 53, self?.panel?.isKeyWindow == true {
                Task { @MainActor in self?.store.pinned = false; self?.store.setExpanded(false) }
                return nil
            }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showPeek), name: showNotification, object: nil)
    }

    private func launchHumanActionSimulation() throws {
        // Distinct bundle, fresh state, no observer, approval surface, external path override,
        // shared notifications, host setup, or live/demo switch.
        NSApp.setActivationPolicy(.regular)
        let state = try HumanActionSimulationFixture.create()
        store = PeekStore(stateURL: state, demo: false, ownsApprovalSurface: false,
                          humanActionSimulation: HumanActionSimulation())
        store.onTaste = { [weak self] mission, checkpoint in self?.taste(mission, checkpoint: checkpoint) }
        store.onQueue = { [weak self] item in self?.inspectQueue(item) }
        store.onShowQueue = { [weak self] in self?.queueManager() }
        let pane = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 730),
                            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        pane.title = "SneakPeek · HUMAN ACTION SIMULATION · no real authentication"
        pane.isReleasedWhenClosed = false
        pane.contentView = NSHostingView(rootView: MissionInspector(store: store, missionId: "simulation-mission"))
        playgroundWindow = pane
        let menu = NSMenu(), app = NSMenuItem(), actions = NSMenu()
        let quit = actions.addItem(withTitle: "Quit Human Action Simulation", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; app.submenu = actions; menu.addItem(app); NSApp.mainMenu = menu
        show(pane)
    }

    private func startBridge(stateURL: URL, project: String?) {
        guard let resources = Bundle.main.resourceURL else { return }
        let script = resources.appendingPathComponent("bridge/peek.py")
        guard FileManager.default.fileExists(atPath: script.path) else { store.message = "Observer missing. Rebuild the app bundle."; return }
        do {
            try PrivateStateFiles.ensureDirectory(stateURL.deletingLastPathComponent())
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
        guard !draggingGlance else { return }
        guard let screen = screen ?? NSScreen.main else { return }
        let width: CGFloat = renderingCove ? 240 : renderingCoveRaft ? 370 : renderingPlayground ? 740 : renderingHarnesses ? 615 : !trackingPreview.isEmpty ? 640 : store.expanded ? 470 : store.companionMode == .otter ? 350 : 320
        let height: CGFloat = renderingCove ? 220 : renderingCoveRaft ? 360 : renderingPlayground ? 790 : renderingHarnesses || !trackingPreview.isEmpty ? 735 : store.expanded ? min(710, screen.frame.height - 80) : cameraHeight + (store.companionMode == .otter ? 52 : 33)
        let rect = PanelPlacement.frame(size: NSSize(width: width, height: height), screen: screen.frame,
                                        visible: screen.visibleFrame, anchor: floatingPanelAnchor)
        if floatingPanelAnchor != nil { floatingPanelAnchor = NSPoint(x: rect.midX, y: rect.maxY) }
        if animated && floatingPanelAnchor == nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(rect, display: true)
            }
        } else { panel.setFrame(rect, display: true) }
    }

    @objc private func displayChanged() {
        guard panel != nil else { return }
        screen = chooseScreen(preferred: screen)
        panelGeometry.cameraHeight = floatingPanelAnchor == nil ? max(28, screen?.safeAreaInsets.top ?? 0) : 28
        // Update geometry in the existing SwiftUI tree; its selected pane and
        // other local state survive display topology changes.
        position(animated: false)
    }

    private func chooseScreen(preferred: NSScreen? = nil) -> NSScreen? {
        func id(_ value: NSScreen?) -> UInt32? {
            (value?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        let displays = NSScreen.screens
        let active = displays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let selected = DisplaySelection.choose(available: displays.compactMap { id($0) }, preferred: id(preferred), active: id(active))
        return displays.first { id($0) == selected } ?? active
    }

    @objc private func moveToCurrentDisplay() {
        guard panel != nil else { return }
        screen = chooseScreen()
        if floatingPanelAnchor != nil, let screen {
            floatingPanelAnchor = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 12)
        }
        panelGeometry.cameraHeight = floatingPanelAnchor == nil ? max(28, screen?.safeAreaInsets.top ?? 0) : 28
        position(animated: false)
        showPeek()
    }

    @objc private func resetPanelPosition() {
        guard panel != nil else { return }
        floatingPanelAnchor = nil
        screen = chooseScreen(preferred: screen)
        panelGeometry.cameraHeight = max(28, screen?.safeAreaInsets.top ?? 0)
        position(animated: false)
        panel.orderFrontRegardless()
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
        let move = menu.addItem(withTitle: "Move to this display", action: #selector(moveToCurrentDisplay), keyEquivalent: ""); move.target = self
        let reset = menu.addItem(withTitle: "Reset position to top", action: #selector(resetPanelPosition), keyEquivalent: ""); reset.target = self
        let demo = menu.addItem(withTitle: "Switch live / example", action: #selector(toggleDemo), keyEquivalent: "d"); demo.target = self
        let harnesses = menu.addItem(withTitle: "Manage harnesses…", action: #selector(manage), keyEquivalent: "h"); harnesses.target = self
        let queue = menu.addItem(withTitle: "Decision queue…", action: #selector(queueManager), keyEquivalent: "j"); queue.target = self
        let appearance = menu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu()
        nativeAppearanceItem = appearanceMenu.addItem(withTitle: "Native", action: #selector(useNativeAppearance), keyEquivalent: "")
        nativeAppearanceItem?.target = self
        otterAppearanceItem = appearanceMenu.addItem(withTitle: "Otter", action: #selector(useOtterAppearance), keyEquivalent: "")
        otterAppearanceItem?.target = self
        appearance.submenu = appearanceMenu
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit SneakPeek", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        statusItem.menu = menu
        updateAppearanceMenu()
    }
    private func updateAppearanceMenu() {
        nativeAppearanceItem?.state = store.companionMode == .native ? .on : .off
        otterAppearanceItem?.state = store.companionMode == .otter ? .on : .off
        statusItem?.button?.image = NSImage(systemSymbolName: store.companionMode == .otter ? "pawprint" : "eye", accessibilityDescription: "SneakPeek")
        updateMenuIcon()
    }
    @objc private func useNativeAppearance() { store.setCompanionMode(.native) }
    @objc private func useOtterAppearance() { store.setCompanionMode(.otter) }
    private func updateMenuIcon() {
        statusItem?.button?.contentTintColor = store.attentionCount > 0 ? NSColor.systemOrange : NSColor.secondaryLabelColor
        statusItem?.button?.toolTip = store.attentionCount > 0 ? "\(store.attentionCount) decisions need you" : "SneakPeek · room to focus"
    }
    @objc private func togglePeek() {
        if panel?.isVisible == false { showPeek(); return }
        store.pinned = !store.expanded; store.setExpanded(!store.expanded)
    }
    @objc private func toggleDemo() { store.toggleMode(); store.pinned = true; store.setExpanded(true) }
    @objc private func showPeek() {
        if isolatedCompanionPreview, playgroundWindow != nil { openPlayground(); return }
        store.pinned = true; store.setExpanded(true); panel.orderFrontRegardless()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openPlayground() {
        companionPanel?.orderOut(nil)
        if let playgroundWindow { show(playgroundWindow); return }
        let model = OtterPlaygroundModel(store: store)
        playgroundModel = model
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 900, height: 900)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(740, available.width - 48), height: min(790, available.height - 48)),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = Bundle.main.bundleIdentifier == CoveLaunchConfiguration.gestureIdentifier ? "Cove · clearer gestures" : Bundle.main.bundleIdentifier == CoveLaunchConfiguration.demoIdentifier ? "Cove · demo" : "Cove · preview"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OtterPlayground(model: model) { [weak self] in self?.showCompanion() })
        playgroundWindow = window
        let mainMenu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        let appQuit = appMenu.addItem(withTitle: "Quit Cove", action: #selector(quit), keyEquivalent: "q")
        appQuit.target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint", accessibilityDescription: "Cove demo")
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open Cove demo", action: #selector(openPlayground), keyEquivalent: ""); open.target = self
        let only = menu.addItem(withTitle: "Cove only", action: #selector(showCompanion), keyEquivalent: ""); only.target = self
        let play = menu.addItem(withTitle: "Play demo", action: #selector(playAllGestures), keyEquivalent: ""); play.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Cove", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        statusItem.menu = menu
        show(window)
    }

    @objc private func playAllGestures() { playgroundModel?.playAll() }

    @objc private func showCompanion() {
        guard let model = playgroundModel else { return }
        if companionPanel == nil {
            let floating = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 264, height: 204),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            floating.isOpaque = false; floating.backgroundColor = .clear; floating.hasShadow = false
            floating.level = .floating; floating.hidesOnDeactivate = false
            floating.isMovableByWindowBackground = true
            floating.isReleasedWhenClosed = false
            floating.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            floating.contentView = NSHostingView(rootView: FloatingOtterPreview(model: model, move: { [weak self] translation, ended in
                self?.moveCompanion(translation, ended: ended)
            }) { [weak self] in self?.openPlayground() })
            if let screen = NSScreen.main {
                floating.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 296, y: screen.visibleFrame.minY + 40))
            }
            companionPanel = floating
        }
        playgroundWindow?.orderOut(nil)
        companionPanel?.orderFrontRegardless()
    }

    private func moveCompanion(_ translation: CGSize, ended: Bool) {
        guard let companionPanel else { return }
        let origin = companionDragOrigin ?? companionPanel.frame.origin
        companionDragOrigin = origin
        var point = NSPoint(x: origin.x + translation.width, y: origin.y - translation.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame
            point.x = min(max(point.x, bounds.minX + 12), bounds.maxX - companionPanel.frame.width - 12)
            point.y = min(max(point.y, bounds.minY + 12), bounds.maxY - companionPanel.frame.height - 12)
        }
        companionPanel.setFrameOrigin(point)
        if ended { companionDragOrigin = nil }
    }

    private func window(title: String, width: CGFloat = 640, height: CGFloat = 735) -> NativeAuxiliaryWindow {
        NativeAuxiliaryWindow(title: title, width: width, height: height)
    }
    private func show(_ window: NSWindow) {
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func presentNative<Content: View>(_ tool: NativeWindowTool, target: NativeWindowTarget = .none,
                                              title: String, width: CGFloat = 640, height: CGFloat = 735,
                                              content: (NativeAuxiliaryWindow) -> Content) {
        nativeWindows.present(tool: tool, target: target,
                              makeWindow: { window(title: title, width: width, height: height) },
                              configure: { pane in
            pane.title = title
            pane.contentView = NSHostingView(rootView: content(pane))
        })
    }
    private func inspect(_ mission: Mission) {
        presentNative(.missionInspector, target: .mission(mission.id), title: "SneakPeek · mission evidence") { _ in
            MissionInspector(store: store, missionId: mission.id)
        }
    }
    private func inspectQueue(_ item: QueueItem) {
        presentNative(.queueInspector, target: .queueItem(item.id), title: "SneakPeek · \(item.kindLabel)", width: 620, height: 565) { _ in
            QueueInspector(store: store, itemId: item.id)
        }
    }
    @objc private func queueManager() {
        presentNative(.decisionQueue, title: "SneakPeek · decision queue", width: 625, height: 720) { _ in
            QueueManager(store: store)
        }
    }
    private func taste(_ mission: Mission, checkpoint: Checkpoint?) {
        let target: NativeWindowTarget = checkpoint.map { .checkpoint(mission: mission.id, checkpoint: $0.id) } ?? .mission(mission.id)
        presentNative(.tasteEditor, target: target, title: "SneakPeek · human Taste", width: 600, height: 740) { pane in
            TasteEditor(store: store, mission: mission, checkpoint: checkpoint) { [weak pane] in pane?.close() }
        }
    }
    private func evidence(_ mission: Mission, checkpoint: Checkpoint) {
        presentNative(.evidenceEditor, target: .checkpoint(mission: mission.id, checkpoint: checkpoint.id),
                      title: "SneakPeek · attach evidence", width: 600, height: 540) { pane in
            EvidenceEditor(store: store, mission: mission, checkpoint: checkpoint) { [weak pane] in pane?.close() }
        }
    }
    private func judgment(_ mission: Mission) {
        presentNative(.judgmentEditor, target: .mission(mission.id), title: "SneakPeek · request human judgment", width: 610, height: 535) { pane in
            JudgmentEditor(store: store, mission: mission) { [weak pane] in pane?.close() }
        }
    }

    @objc private func manage() {
        presentNative(.connections, title: "SneakPeek · harness connections", width: 615, height: 720) { _ in
            HarnessManager(store: store)
        }
    }

    private func setup(_ harness: HarnessInfo) {
        guard setupProcess?.isRunning != true, let resources = Bundle.main.resourceURL else { return }
        let picker = NSOpenPanel()
        picker.title = "Set up \(harness.name) observation"
        picker.message = "Choose the project for your test. SneakPeek adds local observer hooks and preserves the other project hooks. Start or resume the harness after setup."
        picker.prompt = "Set up observer"
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
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
        presentNative(.missionEditor, target: .mission(mission.id), title: "SneakPeek · mission destination", width: 620, height: 710) { pane in
            MissionEditor(store: store, mission: mission) { [weak self, weak pane] updated in
                self?.store.saveMission(updated) { [weak pane] success in if success { pane?.close() } }
            }
        }
    }

    private func render(to path: String) {
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
    private func renderGesture(to path: String) async {
        guard let view = panel.contentView else { return }
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "com.compuserve.gif" as CFString, 70, nil) else { return }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for _ in 0..<70 {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let frame = bitmap.cgImage {
                    CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        CGImageDestinationFinalize(destination)
    }
    func applicationWillTerminate(_ notification: Notification) {
        store?.publishApprovalSurface(live: false, synchronously: true)
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
