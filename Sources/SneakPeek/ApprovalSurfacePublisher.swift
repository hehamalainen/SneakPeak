import Foundation
import SneakPeekCore

struct ApprovalSurfaceValue: Equatable, Sendable {
    let live: Bool
    let statePath: String
    let provider: String
}

// Mutable state belongs exclusively to queue; callers submit immutable values.
final class ApprovalSurfacePublisher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SneakPeek.approval-surface", qos: .utility)
    private let directory: URL
    private let repairDirectory: Bool
    private var lastValue: ApprovalSurfaceValue?
    private var lastWrittenAt = -Double.infinity
    static let heartbeatInterval: Double = 4 // Receiver expires a heartbeat after 10 seconds.

    init(directory: URL) {
        self.directory = directory
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SneakPeek").standardizedFileURL
        repairDirectory = directory.standardizedFileURL == defaultDirectory
    }

    func publish(_ value: ApprovalSurfaceValue, at timestamp: Double, synchronously: Bool) {
        let write: @Sendable () -> Void = { [self] in
            if value == lastValue {
                if !value.live { return }
                if timestamp >= lastWrittenAt && timestamp - lastWrittenAt < Self.heartbeatInterval { return }
            }
            let payload: [String: Any] = ["generatedAt": timestamp, "live": value.live,
                "statePath": value.statePath, "provider": value.provider]
            do {
                let data = try JSONSerialization.data(withJSONObject: payload)
                try PrivateStateFiles.write(data, to: directory.appendingPathComponent("approval-surface.json"),
                                            repairDirectory: repairDirectory)
                lastValue = value; lastWrittenAt = timestamp
            } catch { /* A failed write must not suppress the next heartbeat attempt. */ }
        }
        // Queue order preserves revocation after earlier live writes. Shutdown
        // drains that queue before the process exits.
        if synchronously { queue.sync(execute: write) }
        else { queue.async(execute: write) }
    }
}
