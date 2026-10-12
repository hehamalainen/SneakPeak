import Foundation

/// Blocking I/O stays off the main actor. Both output pipes are drained while
/// the child runs; stderr is bounded so a failed command cannot grow memory.
final class CommandPipeDrain: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var failure = Data()
    private var inputFailed = false
    private let stdout: Pipe
    private let stderr: Pipe
    private let stdin: Pipe
    private static let limit = 32_768

    init(stdout: Pipe, stderr: Pipe, stdin: Pipe) {
        self.stdout = stdout; self.stderr = stderr; self.stdin = stdin
        for _ in 0..<3 { group.enter() }
    }

    func start(input: Data, process: Process) {
        for (pipe, capture) in [(stdout, false), (stderr, true)] {
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { group.leave() }
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                    if capture {
                        lock.lock()
                        failure.append(chunk.prefix(max(0, Self.limit - failure.count)))
                        lock.unlock()
                    }
                }
                try? pipe.fileHandleForReading.close()
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { try? stdin.fileHandleForWriting.close(); group.leave() }
            do { try stdin.fileHandleForWriting.write(contentsOf: input) }
            catch {
                lock.lock(); inputFailed = true; lock.unlock()
                if process.isRunning { process.terminate() }
            }
        }
    }

    // Called only if Process.run fails, before start has scheduled any readers.
    func abandon() {
        for pipe in [stdout, stderr, stdin] {
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            group.leave()
        }
    }

    func result(exitCode: Int32) -> (Bool, String) {
        group.wait()
        lock.lock(); defer { lock.unlock() }
        let detail = String(decoding: failure, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (exitCode == 0 && !inputFailed,
                detail.isEmpty ? "The record could not be saved" : detail)
    }
}
