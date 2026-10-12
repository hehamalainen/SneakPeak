from __future__ import annotations
import copy
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import time
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bridge"))
from common import atomic_json, agent, request
from mission_commands import apply
from mission_tracking import add_evidence, definition_revision, fingerprint, project, revision, save_record
from peek import Demo, checkpoint, decorate_demo, merge_feed, mission_filename
from types import SimpleNamespace


class MissionTrackingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name).resolve()
        self.state = self.directory / "state.json"
        self.now = time.time()
        self.mission = {"id": "mission-a", "title": "Launch a calm workflow",
                        "goal": "Complete the intended outcome", "pinned": True,
                        "checkpoints": [{"id": "check-a", "label": "The acceptance test passes", "status": "pending", "evidence": "Awaiting evidence", "source": "human"}]}
        self.worker = agent("agent-a", "mission-a", "Worker", "Codex")
        self.worker.update(status="working", trajectory="onCourse", summary="Busy writing code")
        self.feed = {"generatedAt": self.now, "demo": False, "missions": [self.mission],
                     "agents": [self.worker], "harnesses": [], "warnings": []}
        atomic_json(self.state, self.feed)
        atomic_json(self.directory / "missions" / mission_filename("mission-a"), self.mission)

    def tearDown(self):
        self.temporary.cleanup()

    def project(self, now=None):
        return project(copy.deepcopy(self.feed), self.directory, now or self.now + 5)

    def evidence(self, claim="supports", reference="https://example.com/test-result"):
        return add_evidence(self.directory, self.mission, "check-a", "The integration check passes", reference, claim)

    def accept(self, evidence, verdict="accept"):
        payload = {"missionId": self.mission["id"], "goalRevision": revision(self.mission),
                   "evidenceId": evidence["id"], "fingerprint": fingerprint(evidence), "verdict": verdict}
        return apply(self.state, "review-evidence", payload)

    def taste(self, **extra):
        payload = {"missionId": self.mission["id"], "goalRevision": revision(self.mission),
                   "valence": "off", "strength": "hunch", "note": "It feels too demanding",
                   "impact": "note", "acceptance": "unassessed", **extra}
        return apply(self.state, "taste", payload)

    def test_activity_and_self_report_cannot_establish_goal_progress(self):
        result = self.project()
        assessment = result["missions"][0]["assessment"]
        self.assertEqual(assessment["course"], "unknown")
        self.assertEqual(assessment["evidence"], "missing")
        self.assertEqual(assessment["decisionCount"], 0)
        self.assertEqual([q["kind"] for q in result["queue"]], ["evidence"])

    def test_legacy_verified_label_without_bound_evidence_is_unproven(self):
        self.mission["checkpoints"][0]["status"] = "verified"
        self.mission["checkpoints"][0]["source"] = "human"
        result = self.project()
        self.assertEqual(result["missions"][0]["assessment"]["verifiedCount"], 0)

    def test_inspectable_report_needs_independent_review(self):
        self.evidence()
        result = self.project()
        self.assertEqual(result["missions"][0]["assessment"]["course"], "supportedProgress")
        self.assertEqual(result["missions"][0]["assessment"]["verifiedCount"], 0)
        self.assertEqual(result["missions"][0]["checkpoints"][0]["records"][0]["state"], "reported")
        self.assertEqual([q["kind"] for q in result["queue"]], ["evidence"])
        self.assertEqual(result["missions"][0]["assessment"]["decisionCount"], 0)

    def test_inconclusive_report_does_not_claim_supported_progress(self):
        self.evidence(claim="unknown")
        result = self.project()
        self.assertEqual(result["missions"][0]["assessment"]["course"], "unknown")
        self.assertEqual(result["missions"][0]["checkpoints"][0]["trackingState"], "inconclusive")
        self.assertEqual(result["missions"][0]["assessment"]["decisionCount"], 0)

    def test_review_is_bound_to_record_and_current_goal(self):
        record = self.evidence()
        self.accept(record)
        result = self.project()
        self.assertEqual(result["missions"][0]["assessment"]["course"], "readyForReview")
        changed = copy.deepcopy(self.feed)
        changed["missions"][0]["goal"] = "A different intended outcome"
        result = project(changed, self.directory, self.now + 5)
        self.assertEqual(result["missions"][0]["assessment"]["verifiedCount"], 0)
        self.assertEqual(result["missions"][0]["checkpoints"][0]["records"][0]["state"], "goalChanged")

    def test_record_mutation_cannot_replay_a_previous_acceptance(self):
        record = self.evidence()
        self.accept(record)
        record["summary"] = "A different assertion"
        save_record(self.directory, "evidence", record)
        result = self.project()
        self.assertEqual(result["missions"][0]["assessment"]["verifiedCount"], 0)
        self.assertEqual(result["missions"][0]["checkpoints"][0]["records"][0]["state"], "reported")

    def test_new_failure_supersedes_old_pass(self):
        accepted = self.evidence()
        self.accept(accepted)
        failed = self.evidence("contradicts")
        failed["observedAt"] = accepted["observedAt"] + 1
        save_record(self.directory, "evidence", failed)
        result = self.project()
        self.assertEqual(result["missions"][0]["assessment"]["course"], "suspectedDrift")
        self.assertEqual(result["missions"][0]["assessment"]["verifiedCount"], 0)
        self.assertIn("drift", [q["kind"] for q in result["queue"]])

    def test_human_can_explicitly_reject_or_accept_a_reported_conflict(self):
        record = self.evidence("contradicts")
        self.accept(record, "reject")
        self.assertEqual(self.project()["missions"][0]["assessment"]["course"], "suspectedDrift")
        self.accept(record, "accept")
        self.assertEqual(self.project()["missions"][0]["assessment"]["course"], "readyForReview")

    def test_stale_evidence_and_missing_reference_are_not_drift_or_decisions(self):
        record = self.evidence(reference="")
        result = self.project()
        self.assertEqual(result["missions"][0]["checkpoints"][0]["records"][0]["state"], "missingReference")
        self.assertEqual(result["missions"][0]["assessment"]["decisionCount"], 0)
        record["reference"] = "https://example.com/proof"
        record["observedAt"] = self.now - 90000
        save_record(self.directory, "evidence", record)
        result = self.project()
        self.assertEqual(result["missions"][0]["assessment"]["evidence"], "stale")
        self.assertEqual(result["missions"][0]["assessment"]["course"], "unknown")

    def test_local_artifact_change_invalidates_accepted_snapshot(self):
        artifact = self.directory / "test-result.txt"
        artifact.write_text("PASS")
        record = self.evidence(reference=str(artifact))
        self.accept(record)
        self.assertEqual(self.project()["missions"][0]["assessment"]["verifiedCount"], 1)
        artifact.write_text("FAIL with a longer result")
        result = self.project()
        self.assertEqual(result["missions"][0]["checkpoints"][0]["records"][0]["state"], "artifactChanged")
        self.assertEqual(result["missions"][0]["assessment"]["verifiedCount"], 0)

    def test_a_taste_hunch_can_be_wordless_and_does_not_create_a_decision(self):
        note = self.taste(note="")
        result = self.project()
        self.assertEqual(note["note"], "")
        self.assertEqual(result["missions"][0]["assessment"]["course"], "unknown")
        self.assertEqual(result["missions"][0]["assessment"]["decisionCount"], 0)
        self.assertEqual(len(result["missions"][0]["tasteNotes"]), 1)

    def test_taste_review_is_explicit_and_never_an_executable_permission(self):
        note = self.taste(impact="review")
        result = self.project()
        item = next(q for q in result["queue"] if q["kind"] == "taste")
        self.assertEqual(result["missions"][0]["assessment"]["decisionCount"], 1)
        self.assertNotIn("requestId", item)
        apply(self.state, "resolve", {"missionId": "mission-a", "recordId": note["id"],
              "recordGoalRevision": note["goalRevision"], "outcome": "keep"})
        self.assertFalse(any(q["kind"] == "taste" for q in self.project()["queue"]))
        self.assertFalse((self.directory / "decisions").exists())

    def test_taste_cannot_satisfy_an_objective_evidence_check(self):
        with self.assertRaisesRegex(ValueError, "only a check explicitly defined as human taste"):
            self.taste(checkpointId="check-a", acceptance="accept", valence="right")
        self.assertEqual(self.project()["missions"][0]["assessment"]["verifiedCount"], 0)

    def test_explicit_taste_check_is_labeled_subjective_acceptance(self):
        self.mission["checkpoints"][0]["kind"] = "taste"
        atomic_json(self.state, self.feed)
        atomic_json(self.directory / "missions" / mission_filename("mission-a"), self.mission)
        self.taste(checkpointId="check-a", acceptance="accept", valence="right")
        result = self.project()
        self.assertEqual(result["missions"][0]["checkpoints"][0]["trackingState"], "acceptedTaste")
        self.assertEqual(result["missions"][0]["checkpoints"][0]["source"], "human taste")
        self.assertEqual(result["missions"][0]["assessment"]["verifiedCount"], 1)

    def test_old_taste_context_cannot_steer_new_goal_but_can_be_dismissed(self):
        note = self.taste(impact="review")
        self.mission["goal"] = "A changed outcome"
        atomic_json(self.state, self.feed)
        atomic_json(self.directory / "missions" / mission_filename("mission-a"), self.mission)
        with self.assertRaisesRegex(ValueError, "earlier goal"):
            apply(self.state, "resolve", {"missionId": "mission-a", "recordId": note["id"], "recordGoalRevision": note["goalRevision"], "outcome": "change"})
        apply(self.state, "resolve", {"missionId": "mission-a", "recordId": note["id"], "recordGoalRevision": note["goalRevision"], "outcome": "dismiss"})
        self.assertFalse(any(q["kind"] == "taste" for q in self.project()["queue"]))

    def test_runtime_decisions_sort_before_review_and_expired_requests_cannot_act(self):
        self.worker["request"] = request("Allow this exact step?", "Exact host scope", ttl=300)
        result = self.project()
        self.assertEqual(result["queue"][0]["kind"], "runtime")
        self.assertEqual(result["missions"][0]["assessment"]["decisionCount"], 1)
        self.worker["request"]["expiresAt"] = self.now - 1
        self.assertFalse(any(q["kind"] == "runtime" for q in self.project()["queue"]))

    def test_missing_checks_group_per_mission_and_coverage_is_explicit(self):
        for i in range(5):
            self.mission["checkpoints"].append({"id": "more-" + str(i), "label": "Another check", "status": "pending", "evidence": "", "source": "human"})
        self.worker["harnessId"] = "codex"
        self.feed["harnesses"] = [{"id": "codex", "omittedLogs": 3}]
        result = self.project()
        self.assertEqual(len([q for q in result["queue"] if q["kind"] == "evidence"]), 1)
        self.assertTrue(result["missions"][0]["assessment"]["coverageIncomplete"])
        self.assertEqual(result["missions"][0]["assessment"]["decisionCount"], 0)

    def test_definition_save_preserves_new_legacy_report_and_sidecar_evidence(self):
        old_revision = definition_revision(self.mission)
        old_editor = copy.deepcopy(self.mission)
        record = self.evidence()
        self.accept(record)
        checkpoint(SimpleNamespace(state=str(self.state), agent="agent-a", checkpoint="check-a",
                                   evidence="A newer agent report", next="Review", trajectory="onCourse"))
        old_editor["title"] = "New human title"
        apply(self.state, "definition", {"missionId": "mission-a", "definitionRevision": old_revision, "definition": old_editor})
        saved = json.loads((self.directory / "missions" / mission_filename("mission-a")).read_text())
        self.assertEqual(saved["checkpoints"][0]["evidence"], "A newer agent report")
        result = merge_feed([], [], self.directory)
        projected = project(result, self.directory, self.now + 5)
        self.assertEqual(projected["missions"][0]["assessment"]["verifiedCount"], 1)

    def test_definition_conflict_and_duplicate_ids_are_rejected(self):
        base = definition_revision(self.mission)
        updated = copy.deepcopy(self.mission); updated["title"] = "First title"
        apply(self.state, "definition", {"missionId": "mission-a", "definitionRevision": base, "definition": updated})
        with self.assertRaisesRegex(ValueError, "changed while the editor"):
            apply(self.state, "definition", {"missionId": "mission-a", "definitionRevision": base, "definition": self.mission})
        duplicate = copy.deepcopy(updated)
        duplicate["checkpoints"].append(copy.deepcopy(duplicate["checkpoints"][0]))
        with self.assertRaisesRegex(ValueError, "identities must be unique"):
            apply(self.state, "definition", {"missionId": "mission-a", "definitionRevision": definition_revision(updated), "definition": duplicate})

    def test_pinned_mission_keeps_a_human_decision_after_workers_disappear(self):
        apply(self.state, "judgment", {"missionId": "mission-a", "goalRevision": revision(self.mission),
                                      "title": "Choose the intended experience", "why": "The metrics do not settle it"})
        feed = merge_feed([], [], self.directory)
        result = project(feed, self.directory)
        self.assertEqual(len(result["missions"]), 1)
        self.assertEqual(result["missions"][0]["assessment"]["decisionCount"], 1)

    def test_one_malformed_evidence_record_cannot_verify_or_stop_other_missions(self):
        bad = {"id": str(uuid.uuid4()), "missionId": "mission-a", "goalRevision": revision(self.mission),
               "checkpointId": "check-a", "summary": "Untrusted", "observedAt": self.now,
               "reference": ["bad"], "verdict": "supports"}
        atomic_json(self.directory / "evidence" / (bad["id"] + ".json"), bad)
        self.evidence()
        result = self.project()
        self.assertEqual(result["missions"][0]["assessment"]["reportedCount"], 1)
        self.assertTrue(result["warnings"])

    def test_malformed_review_and_judgment_references_are_skipped(self):
        for category, extra in [("evidence-reviews", {"evidenceId": [], "fingerprint": "bad", "verdict": "accept"}),
                                ("judgment-resolutions", {"judgmentId": [], "outcome": "keep"}),
                                ("judgments", {"title": [], "why": "bad", "impact": "bad"})]:
            record = {"id": str(uuid.uuid4()), "missionId": "mission-a", "goalRevision": revision(self.mission),
                      "createdAt": self.now, **extra}
            save_record(self.directory, category, record)
        result = self.project()
        self.assertEqual(len(result["warnings"]), 3)
        self.assertEqual(result["missions"][0]["assessment"]["decisionCount"], 0)

    def test_example_evidence_is_still_reviewable_after_pinning_a_taste_note(self):
        demo = Demo()
        feed = demo.feed(self.directory)
        decorate_demo(feed, demo.started)
        feed = project(feed, self.directory)
        atomic_json(self.state, feed)
        mission = feed["missions"][0]
        apply(self.state, "taste", {"missionId": mission["id"], "goalRevision": mission["goalRevision"],
                                  "valence": "right", "note": "", "impact": "note"})
        atomic_json(self.directory / "missions" / mission_filename(mission["id"]), mission)
        record = mission["checkpoints"][1]["records"][0]
        result = apply(self.state, "review-evidence", {"missionId": mission["id"], "goalRevision": mission["goalRevision"],
                        "evidenceId": record["id"], "fingerprint": record["fingerprint"], "verdict": "accept"})
        self.assertEqual(result["evidenceId"], record["id"])

    def test_demo_actions_do_not_pin_example_missions_into_live_and_human_review_wins(self):
        demo = Demo()
        feed = demo.feed(self.directory)
        decorate_demo(feed, demo.started)
        feed = project(feed, self.directory)
        atomic_json(self.state, feed)
        mission = feed["missions"][0]
        apply(self.state, "taste", {"missionId": mission["id"], "goalRevision": mission["goalRevision"],
                                  "valence": "right", "note": "", "impact": "review"})
        record = mission["checkpoints"][0]["records"][0]
        apply(self.state, "review-evidence", {"missionId": mission["id"], "goalRevision": mission["goalRevision"],
              "evidenceId": record["id"], "fingerprint": record["fingerprint"], "verdict": "reject"})
        refreshed = demo.feed(self.directory)
        decorate_demo(refreshed, demo.started)
        result = project(refreshed, self.directory)
        self.assertEqual(result["missions"][0]["assessment"]["course"], "suspectedDrift")
        self.assertFalse(any(m["id"] == mission["id"] for m in merge_feed([], [], self.directory)["missions"]))

    def test_native_command_transport_records_a_hunch_without_a_permission(self):
        command = Path(__file__).resolve().parents[1] / "bridge" / "mission_commands.py"
        result = subprocess.run([sys.executable, str(command), "--state", str(self.state), "--action", "taste"],
                                input=json.dumps({"missionId": "mission-a", "goalRevision": revision(self.mission),
                                                  "valence": "off", "note": "", "impact": "review"}),
                                capture_output=True, text=True, check=True)
        self.assertTrue(json.loads(result.stdout)["ok"])
        self.assertIn("taste", [q["kind"] for q in self.project()["queue"]])
        self.assertFalse((self.directory / "decisions").exists())

    def test_pinned_mission_scope_survives_between_worker_sessions(self):
        self.mission["workspace"] = "/project-A"
        atomic_json(self.directory / "missions" / mission_filename("mission-a"), self.mission)
        self.assertEqual(merge_feed([], [], self.directory, project="/project-B")["missions"], [])
        self.assertEqual(len(merge_feed([], [], self.directory, project="/project-A")["missions"]), 1)
        self.mission.pop("workspace")
        atomic_json(self.directory / "missions" / mission_filename("mission-a"), self.mission)
        self.assertEqual(merge_feed([], [], self.directory, project="/project-A")["missions"], [])

    def test_malformed_record_numbers_do_not_break_projection_or_native_decoding(self):
        for invalid in [True, 10**1000]:
            record = self.evidence()
            record["observedAt"] = invalid
            save_record(self.directory, "evidence", record)
        record = self.evidence()
        record["localFile"] = {"size": 10**1000, "modifiedNS": "0"}
        save_record(self.directory, "evidence", record)
        result = self.project()
        self.assertEqual(result["missions"][0]["assessment"]["reportedCount"], 0)
        self.assertEqual(len(result["warnings"]), 3)

    def test_a_missing_local_artifact_cannot_be_accepted(self):
        record = self.evidence(reference=str(self.directory / "absent-proof.txt"))
        self.assertEqual(self.project()["missions"][0]["checkpoints"][0]["records"][0]["state"], "missingArtifact")
        with self.assertRaisesRegex(ValueError, "unavailable"):
            self.accept(record)

    def test_thousand_workflows_keep_uncertainty_separate_from_human_decisions(self):
        feed = {"demo": False, "agents": [], "harnesses": [], "warnings": [], "missions": []}
        for i in range(1000):
            mission = copy.deepcopy(self.mission); mission["id"] = f"mission-{i}"
            feed["missions"].append(mission)
        result = project(feed, self.directory, self.now)
        self.assertEqual(len(result["queue"]), 1000)
        self.assertTrue(all(item["kind"] == "evidence" for item in result["queue"]))
        self.assertTrue(all(m["assessment"]["decisionCount"] == 0 for m in result["missions"]))

    def test_missing_file_url_cannot_be_accepted(self):
        artifact = self.directory / 'absent report.txt'
        record = self.evidence(reference=artifact.as_uri())
        with self.assertRaises(ValueError):
            self.accept(record)
        result = self.project()
        self.assertEqual(result['missions'][0]['assessment']['verifiedCount'], 0)
        self.assertEqual(result['missions'][0]['checkpoints'][0]['records'][0]['state'], 'missingArtifact')

    def test_percent_encoded_file_url_has_the_same_snapshot_as_a_local_path(self):
        artifact = self.directory / 'result #1 café.txt'; artifact.write_text('PASS')
        record = self.evidence(reference=artifact.as_uri())
        self.assertEqual(record['reference'], str(artifact))
        self.assertIsNotNone(record['digest'])
        self.assertEqual(record['localFile']['size'], artifact.stat().st_size)
        self.accept(record)
        self.assertEqual(self.project()['missions'][0]['assessment']['verifiedCount'], 1)
        artifact.write_text('FAIL with changed content')
        self.assertEqual(self.project()['missions'][0]['checkpoints'][0]['records'][0]['state'], 'artifactChanged')

    def test_existing_file_url_records_still_check_missing_or_changed_artifacts(self):
        artifact = self.directory / 'legacy result.txt'; artifact.write_text('PASS')
        record = self.evidence(reference=str(artifact))
        record['reference'] = artifact.as_uri()  # Older stored records are not rewritten.
        save_record(self.directory, 'evidence', record)
        self.accept(record)
        self.assertEqual(self.project()['missions'][0]['assessment']['verifiedCount'], 1)
        artifact.unlink()
        result = self.project()
        self.assertEqual(result['missions'][0]['assessment']['verifiedCount'], 0)
        self.assertEqual(result['missions'][0]['checkpoints'][0]['records'][0]['state'], 'missingArtifact')

    def test_file_url_digest_is_checked_at_review_even_if_metadata_is_preserved(self):
        import os
        artifact = self.directory / 'bound result.txt'; artifact.write_text('PASS')
        before = artifact.stat()
        record = self.evidence(reference=str(artifact))
        record['reference'] = 'file://localhost' + artifact.as_uri()[len('file://'):]
        save_record(self.directory, 'evidence', record)
        artifact.write_text('FAIL')  # Same size and timestamp defeats a metadata-only check.
        os.utime(artifact, ns=(before.st_atime_ns, before.st_mtime_ns))
        with self.assertRaisesRegex(ValueError, 'content changed'):
            self.accept(record)
        self.assertEqual(self.project()['missions'][0]['assessment']['verifiedCount'], 0)

    def test_legacy_file_url_without_a_snapshot_requires_new_evidence(self):
        artifact = self.directory / 'old result.txt'; artifact.write_text('PASS')
        record = self.evidence(reference=str(artifact))
        record.update(reference=artifact.as_uri(), digest=None)
        record.pop('localFile')
        save_record(self.directory, 'evidence', record)
        with self.assertRaises(ValueError):
            self.accept(record)
        self.assertEqual(self.project()['missions'][0]['checkpoints'][0]['records'][0]['state'], 'missingReference')

    def test_remote_and_malformed_file_urls_are_not_reviewable(self):
        for reference in ['file://remote-host/tmp/report.txt', 'file:///tmp/report?query',
                          'file:///tmp/report#fragment', 'file:///tmp/report%00.txt', 'file:///tmp/report%FF.txt']:
            with self.subTest(reference=reference):
                record = self.evidence(reference=reference)
                with self.assertRaises(ValueError):
                    self.accept(record)
        self.assertEqual(self.project()['missions'][0]['assessment']['verifiedCount'], 0)


if __name__ == "__main__":
    unittest.main()
