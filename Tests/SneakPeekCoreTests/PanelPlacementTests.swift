import CoreGraphics
import Testing
import SneakPeekCore

@Test func floatingGlanceKeepsTopCentreWhenExpandedCollapsedOrRestyled() {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let visible = CGRect(x: 0, y: 60, width: 1920, height: 995)
    let anchor = CGPoint(x: 1300, y: 900)
    for size in [CGSize(width: 350, height: 80), CGSize(width: 470, height: 710), CGSize(width: 320, height: 61)] {
        let frame = PanelPlacement.frame(size: size, screen: screen, visible: visible, anchor: anchor)
        #expect(frame.midX == anchor.x)
        #expect(frame.maxY == anchor.y)
        #expect(visible.contains(frame))
    }
}

@Test func offscreenGlanceRecoversOnSmallAndNegativeCoordinateDisplays() {
    for visible in [CGRect(x: -1440, y: 30, width: 1440, height: 850),
                    CGRect(x: 0, y: 0, width: 400, height: 600)] {
        for anchor in [CGPoint(x: 4000, y: 4000), CGPoint(x: -4000, y: -4000)] {
            let frame = PanelPlacement.frame(size: CGSize(width: 470, height: 710), screen: visible,
                                            visible: visible, anchor: anchor)
            #expect(visible.insetBy(dx: 12, dy: 12).contains(frame))
        }
    }
}

@Test func resetPreservesOriginalNotchPlacement() {
    let screen = CGRect(x: -1440, y: -100, width: 1440, height: 900)
    let frame = PanelPlacement.frame(size: CGSize(width: 350, height: 80), screen: screen,
                                    visible: screen.insetBy(dx: 0, dy: 30), anchor: nil)
    #expect(frame.midX == screen.midX)
    #expect(frame.maxY == screen.maxY)
    #expect(frame.size == CGSize(width: 350, height: 80))
}
