import CryptoKit
import Foundation

/// This protocol has no permission action. It can describe only mission judgments.
public enum HumanActionKind: String, Codable, Sendable { case confirmDefinition, reviewEvidence, taste, resolve }

public enum HumanActionError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

public enum HumanCanonical {
    public static func milliseconds(_ seconds: Double) throws -> Int64 {
        guard seconds.isFinite, seconds > 0, seconds < 32_503_680_000 else { throw HumanActionError.invalid("Invalid action time") }
        return Int64(seconds * 1000)
    }
    /// UTF-8 byte lengths, not delimiters or JSON encoder behaviour, separate fields.
    public static func encode(_ fields: [String]) -> Data {
        Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func digest(_ fields: [String]) -> String { digest(encode(fields)) }
    static func number(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
}

public struct HumanAction: Codable, Sendable, Equatable {
    public var version = 1
    public var installationID: String
    public var keyID: String
    public var sequence: Int
    public var previousDigest: String
    public var nonce: String
    public var issuedAtMS: Int64
    public var expiresAtMS: Int64
    public var kind: HumanActionKind
    public var missionID: String
    public var definitionDigest: String
    public var definitionID: String
    public var checkpointID: String
    public var subjectID: String
    public var subjectDigest: String
    public var value: String
    public var note: String
    public var valence: String
    public var strength: String
    public var impact: String

    public init(installationID: String, keyID: String, sequence: Int, previousDigest: String, nonce: String = UUID().uuidString,
                issuedAtMS: Int64, kind: HumanActionKind, missionID: String, definitionDigest: String, definitionID: String = "",
                checkpointID: String = "", subjectID: String = "", subjectDigest: String = "", value: String = "",
                note: String = "", valence: String = "", strength: String = "", impact: String = "") {
        self.installationID = installationID; self.keyID = keyID; self.sequence = sequence; self.previousDigest = previousDigest
        self.nonce = nonce; self.issuedAtMS = issuedAtMS; self.expiresAtMS = issuedAtMS.addingReportingOverflow(120_000).partialValue; self.kind = kind
        self.missionID = missionID; self.definitionDigest = definitionDigest; self.definitionID = definitionID
        self.checkpointID = checkpointID; self.subjectID = subjectID; self.subjectDigest = subjectDigest; self.value = value
        self.note = note; self.valence = valence; self.strength = strength; self.impact = impact
    }

    public var canonical: Data {
        HumanCanonical.encode(["SneakPeek/human-action/P256-SHA256/v1", String(version), installationID, keyID,
            String(sequence), previousDigest, nonce, String(issuedAtMS), String(expiresAtMS), kind.rawValue, missionID,
            definitionDigest, definitionID, checkpointID, subjectID, subjectDigest, value, note, valence, strength, impact])
    }
    public var digest: String { HumanCanonical.digest(canonical) }
    public func validate() throws {
        guard version == 1, UUID(uuidString: installationID) != nil, UUID(uuidString: nonce) != nil,
              sequence > 0, issuedAtMS > 0, issuedAtMS <= Int64.max - 120_000,
              expiresAtMS == issuedAtMS + 120_000, !missionID.isEmpty,
              definitionDigest.count == 64, keyID.count == 64, note.utf8.count <= 10_000,
              canonical.count <= 40_000 else { throw HumanActionError.invalid("Invalid authenticated action") }
        switch kind {
        case .confirmDefinition:
            guard definitionID == nonce, checkpointID.isEmpty, subjectID.isEmpty, subjectDigest.isEmpty,
                  value.isEmpty, note.isEmpty, valence.isEmpty, strength.isEmpty, impact.isEmpty else {
                throw HumanActionError.invalid("Invalid definition confirmation")
            }
        case .reviewEvidence:
            guard UUID(uuidString: definitionID) != nil, !checkpointID.isEmpty, UUID(uuidString: subjectID) != nil,
                  subjectDigest.count == 64, ["accept", "reject"].contains(value), valence.isEmpty,
                  strength.isEmpty, impact.isEmpty else { throw HumanActionError.invalid("Invalid evidence review") }
        case .taste:
            guard UUID(uuidString: definitionID) != nil, subjectID.isEmpty, subjectDigest.isEmpty,
                  ["accept", "reject", "unassessed"].contains(value), ["right", "off", "uncertain"].contains(valence),
                  ["hunch", "conviction"].contains(strength), ["note", "review"].contains(impact),
                  value == "unassessed" || !checkpointID.isEmpty else { throw HumanActionError.invalid("Invalid Taste judgment") }
        case .resolve:
            guard UUID(uuidString: definitionID) != nil, !subjectID.isEmpty, subjectDigest.count == 64,
                  ["taste:", "simulation-taste:", "judgment:"].contains(where: { subjectID.hasPrefix($0) }),
                  ["keep", "change", "dismiss"].contains(value), checkpointID.isEmpty, valence.isEmpty,
                  strength.isEmpty, impact.isEmpty else { throw HumanActionError.invalid("Invalid resolution") }
        }
    }
}

public struct SignedHumanAction: Codable, Sendable, Equatable {
    public var action: HumanAction
    /// Fixed-width r || s, 64 bytes. There is no record-supplied public key.
    public var signature: Data
    public init(action: HumanAction, signature: Data) { self.action = action; self.signature = signature }
    public var digest: String { HumanCanonical.digest([action.digest, signature.base64EncodedString()]) }
}

/// In this prototype the trust anchor and journal live only in a simulation session.
/// Never trust this type merely because it decoded from a file. Production enrollment
/// and protected storage are release prerequisites, not implemented here.
public struct HumanJournal: Codable, Sendable {
    public var installationID: String
    public var publicKey: Data
    public var records: [SignedHumanAction]
    public init(installationID: String, publicKey: Data, records: [SignedHumanAction] = []) {
        self.installationID = installationID; self.publicKey = publicKey; self.records = records
    }
    public var keyID: String { HumanCanonical.digest(publicKey) }
    public func verified(at nowMS: Int64) throws -> [HumanAction] {
        guard nowMS > 0, nowMS < Int64.max - 5_000, UUID(uuidString: installationID) != nil, records.count <= 512 else { throw HumanActionError.invalid("Invalid action journal") }
        let key = try P256.Signing.PublicKey(x963Representation: publicKey)
        var previous = "", nonces = Set<String>(), priorTime: Int64 = 0
        for (index, signed) in records.enumerated() {
            let a = signed.action
            try a.validate()
            guard a.installationID == installationID, a.keyID == keyID, a.sequence == index + 1,
                  a.previousDigest == previous, nonces.insert(a.nonce).inserted,
                  a.issuedAtMS >= priorTime, a.issuedAtMS <= nowMS + 5_000,
                  signed.signature.count == 64,
                  key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signed.signature), for: a.canonical)
            else { throw HumanActionError.invalid("The protected action history failed verification") }
            previous = signed.digest; priorTime = a.issuedAtMS
        }
        return records.map(\.action)
    }
    public mutating func append(_ signed: SignedHumanAction, at nowMS: Int64) throws {
        guard signed.action.issuedAtMS <= nowMS, nowMS <= signed.action.expiresAtMS else {
            throw HumanActionError.invalid("Confirmation expired. Review the action again.")
        }
        var candidate = self; candidate.records.append(signed)
        _ = try candidate.verified(at: nowMS)
        self = candidate
    }
}

