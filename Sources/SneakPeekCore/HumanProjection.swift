import CryptoKit
import Darwin
import Foundation

public enum HumanArtifact {
    /// Bounded descriptor-based hashing prevents stat-only acceptance and rejects final symlinks,
    /// special files, replacement during reads and mutable remote references.
    public static func validate(_ evidence: EvidenceRecord, mission: Mission, check: Checkpoint, now: Double) throws {
        guard UUID(uuidString: evidence.id) != nil, evidence.missionId == mission.id, evidence.checkpointId == check.id,
              evidence.goalRevision == (try HumanContext.sourceGoalRevision(mission)),
              evidence.observedAt.isFinite, evidence.observedAt > 0, evidence.observedAt <= now + 5,
              ["supports", "contradicts", "unknown"].contains(evidence.verdict), !evidence.summary.isEmpty,
              let reference = evidence.reference, case .reveal(let url) = EvidenceReference(reference),
              let snapshot = evidence.localFile, let expected = evidence.digest, expected.count == 64 else {
            throw HumanActionError.invalid("A current local artifact with a content digest is required for authenticated review.")
        }
        let maxAge = check.maxAgeSeconds ?? mission.evidenceMaxAgeSeconds ?? 86_400
        guard maxAge.isFinite, maxAge >= 0, maxAge == 0 || now - evidence.observedAt <= maxAge else {
            throw HumanActionError.invalid("Evidence is stale. Attach a fresh record.")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw HumanActionError.invalid("The local artifact cannot be inspected safely.") }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= 16 * 1024 * 1024,
              before.st_size == snapshot.size,
              before.st_mtimespec.tv_sec >= 0, before.st_mtimespec.tv_sec < 9_223_372_034,
              String(Int64(before.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(before.st_mtimespec.tv_nsec)) == snapshot.modifiedNS else {
            throw HumanActionError.invalid("The artifact changed, is not a regular file, or exceeds the 16 MiB inspection limit.")
        }
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1024), total = 0
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw HumanActionError.invalid("The artifact could not be read.") }
            if count == 0 { break }
            total += count
            guard total <= 16 * 1024 * 1024 else { throw HumanActionError.invalid("The artifact grew during inspection.") }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, total == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw HumanActionError.invalid("The artifact content changed. Attach a fresh record.")
        }
        // Ensure the pathname still resolves to the descriptor we read.
        var named = stat()
        guard lstat(url.path, &named) == 0, named.st_dev == after.st_dev, named.st_ino == after.st_ino,
              named.st_mode & S_IFMT == S_IFREG else { throw HumanActionError.invalid("The artifact was replaced during inspection.") }
    }
}

