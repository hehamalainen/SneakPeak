import AppKit
import SwiftUI

enum CompanionMode: String, Codable { case native, otter }
struct CompanionSettings: Codable { var mode: CompanionMode }
enum OtterPose: String { case peeking, attention, resting, unseen }
enum OtterTone { case muted, attention, working, resting }

struct OtterStatus {
    let pose: OtterPose
    let title: String
    let detail: String
    let tone: OtterTone

    var color: Color {
        switch tone {
        case .muted: Color(red: 0.56, green: 0.58, blue: 0.60)
        case .attention: Color(red: 0.94, green: 0.73, blue: 0.43)
        case .working: Color(red: 0.52, green: 0.68, blue: 0.94)
        case .resting: Color(red: 0.76, green: 0.88, blue: 0.79)
        }
    }
}

struct OtterGlance: View {
    @ObservedObject var store: PeekStore

    var body: some View {
        let status = store.otterStatus
        Button {
            store.pinned = true
            store.setExpanded(true)
        } label: {
            HStack(spacing: 13) {
                OtterActor(store: store)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Circle().fill(status.color).frame(width: 5, height: 5)
                        Text(store.showingDemo ? "EXAMPLE · OTTER" : store.hasUnsignedReviews ? "SNEAKPEEK · UNSIGNED REVIEWS" : "SNEAKPEEK · OTTER")
                            .font(.system(size: 7, weight: .semibold)).tracking(1).foregroundStyle(.gray)
                    }
                    Text(status.title).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(status.color)
                    Text(status.detail).font(.system(size: 9)).foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.gray)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open your missions and decision queue")
        .accessibilityLabel("\(store.showingDemo ? "Example. " : "")\(status.title). \(status.detail)")
        .accessibilityHint("Opens the mission panel")
    }
}

struct OtterActor: View {
    @ObservedObject var store: PeekStore
    var replay: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pawLift = 1.0
    @State private var settled = true

    var body: some View {
        let status = store.otterStatus
        CoveFigure(pose: status.pose, pawLift: pawLift)
            .opacity(status.tone == .muted ? 0.82 : 1)
            .offset(y: settled || reduceMotion ? 0 : status.pose == .unseen ? -24 : 18)
            .rotationEffect(.degrees(settled || reduceMotion || status.pose != .resting ? 0 : -24))
            .id(status.pose)
            .transition(reduceMotion ? .identity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .bottom).combined(with: .opacity)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: status.pose)
            .task(id: "\(status.pose.rawValue)|\(store.otterAttentionSignature)|\(replay)|\(reduceMotion)") {
            guard !reduceMotion else { pawLift = 1; settled = true; return }
            settled = false
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.85)) { settled = true }
            guard status.pose == .attention, !reduceMotion else { pawLift = 1; return }
            // Rise clearly above the face, wave twice across a wide arc, then
            // hold the paw up until this particular decision is acknowledged.
            pawLift = 0
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { pawLift = 1 }
            do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
            for _ in 0..<2 {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.28)) { pawLift = 0.55 }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.28)) { pawLift = 1 }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
        }
    }
}
