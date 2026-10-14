import CoreGraphics

/// A detached glance keeps its top centre while changing size. Docked glances
/// retain the original notch placement; detached ones stay in usable screen space.
public enum PanelPlacement {
    public static func frame(size: CGSize, screen: CGRect, visible: CGRect, anchor: CGPoint?) -> CGRect {
        guard let anchor else {
            return CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height,
                          width: size.width, height: size.height)
        }
        let bounds = visible.insetBy(dx: 12, dy: 12)
        let width = min(size.width, max(1, bounds.width))
        let height = min(size.height, max(1, bounds.height))
        return CGRect(x: min(max(anchor.x - width / 2, bounds.minX), bounds.maxX - width),
                      y: min(max(anchor.y - height, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }
}
