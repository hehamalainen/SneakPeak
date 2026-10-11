import Foundation

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
