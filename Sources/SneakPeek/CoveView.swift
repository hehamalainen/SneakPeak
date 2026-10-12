import AppKit
import SneakPeekCore
import SwiftUI

/// The selected Sculptural Cove artwork, with a separately articulated attention paw.
/// The actor supplies the one-shot gesture; this view never starts an idle animation.
struct CoveFigure: View, Animatable {
    let pose: OtterPose
    nonisolated var pawLift: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated var animatableData: Double {
        get { pawLift }
        set { pawLift = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            if pose == .attention {
                attentionFigure(in: geometry.size)
            } else if pose == .unseen {
                unavailableFigure(in: geometry.size)
            } else if let artwork = CoveArtwork.image(named: artworkName) {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                CoveMissingArtwork()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var artworkName: String {
        switch pose {
        case .unseen: "unseen"
        case .resting: CoveArtwork.image(named: "sleeping") != nil ? "sleeping" : "resting"
        case .peeking: CoveArtwork.image(named: "watching") != nil ? "watching" : "attention-body"
        case .attention: "attention-body"
        }
    }

    private var accessibilityDescription: String {
        switch pose {
        case .attention: "Cove has a paw raised. Your attention is needed."
        case .peeking: "Cove is watching."
        case .resting: "Cove is resting."
        case .unseen: "Cove has turned away. Status is unavailable."
        }
    }

    private func unavailableFigure(in size: CGSize) -> some View {
        ZStack(alignment: .topTrailing) {
            if let artwork = CoveArtwork.image(named: "unseen") {
                Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit()
                    .frame(width: size.width * 0.78, height: size.height * 0.78)
                    .frame(width: size.width, height: size.height, alignment: .bottomLeading)
            }
            // A turned back plus loss-of-visibility mark cannot be mistaken for sleep.
            Image(systemName: "eye.slash")
                .font(.system(size: max(10, min(size.width, size.height) * 0.18), weight: .medium))
                .foregroundStyle(Color(red: 0.70, green: 0.73, blue: 0.76))
                .padding(size.height * 0.07)
        }
    }

    @ViewBuilder private func attentionFigure(in size: CGSize) -> some View {
        if let body = CoveArtwork.image(named: "attention-body"),
           let arm = CoveArtwork.image(named: "attention-arm") {
            let canvas = CoveRigGeometry.fittedRect(in: size, aspect: body.size.width / body.size.height)
            let frame = CoveRigGeometry.attentionArm.frame(in: canvas)
            let lift = reduceMotion ? 1 : min(max(pawLift, 0), 1)
            ZStack(alignment: .topLeading) {
                // The torso occludes the soft shoulder root. The actual paw remains
                // outside the body silhouette, and lowers behind it between gestures.
                Image(nsImage: arm)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: frame.width, height: frame.height)
                    .rotationEffect(
                        .degrees(CoveRigGeometry.attentionLoweredAngle * (1 - lift) + 14 * lift),
                        anchor: CoveRigGeometry.attentionArm.anchor
                    )
                    .position(x: frame.midX, y: frame.midY)
                Image(nsImage: body)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: canvas.width, height: canvas.height)
                    .position(x: canvas.midX, y: canvas.midY)
            }
            .frame(width: size.width, height: size.height)
        } else if let artwork = CoveArtwork.image(named: "attention") {
            // An optional complete attention portrait keeps the approved character visible
            // while the rig assets are being packaged, without inventing a substitute animal.
            Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit()
                .frame(width: size.width, height: size.height)
        } else {
            CoveMissingArtwork()
        }
    }
}

/// All attachment coordinates are normalized to the authored image canvas.
/// Keeping them together makes rig tuning independent of the companion's displayed size.
private enum CoveRigGeometry {
    struct Layer {
        var bounds: CGRect
        var anchor: UnitPoint

        func frame(in canvas: CGRect) -> CGRect {
            CGRect(x: canvas.minX + bounds.minX * canvas.width,
                   y: canvas.minY + bounds.minY * canvas.height,
                   width: bounds.width * canvas.width,
                   height: bounds.height * canvas.height)
        }
    }

    // The arm's root is its shoulder, close to the bottom of its transparent crop.
    static let attentionArm = Layer(bounds: CGRect(x: 0.440, y: 0.105, width: 0.300, height: 0.450),
                                    anchor: UnitPoint(x: 0.48, y: 0.90))
    static let attentionLoweredAngle = -82.0

    static func fittedRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }
}

