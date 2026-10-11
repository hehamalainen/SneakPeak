from __future__ import annotations
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bridge"))
from common import atomic_json
from connect import configure
from copilot_hook import handle as copilot_hook
from harnesses import Registry, register
from observer import Observer, Session
from peek import merge_feed


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name).resolve()
        self.home = self.directory / "home"
        self.home.mkdir()
        self.state = self.directory / "state.json"

    def tearDown(self):
        self.temporary.cleanup()

    def copilot(self):
        path = self.home / ".copilot/session-state/session-a/events.jsonl"
        path.parent.mkdir(parents=True)
        path.touch()
        session = Session(path, "GitHub Copilot")
        session.consume({"type": "session.start", "data": {"sessionId": "session-a", "context": {"cwd": "/project"}}})
        session.consume({"type": "user.message", "data": {"content": "Implement the agreed mission"}})
        return session

    def test_all_harnesses_stay_in_catalog_without_sessions(self):
        observer = Observer(self.home, directory=self.directory)
        missions, agents = observer.refresh()
        feed = merge_feed(missions, agents, self.directory, observer.catalog)
        self.assertEqual({h["id"] for h in feed["harnesses"]}, {"codex", "claude", "antigravity", "copilot"})
        self.assertFalse(feed["agents"])
        self.assertTrue(all(h["sessionCount"] == 0 for h in feed["harnesses"]))

    def test_old_antigravity_is_explained_and_history_window_can_include_it(self):
        path = self.home / ".gemini/antigravity/brain/conversation-a/.system_generated/logs/transcript.jsonl"
        path.parent.mkdir(parents=True)
        old = time.time() - 3 * 86400
        row = {"type": "USER_INPUT", "created_at": old, "status": "DONE", "content": "<USER_REQUEST>Old mission</USER_REQUEST>"}
        path.write_text(json.dumps(row) + "\n")
        os.utime(path, (old, old))
        observer = Observer(self.home, directory=self.directory)
        _, agents = observer.refresh()
        ant = next(h for h in observer.catalog if h["id"] == "antigravity")
        self.assertEqual(ant["status"], "waiting")
        self.assertIn("24 hours", ant["detail"])
        self.assertIsNotNone(ant["lastSeen"])
        self.assertFalse(agents)
        atomic_json(self.directory / "harnesses.json", {"recentHours": 168})
        observer.last_scan = 0
        _, agents = observer.refresh()
        self.assertEqual(agents[0]["provider"], "Antigravity")
        self.assertTrue(time.time() - agents[0]["lastActivity"] > 86400)

    def test_copilot_public_text_and_scoped_permission_resolution(self):
        session = self.copilot()
        session.consume({"type": "assistant.message", "data": {"content": "Public update", "reasoningText": "PRIVATE", "encryptedContent": "SECRET"}})
        for rid in ["request-a", "request-b"]:
            session.consume({"type": "permission.requested", "data": {"requestId": rid, "permissionRequest": {"kind": "shell", "fullCommandText": "npm test"}}})
        session.consume({"type": "permission.completed", "data": {"requestId": "unrelated"}})
        self.assertEqual(len(session.copilot_requests), 2)
        session.consume({"type": "permission.completed", "data": {"requestId": "request-a"}})
        self.assertIsNotNone(session.value["request"])
        self.assertEqual(session.value["request"]["mode"], "handoff")
        session.consume({"type": "permission.completed", "data": {"requestId": "request-b"}})
        self.assertIsNone(session.value["request"])
        self.assertNotIn("PRIVATE", json.dumps(session.value))
        self.assertNotIn("SECRET", json.dumps(session.value))

    def test_discovery_limit_reports_incomplete_coverage_and_keeps_newest_logs(self):
        folder = self.home / ".copilot/session-state"
        now = time.time()
        for i in range(103):
            path = folder / f"session-{i:03d}" / "events.jsonl"
            path.parent.mkdir(parents=True)
            path.touch()
            os.utime(path, (now - i, now - i))
        registry = Registry(self.home, self.directory)
        definition = next(h for h in registry.definitions if h["id"] == "copilot")
        files, catalog = registry.discover(definition)
        self.assertEqual(len(files), 100)
        self.assertEqual(catalog["omittedLogs"], 3)
        self.assertEqual(catalog["discoveryLimit"], 100)
        self.assertIn("coverage is incomplete", catalog["detail"])
        self.assertEqual(files[0].parent.name, "session-000")
        self.assertEqual(files[-1].parent.name, "session-099")
        session = self.copilot_for_path(files[0])
        feed = merge_feed([session.mission], [session.value], self.directory, [catalog])
        self.assertIn("coverage is incomplete", feed["harnesses"][0]["detail"])
        self.assertTrue(any("3 recent logs omitted" in warning for warning in feed["warnings"]))
        definition["enabled"] = False
        files, catalog = registry.discover(definition)
        self.assertFalse(files)
        self.assertEqual(catalog["omittedLogs"], 0)

    def copilot_for_path(self, path):
        session = Session(path, "GitHub Copilot")
        session.consume({"type": "session.start", "data": {"sessionId": path.parent.name, "context": {"cwd": "/project"}}})
        return session

    def test_copilot_model_turn_is_not_automatically_a_finished_agent_turn(self):
        session = self.copilot()
        session.consume({"type": "assistant.message", "data": {"turnId": "t1", "content": "Running tests", "toolRequests": [{}]}})
        session.consume({"type": "assistant.turn_end", "data": {"turnId": "t1"}})
        self.assertEqual(session.value["status"], "observed")
        session.consume({"type": "assistant.message", "data": {"turnId": "t2", "content": "Ready for review", "phase": "final_answer"}})
        session.consume({"type": "assistant.turn_end", "data": {"turnId": "t2"}})
        self.assertEqual(session.value["status"], "done")
        session.consume({"type": "assistant.turn_start", "data": {"turnId": "t2"}})
        session.consume({"type": "assistant.turn_end", "data": {"turnId": "t2"}})
        self.assertEqual(session.value["status"], "observed")

    def test_copilot_subagent_envelopes_do_not_overwrite_root_summary(self):
        session = self.copilot()
        session.consume({"type": "assistant.message", "data": {"content": "Root progress"}})
        session.consume({"type": "assistant.message", "agentId": "worker-a", "data": {"content": "Child progress"}})
        self.assertEqual(session.value["summary"], "Root progress")
        child = session.children["worker-a"]
        self.assertEqual(child.value["summary"], "Child progress")
        self.assertEqual(child.value["missionId"], "copilot:session-a")
        self.assertEqual(child.value["sessionId"], "session-a")

    def test_custom_cli_registration_and_event_round_trip_without_rebuild(self):
        script = Path(__file__).resolve().parents[1] / "bridge/peek.py"
        command = [sys.executable, str(script)]
        result = subprocess.run(command + ["register", "--state", str(self.state), "--name", "My Harness"], check=True, capture_output=True, text=True)
        registration = json.loads(result.stdout)
        for event, extra in [("started", ["--goal", "Ship the desired outcome"]),
                             ("progress", ["--evidence", "Integration test passes", "--trajectory", "onCourse"]),
                             ("needs_input", ["--summary", "Choose the release target"]),
                             ("resolved", []), ("completed", ["--summary", "Ready for review"])]:
            subprocess.run(command + ["emit", "--state", str(self.state), "--harness", registration["id"], "--session", "non-uuid-session", "--event", event] + extra, check=True, capture_output=True)
        observer = Observer(self.home, directory=self.directory)
        missions, agents = observer.refresh()
        self.assertEqual(len(agents), 1)
        self.assertEqual(agents[0]["provider"], "My Harness")
        self.assertEqual(agents[0]["status"], "done")
        self.assertEqual(agents[0]["evidence"], "Integration test passes")
        self.assertEqual(agents[0]["handoffKind"], "copy-id")
        self.assertEqual(missions[0]["goal"], "Ship the desired outcome")

    def test_multiple_generic_agents_share_a_root_mission(self):
        entry = register(self.directory, "A Team")
        path = Path(entry["logs"][0]); path.parent.mkdir(parents=True)
        rows = [{"schema": 1, "event": "started", "session_id": "root", "goal": "Root outcome"},
                {"schema": 1, "event": "started", "session_id": "child", "parent_session_id": "root", "goal": "Child task"}]
        path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
        missions, agents = Observer(self.home, directory=self.directory).refresh()
        self.assertEqual(len(agents), 2)
        self.assertEqual(len(missions), 1)
        self.assertEqual({a["missionId"] for a in agents}, {"a-team:root"})
        self.assertEqual(missions[0]["goal"], "Root outcome")

    def test_invalid_registry_does_not_execute_or_load_code(self):
        atomic_json(self.directory / "harnesses.json", {"harnesses": [{"id": "../../escape", "name": "Unsafe", "format": "python", "logs": ["/tmp/file"]}]})
        registry = Registry(self.home, self.directory)
        self.assertEqual(len(registry.definitions), 4)
        self.assertTrue(registry.warnings)

    def test_disabling_a_harness_removes_sessions_and_connected_source(self):
        session = self.copilot()
        atomic_json(self.directory / "harnesses.json", {"harnesses": [{"id": "copilot", "enabled": False}]})
        observer = Observer(self.home, directory=self.directory)
        missions, agents = observer.refresh()
        atomic_json(self.directory / "sources/late-hook.json", {"generatedAt": time.time(), "agents": [session.value], "missions": [session.mission]})
        feed = merge_feed(missions, agents, self.directory, observer.catalog)
        self.assertFalse(feed["agents"])
        self.assertEqual(next(h for h in feed["harnesses"] if h["id"] == "copilot")["status"], "disabled")

    def test_project_setup_preserves_other_hooks_and_is_idempotent(self):
        project = self.directory / "project"; project.mkdir()
        ant = project / ".agents/hooks.json"
        atomic_json(ant, {"other-hook": {"Stop": []}})
        configure("antigravity", project, self.state)
        configure("antigravity", project, self.state)
        value = json.loads(ant.read_text())
        self.assertEqual(value["other-hook"], {"Stop": []})
        self.assertNotIn("PreToolUse", value["sneakpeek-observer"])
        copilot = project / ".github/hooks/sneakpeek.json"
        atomic_json(copilot, {"version": 1, "hooks": {"agentStop": [{"type": "command", "exec": "echo", "args": ["keep"]}]}})
        configure("copilot", project, self.state)
        configure("copilot", project, self.state)
        value = json.loads(copilot.read_text())
        self.assertEqual(len(value["hooks"]["agentStop"]), 2)
        self.assertNotIn("permissionRequest", value["hooks"])
        self.assertNotIn("preToolUse", value["hooks"])

    def test_copilot_observer_hook_never_returns_a_permission_decision(self):
        event = {"sessionId": "session-a", "cwd": "/project"}
        self.assertEqual(copilot_hook(event, self.state, "agentStop"), {})
        source = next((self.directory / "sources").glob("*.json"))
        self.assertEqual(json.loads(source.read_text())["agents"][0]["status"], "done")


if __name__ == "__main__":
    unittest.main()
