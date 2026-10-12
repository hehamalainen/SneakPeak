import CryptoKit
import Foundation

/// Deliberately ephemeral and explicitly simulated. This is not a production signer.
/// Only the separate simulation application creates this object. No keys or receipts
/// are imported from state files, persisted, enrolled, or shared with the normal app.
@MainActor public final class HumanActionSimulation {
    public static let bundleIdentifier = "local.sneakpeek.human-actions.simulation"
    private let key = P256.Signing.PrivateKey()
    public private(set) var journal: HumanJournal
    private var pending: HumanAction?

    public init() {
        journal = HumanJournal(installationID: UUID().uuidString, publicKey: key.publicKey.x963Representation)
    }
    public func prepare(kind: HumanActionKind, mission: Mission, now: Double, checkpointID: String = "",
                        subjectID: String = "", subjectDigest: String = "", value: String = "", note: String = "",
                        valence: String = "", strength: String = "", impact: String = "") throws -> HumanAction {
        let digest = try HumanContext.definitionDigest(mission)
        let nowMS = try HumanCanonical.milliseconds(now)
        let actions = try journal.verified(at: nowMS)
        let definition = HumanContext.confirmedDefinition(mission, actions: actions)
        guard kind == .confirmDefinition || definition != nil else { throw HumanActionError.invalid("Confirm the mission definition in this simulation first.") }
        if kind == .reviewEvidence {
            guard let check = mission.checkpoints.first(where: { $0.id == checkpointID }), check.kind != "taste",
                  let evidence = check.records?.first(where: { $0.id == subjectID }),
                  HumanContext.evidenceDigest(evidence) == subjectDigest else { throw HumanActionError.invalid("Evidence context changed") }
            try HumanArtifact.validate(evidence, mission: mission, check: check, now: now)
        }
        if kind == .taste && (!checkpointID.isEmpty || value != "unassessed") {
            guard mission.checkpoints.contains(where: { $0.id == checkpointID && $0.kind == "taste" }) else {
                throw HumanActionError.invalid("Taste judgments apply only to Taste checks.")
            }
        }
        var action = HumanAction(installationID: journal.installationID, keyID: journal.keyID,
            sequence: journal.records.count + 1, previousDigest: journal.records.last?.digest ?? "", issuedAtMS: nowMS,
            kind: kind, missionID: mission.id, definitionDigest: digest, definitionID: definition?.nonce ?? "",
            checkpointID: checkpointID, subjectID: subjectID, subjectDigest: subjectDigest, value: value, note: note,
            valence: valence, strength: strength, impact: impact)
        if kind == .confirmDefinition { action.definitionID = action.nonce }
        try action.validate()
        pending = action
        return action
    }
    /// A first UI click merely prepares an action. The separate mock biometry result
    /// must name that exact action; cancellation/expiry/context changes issue no receipt.
    public func finish(_ action: HumanAction, mockBiometrySucceeded: Bool, currentMission: Mission, now: Double) throws {
        guard pending == action else { throw HumanActionError.invalid("No matching pending simulation action") }
        pending = nil
        guard mockBiometrySucceeded else { throw HumanActionError.invalid("Simulated Touch ID cancelled. Nothing was signed.") }
        guard currentMission.id == action.missionID,
              try HumanContext.definitionDigest(currentMission) == action.definitionDigest else {
            throw HumanActionError.invalid("Mission changed during confirmation. Review it again.")
        }
        if action.kind == .reviewEvidence {
            guard let check = currentMission.checkpoints.first(where: { $0.id == action.checkpointID }),
                  let evidence = check.records?.first(where: { $0.id == action.subjectID }),
                  HumanContext.evidenceDigest(evidence) == action.subjectDigest else { throw HumanActionError.invalid("Evidence changed during confirmation") }
            try HumanArtifact.validate(evidence, mission: currentMission, check: check, now: now)
        }
        let signature = try key.signature(for: action.canonical).rawRepresentation
        try journal.append(SignedHumanAction(action: action, signature: signature), at: HumanCanonical.milliseconds(now))
    }
}
