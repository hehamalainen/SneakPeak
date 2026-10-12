import Foundation

/// The presentation app has a distinct identity and never participates in live work.
struct CoveLaunchConfiguration {
    static let previewIdentifier = "local.sneakpeek.otter.preview"
    static let demoIdentifier = "local.sneakpeek.cove.demo"
    static let gestureIdentifier = "local.sneakpeek.cove.gestures"

    let isolated: Bool
    let renderOnly: Bool
    let stateURL: URL

    static func isIsolated(_ identifier: String?) -> Bool {
        identifier == previewIdentifier || identifier == demoIdentifier || identifier == gestureIdentifier
    }

    static func notificationName(for identifier: String?) -> String {
        isIsolated(identifier) ? "\(identifier!).show" : "local.sneakpeek.show"
    }

    init(bundleIdentifier: String?, defaultStateURL: URL, stateOverride: String?, renderOnly: Bool) {
        isolated = Self.isIsolated(bundleIdentifier)
        self.renderOnly = renderOnly
        stateURL = isolated && !renderOnly ? defaultStateURL
            : stateOverride.map { URL(fileURLWithPath: $0) } ?? defaultStateURL
    }

    var startsObserver: Bool { !isolated && !renderOnly }
    var ownsApprovalSurface: Bool { !isolated && !renderOnly }
    var reloadsFeed: Bool { !isolated && !renderOnly }
    var loadsInitialFeed: Bool { !isolated || renderOnly }
    var persistsAppearance: Bool { !isolated && !renderOnly }
}