public enum HumanProjection {
    /// The prototype accepts only an explicitly supplied, in-memory simulation trust anchor.
    /// Normal app calls pass nil. No feed field or adjacent key file enables signing.
    public static func project(_ input: Feed, simulationJournal: HumanJournal?, now: Double) -> Feed {
        var feed = input
        let actions = (try? simulationJournal?.verified(at: HumanCanonical.milliseconds(now))) ?? []
        let duplicateMissions = Set(Dictionary(grouping: input.missions, by: \.id).filter { $0.value.count != 1 }.keys)
        let generatedTasteIDs = Set(actions.filter { $0.kind == .taste }.map { "simulation-taste:" + $0.nonce })
        var queue = (input.queue ?? []).filter { !($0.kind == "taste" && generatedTasteIDs.contains($0.id)) }
        for mi in feed.missions.indices {
            let original = feed.missions[mi]
            var mission = original
            let confirmation = duplicateMissions.contains(mission.id) ? nil : HumanContext.confirmedDefinition(mission, actions: actions)
            let applicable = actions.filter { a in
                confirmation.map { a.missionID == mission.id && a.definitionDigest == $0.definitionDigest &&
                    a.definitionID == $0.nonce && a.sequence > $0.sequence } ?? false
            }
            mission.humanAuthentication = confirmation == nil ? "No authenticated definition" : "Definition confirmed · SIMULATION"
            mission.hasUnsignedHumanClaims = original.checkpoints.contains { $0.status == "verified" || $0.records?.contains { ["accepted", "rejected"].contains($0.state) } == true }
                || original.tasteNotes?.isEmpty == false || (original.assessment?.verifiedCount ?? 0) > 0
            let allRecords = mission.checkpoints.flatMap { $0.records ?? [] }
            let duplicates = Set(Dictionary(grouping: allRecords, by: \.id).filter { $0.value.count != 1 }.keys)
            var notes = (mission.tasteNotes ?? []).map { note in
                var n = note
                n.authentication = "unsigned claim"; n.reportedAcceptance = note.acceptance
                n.acceptance = "unassessed"; n.resolved = false; n.resolution = nil
                n.contextStale = note.goalRevision != (try? HumanContext.sourceGoalRevision(mission))
                return n
            }
            for a in applicable where a.kind == .taste {
                var note = TasteSignal(id: a.nonce, missionId: mission.id, goalRevision: (try? HumanContext.sourceGoalRevision(mission)) ?? "",
                    checkpointId: a.checkpointID.isEmpty ? nil : a.checkpointID, valence: a.valence, strength: a.strength,
                    note: a.note, impact: a.impact, acceptance: a.value, createdAt: Double(a.issuedAtMS) / 1000)
                note.authentication = "simulation"
                let request = tasteRequest(note, mission: mission)
                let resolution = applicable.last { $0.kind == .resolve && $0.subjectID == request.id && $0.subjectDigest == HumanContext.requestDigest(request) }
                note.resolved = resolution != nil; note.resolution = resolution?.value; note.contextStale = false
                notes.removeAll { $0.id == a.nonce }
                notes.append(note)
                if a.impact == "review", resolution == nil { queue.append(request) }
            }
            mission.tasteNotes = notes.sorted { $0.createdAt > $1.createdAt }
            var accepted = 0, required = 0, missing = 0, reported = 0, conflicts = 0
            for ci in mission.checkpoints.indices {
                var c = mission.checkpoints[ci]
                c.authentication = "unsigned claim"; c.status = "pending"; c.trackingState = "missing"
                c.source = "untrusted source report"
                let latestReview = applicable.last { $0.kind == .reviewEvidence && $0.checkpointID == c.id }
                var records = c.records ?? []
                for ei in records.indices {
                    var e = records[ei]
                    e.authentication = "unsigned claim"; e.state = "reported"; e.reviewedAt = nil
                    e.fingerprint = HumanContext.evidenceDigest(e)
                    if duplicates.contains(e.id) { e.state = "invalidContext" }
                    else {
                        do {
                            try HumanArtifact.validate(e, mission: mission, check: c, now: now)
                            if let review = latestReview, review.subjectID == e.id, review.subjectDigest == e.fingerprint,
                               Double(review.issuedAtMS) / 1000 >= e.observedAt {
                                e.state = review.value == "accept" ? "accepted" : "rejected"
                                e.authentication = "simulation"; e.reviewedAt = Double(review.issuedAtMS) / 1000
                            }
                        } catch { e.state = "unavailableForAuthentication" }
                    }
                    records[ei] = e
                }
                records.sort { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt > $1.observedAt }
                c.records = records
                if c.kind == "taste" {
                    let taste = applicable.last { $0.kind == .taste && $0.checkpointID == c.id && $0.value != "unassessed" }
                    c.evidence = taste?.note ?? "No authenticated Taste judgment"
                    if let taste {
                        c.authentication = "simulation"; c.status = taste.value == "accept" ? "simulatedAccepted" : "simulatedRejected"
                        c.trackingState = taste.value == "accept" ? "acceptedTaste" : "rejectedTaste"; c.source = "simulated Taste"
                    }
                } else if let latest = records.first {
                    c.evidence = latest.summary; c.trackingState = latest.state
                    if latest.authentication == "simulation" {
                        c.status = latest.state == "accepted" ? "simulatedAccepted" : "simulatedRejected"
                        c.authentication = "simulation"; c.source = "simulated human review"
                    } else { c.status = "reported" }
                }
                if c.required != false {
                    required += 1
                    if c.status == "simulatedAccepted" { accepted += 1 }
                    else if c.status == "simulatedRejected" { conflicts += 1 }
                    else if c.status == "reported" { reported += 1 }
                    else { missing += 1 }
                }
                mission.checkpoints[ci] = c
            }
            // Only a matching native signed resolution can resolve the exact displayed request.
            queue.removeAll { q in
                ["taste", "judgment"].contains(q.kind) && q.missionId == mission.id && applicable.contains { a in
                    a.kind == .resolve && a.subjectID == q.id && a.subjectDigest == HumanContext.requestDigest(q)
                }
            }
            let risks = input.agents.contains { $0.missionId == mission.id && $0.trajectory == "atRisk" }
            let course = conflicts > 0 || risks ? "suspectedDrift" : required > 0 && accepted == required ? "readyForReview" : "unknown"
            mission.assessment = MissionAssessment(goalRevision: (try? HumanContext.sourceGoalRevision(mission)) ?? "",
                course: course, evidence: conflicts > 0 ? "conflicting" : accepted == required && required > 0 ? "verified" : reported > 0 ? "reported" : "missing",
                requiredCount: required, verifiedCount: 0, reportedCount: reported, missingCount: missing,
                staleCount: 0, conflictCount: conflicts, decisionCount: queue.filter { $0.missionId == mission.id && $0.needsDecision }.count,
                coverageIncomplete: original.assessment?.coverageIncomplete ?? false,
                reasons: confirmation == nil ? ["Human authentication is unavailable. Unsigned claims do not verify checks."] : [])
            mission.assessment?.authentication = simulationJournal == nil ? "unavailable" : "simulation"
            mission.assessment?.simulatedVerifiedCount = accepted
            // Legacy feeds without tracking records keep their existing observation UI;
            // alleged check statuses were still stripped above.
            if original.assessment == nil, original.checkpoints.allSatisfy({ $0.records?.isEmpty != false }), simulationJournal == nil {
                mission.assessment = nil
            }
            feed.missions[mi] = mission
        }
        feed.queue = simulationJournal == nil && input.queue == nil && queue.isEmpty ? nil : queue
        return feed
    }

    public static func tasteRequest(_ note: TasteSignal, mission: Mission) -> QueueItem {
        QueueItem(id: "simulation-taste:" + note.id, missionId: mission.id, missionTitle: mission.title,
            kind: "taste", title: "Review your simulated Taste signal", why: note.note,
            impact: "Human judgment · no runtime permission will be granted", priority: 1,
            recordId: note.id, recordGoalRevision: note.goalRevision, contextStale: false)
    }
}
