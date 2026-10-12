import Foundation
import Testing
@testable import SneakPeekCore

@Test(arguments: ["/tmp/payload.command", "/tmp/payload.app", "/tmp/payload.terminal",
                   "/tmp/report.pdf", "file:///tmp/payload.command", "file://localhost/tmp/payload.app"])
func localEvidenceIsOnlyRevealed(reference: String) {
    guard case .reveal = EvidenceReference(reference) else { Issue.record("A local artifact must never be launched"); return }
    #expect(EvidenceReference(reference).buttonLabel == "Show in Finder")
}

@Test func remoteFileAndExecutableURLSchemesAreNotAccepted() {
    for reference in ["file://other-host/tmp/a", "javascript:alert(1)", "data:text/plain,a", "relative.command", "https://user:secret@example.com/a"] {
        #expect(EvidenceReference(reference) == .unsupported)
    }
    #expect(EvidenceReference("https://example.com/report") == .website(URL(string: "https://example.com/report")!))
}

@Test func privateWritesCreatePrivateDirectoriesAndReplacePermissiveFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("state")
    let path = directory.appendingPathComponent("record.json")
    try PrivateStateFiles.write(Data("first".utf8), to: path)
    func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
    }
    #expect(try mode(directory) == 0o700)
    #expect(try mode(path) == 0o600)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
    try PrivateStateFiles.write(Data("replacement".utf8), to: path)
    #expect(try mode(path) == 0o600)
    #expect(try Data(contentsOf: path) == Data("replacement".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["record.json"])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try PrivateStateFiles.write(Data(), to: path)
    #expect(try mode(directory) == 0o755) // An explicit shared directory is not chmodded.
    try PrivateStateFiles.ensureDirectory(directory, repairExisting: true)
    #expect(try mode(directory) == 0o700)
}

@Test func acceptedLabelsDescribeUnsignedProvenance() throws {
    let data = Data(#"{"goalRevision":"g","course":"readyForReview","evidence":"verified","requiredCount":1,"verifiedCount":1,"reportedCount":0,"missingCount":0,"staleCount":0,"conflictCount":0,"decisionCount":0,"coverageIncomplete":false,"reasons":[]}"#.utf8)
    let assessment = try JSONDecoder().decode(MissionAssessment.self, from: data)
    #expect(assessment.courseLabel.contains("unsigned"))
    #expect(assessment.evidenceLabel.contains("unsigned"))
}
