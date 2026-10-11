import CryptoKit
import Darwin
import Foundation

public enum MissionSaveError: Error { case conflict, invalidChecks, evidenceChanged, lockFailed }

/// Native and Python checkpoint writers use the same per-mission flock file.
public enum MissionPersistence {
    public static func fileName(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    private static func locked<T>(_ id: String, directory: URL, action: (URL) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(fileName(id))
        let lock = path.deletingPathExtension().appendingPathExtension("lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw MissionSaveError.lockFailed }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw MissionSaveError.lockFailed }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try action(path)
    }
    private static func read(_ path: URL, fallback: Mission) throws -> Mission {
        guard FileManager.default.fileExists(atPath: path.path) else { return fallback }
        let value = try JSONDecoder().decode(Mission.self, from: Data(contentsOf: path))
        guard value.id == fallback.id else { throw MissionSaveError.conflict }
        return value
    }
    private static func write(_ value: Mission, path: URL) throws {
        try JSONEncoder().encode(value).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    public static func save(_ edited: Mission, base: Mission, directory: URL) throws {
        try locked(edited.id, directory: directory) { path in
            let current = try read(path, fallback: base)
            guard base.id == edited.id, (base.definitionRevision ?? 0) == (current.definitionRevision ?? 0) else { throw MissionSaveError.conflict }
            guard base.title == current.title, base.goal == current.goal,
                  base.checkpoints.map({ [$0.id, $0.label] }) == current.checkpoints.map({ [$0.id, $0.label] }) else { throw MissionSaveError.conflict }
            let checks = edited.checkpoints
            guard Set(checks.map(\.id)).count == checks.count,
                  checks.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw MissionSaveError.invalidChecks }
            var merged = edited
            merged.checkpoints = checks.map { check in
                if edited.goal == current.goal, let latest = current.checkpoints.first(where: { $0.id == check.id && $0.label == check.label }) {
                    return latest // Preserve reports/verification that arrived after the editor opened.
                }
                return Checkpoint(id: check.id, label: check.label, status: "pending", evidence: "Awaiting evidence", source: "human")
            }
            merged.definitionRevision = (current.definitionRevision ?? 0) + 1
            try write(merged, path: path)
        }
    }
    public static func verify(_ check: Checkpoint, base: Mission, directory: URL) throws {
        try locked(base.id, directory: directory) { path in
            var current = try read(path, fallback: base)
            guard current.goal == base.goal,
                  let index = current.checkpoints.firstIndex(where: { $0.id == check.id }),
                  current.checkpoints[index].label == check.label,
                  current.checkpoints[index].evidence == check.evidence,
                  current.checkpoints[index].source == check.source,
                  current.checkpoints[index].status == check.status,
                  !check.evidence.isEmpty else { throw MissionSaveError.evidenceChanged }
            current.checkpoints[index].status = "verified"
            current.checkpoints[index].source = "human"
            try write(current, path: path)
        }
    }
}

public enum MissionEditing {
    /// Labels may repeat. Identity always belongs to the row, never its label.
    public static func nonblank(_ checks: [Checkpoint]) -> [Checkpoint] {
        checks.compactMap { check in
            var result = check
            result.label = check.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.label.isEmpty ? nil : result
        }
    }
}