public enum HumanContext {
    /// Covers all displayed definition fields and every acceptance rule, including ages.
    /// Feed-provided revision hashes, status, evidence text and source labels are not authoritative.
    public static func definitionDigest(_ mission: Mission) throws -> String {
        guard !mission.id.isEmpty, !mission.title.isEmpty, !mission.goal.isEmpty, mission.checkpoints.count <= 100,
              Set(mission.checkpoints.map(\.id)).count == mission.checkpoints.count,
              mission.checkpoints.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty && [nil, "evidence", "taste"].contains($0.kind) })
        else { throw HumanActionError.invalid("Invalid mission definition") }
        var fields = ["SneakPeek/mission-definition/v1", mission.id, mission.title, mission.goal, mission.owner ?? "You",
                      mission.workspace ?? "", try age(mission.evidenceMaxAgeSeconds), String((mission.constraints ?? []).count)]
        fields += mission.constraints ?? []
        fields += [String(mission.checkpoints.count)]
        for c in mission.checkpoints { // Order is displayed and therefore bound.
            fields += [c.id, c.label, c.kind ?? "evidence", c.required == false ? "optional" : "required", try age(c.maxAgeSeconds ?? mission.evidenceMaxAgeSeconds)]
        }
        let bytes = HumanCanonical.encode(fields)
        guard bytes.count <= 80_000 else { throw HumanActionError.invalid("Mission definition is too large") }
        return HumanCanonical.digest(bytes)
    }
    private static func age(_ value: Double?) throws -> String {
        let value = value ?? 86_400
        guard value.isFinite, value >= 0, value <= 31_536_000 else { throw HumanActionError.invalid("Invalid evidence age limit") }
        return HumanCanonical.number(value)
    }
    /// Compatibility hash for the observer's *content*, recomputed instead of accepting goalRevision.
    public static func sourceGoalRevision(_ mission: Mission) throws -> String {
        let checks: [[String: Any]] = mission.checkpoints.sorted { $0.id < $1.id }.map {
            ["id": $0.id, "label": $0.label, "kind": $0.kind ?? "evidence", "required": $0.required != false]
        }
        let object: [String: Any] = ["goal": mission.goal, "constraints": mission.constraints ?? [],
                                   "workspace": mission.workspace as Any? ?? NSNull(), "checks": checks]
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        var spaced = "", quoted = false, escaped = false
        for ch in String(decoding: json, as: UTF8.self) {
            spaced.append(ch)
            if escaped { escaped = false; continue }
            if ch == "\\" && quoted { escaped = true; continue }
            if ch == "\"" { quoted.toggle() }
            if !quoted && (ch == "," || ch == ":") { spaced.append(" ") }
        }
        return HumanCanonical.digest(Data(spaced.utf8))
    }
    public static func evidenceDigest(_ e: EvidenceRecord) -> String {
        HumanCanonical.digest(["SneakPeek/evidence/v1", e.id, e.missionId, e.checkpointId, e.goalRevision,
            e.summary, e.reference ?? "", e.verdict, HumanCanonical.number(e.observedAt), e.source ?? "", e.actor ?? "",
            e.digest ?? "", e.localFile.map { String($0.size) } ?? "", e.localFile?.modifiedNS ?? ""])
    }
    public static func requestDigest(_ q: QueueItem) -> String {
        HumanCanonical.digest(["SneakPeek/judgment-request/v1", q.id, q.missionId, q.kind, q.title, q.why,
            q.impact, q.recordId ?? "", q.recordGoalRevision ?? ""])
    }
    public static func confirmedDefinition(_ mission: Mission, actions: [HumanAction]) -> HumanAction? {
        guard let digest = try? definitionDigest(mission),
              let last = actions.last(where: { $0.missionID == mission.id && $0.kind == .confirmDefinition }),
              last.definitionDigest == digest else { return nil }
        return last
    }
}