/// Preserve the actual generated pair at its authored paw seam. Unknown members use
/// the withdrawn artwork, and only fresh on-course reports allow a connected pair.
struct CoveRaft: View {
    @ObservedObject var store: PeekStore
    var replay: Int = 0

    var body: some View {
        let members = store.agents.sorted { $0.id < $1.id }
        let groups = stride(from: 0, to: members.count, by: 2).map { index in
            CoveRaftGroup(first: members[index], second: index + 1 < members.count ? members[index + 1] : nil)
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your raft").font(.system(size: 17, weight: .medium, design: .rounded))
                Spacer()
                Text("Course comes from agent reports")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if members.isEmpty {
                Text("No agents in this mission yet.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(groups) { group in
                            CoveRaftGroupView(group: group, store: store, replay: replay)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
            }
            Text(members.count > 2
                 ? "A clear queue and fresh on-course reports link each pair. Pairs do not imply whole-team agreement."
                 : "Fresh reports + a clear queue link paws. Risk opens the link.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Text("A course report is a claim. Inspect the evidence.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct CoveRaftGroup: Identifiable {
    let first: Agent
    let second: Agent?
    var id: String { first.id }
}

/// Rest is an explicitly confirmed condition, never the absence of new events.
/// Kept independent of rendering so its freshness boundaries can be verified.
@MainActor func coveMaySleep(store: PeekStore, first: Agent, second: Agent?) -> Bool {
    guard let second else { return false }
    let feedAge = store.now - store.feed.generatedAt
    return store.feed.generatedAt > 0 && feedAge >= -1 && feedAge <= 10
        && !store.disconnected && store.otterStatus.pose != .unseen && store.otterStatus.tone != .attention
        && store.feed.queue?.isEmpty == true && store.attentionCount == 0
        && raftCourse(first, store: store) == .onCourse
        && raftCourse(second, store: store) == .onCourse
}

private struct CoveRaftGroupView: View {
    let group: CoveRaftGroup
    @ObservedObject var store: PeekStore
    let replay: Int

    var body: some View {
        let firstCourse = raftCourse(group.first, store: store)
        let secondCourse = group.second.map { raftCourse($0, store: store) }
        let maySleep = coveMaySleep(store: store, first: group.first, second: group.second)
        let awakePose: OtterPose = store.otterStatus.pose == .attention ? .attention : .peeking
        VStack(spacing: 6) {
            if let secondCourse {
                CoveRaftPairPicture(left: firstCourse, right: secondCourse,
                                    maySleep: maySleep, awakePose: awakePose, replay: replay)
                    .frame(width: 270, height: 164)
            } else {
                CoveFigure(pose: firstCourse == .unknown ? .unseen : awakePose)
                    .frame(width: 150, height: 164)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 0) {
                memberLabel(group.first, course: firstCourse)
                if let second = group.second, let secondCourse {
                    memberLabel(second, course: secondCourse)
                }
            }
            if group.second != nil {
                Text(maySleep
                     ? "Holding paws · reported on course"
                     : store.otterStatus.pose == .attention ? "Awake · your attention is needed" : "Paw link open")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
            } else {
                Text("One agent · no paw link")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .frame(width: group.second == nil ? 150 : 270)
    }

    private func memberLabel(_ agent: Agent, course: RaftCourse) -> some View {
        let label = course == .onCourse ? "On course · reported" : course == .atRisk ? "At risk · reported" : "Course unavailable"
        return Button { store.selectedAgentId = agent.id } label: {
            VStack(spacing: 4) {
                Text(agent.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(label).font(.system(size: 8))
                    .foregroundStyle(course == .atRisk ? Color.orange : Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agent.name). \(label)")
        .accessibilityHint("Shows this agent’s details")
    }
}

private struct CoveRaftPairPicture: View {
    let left: RaftCourse
    let right: RaftCourse
    let maySleep: Bool
    let awakePose: OtterPose
    let replay: Int

    var body: some View {
        if left != .unknown && right != .unknown {
            CovePairActor(linked: maySleep, drifting: right == .atRisk || left == .atRisk,
                          riskOnLeft: left == .atRisk, replay: replay)
        } else {
            HStack(spacing: 16) {
                CoveFigure(pose: left == .unknown ? .unseen : awakePose)
                CoveFigure(pose: right == .unknown ? .unseen : awakePose)
            }
        }
    }
}

/// The same physical pair stays visible through release and reconnection. We never
/// replace a separating raft with unrelated portraits midway through the gesture.
struct CovePairActor: View {
    let linked: Bool
    var drifting = false
    var riskOnLeft = false
    var replay = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opening = 0.0

    var body: some View {
        GeometryReader { geometry in
            if let sleeping = CoveArtwork.raftHalves(named: "raft"),
               let awake = CoveArtwork.raftHalves(named: "raft-open") {
                let fit = CoveRigGeometry.fittedRect(in: geometry.size, aspect: sleeping.aspect)
                let canvas = CGRect(x: fit.minX + fit.width * 0.12, y: fit.minY + fit.height * 0.10,
                                    width: fit.width * 0.76, height: fit.height * 0.80)
                ZStack(alignment: .topLeading) {
                    member(sleeping.left, awake: awake.left, side: -1, canvas: canvas)
                    member(sleeping.right, awake: awake.right, side: 1, canvas: canvas)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                CoveMissingArtwork()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(linked ? "Two otters holding paws. Clear queue and fresh on-course reports."
                            : drifting ? "The paws release and one otter drifts away. A course concern was reported."
                            : "Two awake otters with their paw link open.")
        .task(id: "\(linked)|\(drifting)|\(riskOnLeft)|\(replay)|\(reduceMotion)") {
            let target = linked ? 0.0 : drifting ? 1.0 : 0.6
            guard !reduceMotion else { opening = target; return }
            // Start each deliberate replay with enough distance to see the paw seam
            // closing, or with connected paws to see a release clearly.
            var reset = Transaction(); reset.disablesAnimations = true
            withTransaction(reset) { opening = linked ? 0.8 : 0 }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 1.3)) { opening = target }
        }
    }

    private func member(_ asleep: NSImage, awake: NSImage, side: CGFloat, canvas: CGRect) -> some View {
        let risk = drifting && (riskOnLeft ? side < 0 : side > 0)
        let width = canvas.width / 2
        let distance = canvas.width * 0.13 * opening * (risk ? 1.4 : 0.55)
        let tilt = risk ? Double(side) * 15 * opening : 0
        return ZStack {
            Image(nsImage: asleep).resizable().interpolation(.high).scaledToFit()
                .opacity(linked && opening < 0.16 ? 1 : 0)
            Image(nsImage: awake).resizable().interpolation(.high).scaledToFit()
                .offset(x: -side * canvas.width * 0.024 * (1 - opening))
                .opacity(linked && opening < 0.16 ? 0 : 1)
        }
        .frame(width: width, height: canvas.height)
        .rotationEffect(.degrees(tilt), anchor: UnitPoint(x: side < 0 ? 1 : 0, y: 0.47))
        .position(x: canvas.minX + width * (side < 0 ? 0.5 : 1.5) + side * distance,
                  y: canvas.midY + (risk ? canvas.height * 0.10 * opening : 0))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: linked)
    }
}

@MainActor private enum CoveArtwork {
    struct Split {
        let left: NSImage
        let right: NSImage
        let aspect: CGFloat
    }

    private static var images: [String: NSImage] = [:]
    private static var missing = Set<String>()
    private static var cachedRaftSplits: [String: Split] = [:]
    private static let bundles: [Bundle] = {
        if let packaged = Bundle.main.resourceURL.flatMap({
            Bundle(url: $0.appendingPathComponent("SneakPeek_SneakPeek.bundle"))
        }) {
            return [packaged]
        }
        return [Bundle.module]
    }()

    static func image(named name: String) -> NSImage? {
        if let cached = images[name] { return cached }
        guard !missing.contains(name) else { return nil }
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Otter/Cove"),
               let image = NSImage(contentsOf: url) {
                images[name] = image
                return image
            }
        }
        missing.insert(name)
        return nil
    }

    static func raftHalves(named name: String) -> Split? {
        if let cached = cachedRaftSplits[name] { return cached }
        guard let image = image(named: name),
              let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let middle = pixels.width / 2
        guard middle > 0,
              let left = pixels.cropping(to: CGRect(x: 0, y: 0, width: middle, height: pixels.height)),
              let right = pixels.cropping(to: CGRect(x: middle, y: 0, width: pixels.width - middle, height: pixels.height)) else { return nil }
        let split = Split(left: NSImage(cgImage: left, size: NSSize(width: CGFloat(left.width), height: CGFloat(left.height))),
                          right: NSImage(cgImage: right, size: NSSize(width: CGFloat(right.width), height: CGFloat(right.height))),
                          aspect: CGFloat(pixels.width) / CGFloat(pixels.height))
        cachedRaftSplits[name] = split
        return split
    }
}

private struct CoveMissingArtwork: View {
    var body: some View {
        Text("Cove artwork unavailable")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
