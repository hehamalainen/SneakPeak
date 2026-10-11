"""Regressions from the e5d56d7 adversarial review; synthetic inputs only."""
import copy
import io
import json
from pathlib import Path
import queue
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bridge"))
from common import agent, atomic_json, approval_surface_available, request
from observer import Observer, Session
from peek import Demo, checkpoint, merge_feed, mission_filename, watch
from harnesses import Registry
from claude_hook import handle as hook_handle

def handle(event, state, timeout=120):
    return hook_handle(event, state, timeout, trusted_local_inline=True)
import codex_runner


class ReviewRegressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / "state.json"

    def tearDown(self): self.temp.cleanup()

    def surface(self, **overrides):
        value = {"generatedAt": time.time(), "live": True, "statePath": str(self.state.resolve()), "provider": "All sources"}
        value.update(overrides)
        atomic_json(self.root / "approval-surface.json", value)

    def test_fresh_collector_does_not_imply_live_approval_surface(self):
        atomic_json(self.state, {"generatedAt": time.time()})
        event = {"hook_event_name": "PermissionRequest", "session_id": "one", "cwd": str(self.root)}
        self.assertFalse(approval_surface_available(self.state, "Claude", str(self.root)))
        self.assertEqual(handle(event, self.state), {})
        self.assertFalse((self.root / "sources").exists())
        for overrides in [{"live": False}, {"generatedAt": time.time() - 30}, {"provider": "Codex"}, {"statePath": "/another/state.json"}]:
            self.surface(**overrides)
            self.assertFalse(approval_surface_available(self.state, "Claude", str(self.root)))
        self.surface()
        self.assertTrue(approval_surface_available(self.state, "Claude", str(self.root)))

    def test_claude_returns_to_host_when_surface_switches_to_demo(self):
        atomic_json(self.state, {"generatedAt": time.time(), "missions": [], "agents": []})
        self.surface()
        with patch("claude_hook.time.sleep", side_effect=lambda _: self.surface(live=False)):
            result = handle({"hook_event_name": "PermissionRequest", "session_id": "one", "cwd": str(self.root)}, self.state, timeout=1)
        self.assertEqual(result, {})
        source = json.loads(next((self.root / "sources").glob("*.json")).read_text())
        self.assertIsNone(source["agents"][0]["request"])
        self.assertIn("returned to Claude", source["agents"][0]["summary"])

    def test_scoped_connected_sources_use_workspace_and_cannot_override_goal(self):
        a = agent("codex:one", "codex:one", "One", "Codex")
        mission = {"id": a["id"], "title": "A", "goal": "Goal A", "checkpoints": []}
        wrong = dict(a, workspace="/project-B", request=request("Allow B?", "Project B"))
        atomic_json(self.root / "sources/b.json", {"generatedAt": time.time(), "managed": True, "active": True,
                    "missions": [dict(mission, goal="Wrong goal")], "agents": [wrong]})
        feed = merge_feed([mission], [a], self.root, project="/project-A")
        self.assertIsNone(feed["agents"][0]["request"])
        self.assertEqual(feed["missions"][0]["goal"], "Goal A")
        wrong.pop("workspace")
        atomic_json(self.root / "sources/b.json", {"agents": [wrong]})
        self.assertEqual(merge_feed([], [], self.root, project="/project-A")["agents"], [])
        wrong["workspace"] = "/project-A/subdirectory"
        atomic_json(self.root / "sources/b.json", {"generatedAt": time.time(), "missions": [mission], "agents": [wrong]})
        self.assertIsNotNone(merge_feed([], [], self.root, project="/project-A")["agents"][0]["request"])

    def test_inline_surface_requires_project_scope(self):
        atomic_json(self.state, {"generatedAt": time.time(), "projectRoot": "/project-A"})
        self.surface()
        self.assertFalse(approval_surface_available(self.state, "Codex", "/project-B"))
        self.assertFalse(approval_surface_available(self.state, "Codex", ""))
        self.assertTrue(approval_surface_available(self.state, "Codex", "/project-A/nested"))

    def test_managed_json_lease_cannot_override_newer_observation(self):
        old = agent("codex:resumed", "codex:resumed", "Managed", "Codex")
        old.update(status="done", lastActivity=time.time() - 600)
        new = dict(old, status="working", lastActivity=time.time())
        for metadata in [{"managed": True}, {"managed": True, "active": False},
                         {"managed": True, "active": True, "generatedAt": time.time() - 600}]:
            source = {"generatedAt": time.time(), "agents": [old], **metadata}
            atomic_json(self.root / "sources/old.json", source)
            self.assertEqual(merge_feed([], [new], self.root)["agents"][0]["status"], "working")
        atomic_json(self.root / "sources/old.json", {"generatedAt": time.time(), "managed": True, "active": True, "agents": [old]})
        self.assertEqual(merge_feed([], [new], self.root)["agents"][0]["status"], "working")

    def test_finished_bridge_releases_managed_authority(self):
        bridge = codex_runner.CodexBridge(self.root, "Goal", str(self.root), lambda _: None)
        bridge.setup({"id": "one"})
        bridge.receive({"method": "turn/completed", "params": {"threadId": "one", "turn": {"status": "completed"}}})
        bridge.tick()
        source = json.loads(next((self.root / "sources").glob("*.json")).read_text())
        self.assertFalse(source["active"])
        self.assertEqual(source["agents"][0]["workspace"], str(self.root))

    def test_busy_messages_do_not_bypass_disconnection(self):
        atomic_json(self.state, {"generatedAt": time.time()}); self.surface()
        state = self.state
        messages = [{"id": 1, "result": {}}, {"id": 2, "result": {"thread": {"id": "one"}}},
                    {"method": "item/completed", "params": {"item": {"type": "agentMessage", "text": "Activity"}}}]
        class Messages:
            def __init__(self): self.index = 0
            def put(self, _): pass
            def get(self, timeout):
                if self.index == 2: atomic_json(state, {"generatedAt": time.time() - 30})
                result = messages[self.index]; self.index += 1; return result
        class Process:
            def __init__(self): self.stdin = io.StringIO(); self.stdout = io.StringIO(); self.stopped = False
            def poll(self): return 0 if self.stopped else None
            def terminate(self): self.stopped = True
            def wait(self, timeout): return 0
            def kill(self): self.stopped = True
        process = Process()
        with patch.object(codex_runner.subprocess, "Popen", return_value=process), patch.object(codex_runner.queue, "Queue", Messages), patch.object(codex_runner.threading.Thread, "start"):
            result = codex_runner.run(SimpleNamespace(state=str(self.state), codex="never-executed", project=str(self.root), goal="Synthetic goal", trusted_local_inline=True))
        self.assertEqual(result, 1)
        self.assertTrue(process.stopped)
        source = json.loads(next((self.root / "sources").glob("*.json")).read_text())
        self.assertFalse(source["active"])
        self.assertIsNone(source["agents"][0]["request"])

    def test_old_progress_does_not_replace_newer_evidence(self):
        a = agent("custom:one", "custom:one", "Example", "Custom")
        a.update(evidence="New result", lastProgress=time.time(), trajectory="onCourse")
        atomic_json(self.root / "progress/old.json", {"agentId": a["id"], "at": time.time() - 500,
                    "evidence": "Old result", "trajectory": "atRisk", "nextStep": "Old next"})
        feed = merge_feed([], [a], self.root)
        self.assertEqual(feed["agents"][0]["evidence"], "New result")
        self.assertEqual(feed["agents"][0]["trajectory"], "onCourse")

    def test_malformed_registry_entry_does_not_disable_valid_harness(self):
        atomic_json(self.root / "harnesses.json", {"harnesses": [{"id": []}, {"id": "codex", "enabled": False},
                    {"id": "bad-format", "name": "Bad format", "logs": ["/tmp/unused"], "format": []}]})
        registry = Registry(self.root / "home", self.root)
        self.assertTrue(registry.warnings)
        self.assertFalse(next(h for h in registry.definitions if h["id"] == "codex")["enabled"])

    def test_invalid_sources_are_contained_and_valid_sources_survive(self):
        atomic_json(self.root / "sources/array.json", [])
        a = agent("custom:one", "custom:one", "Example", "Custom")
        invalid = dict(a); invalid.pop("missionId")
        overflow = dict(a, lastActivity=10**1000)
        atomic_json(self.root / "sources/mixed.json", {"agents": [invalid, overflow, a], "generatedAt": time.time()})
        watch(SimpleNamespace(state=str(self.state), home=str(self.root / "home"), project=None, once=True, owner_pid=0))
        feed = json.loads(self.state.read_text())
        self.assertEqual([a["id"] for a in feed["agents"]], ["custom:one"])
        self.assertGreaterEqual(len(feed["warnings"]), 2)

    def test_antigravity_clears_only_the_matching_completed_interaction(self):
        path = self.root / "brain/one/.system_generated/logs/transcript.jsonl"
        path.parent.mkdir(parents=True); path.touch()
        session = Session(path, "Antigravity")
        session.consume({"type": "ASK_USER", "status": "RUNNING", "id": "a"})
        session.consume({"type": "ASK_USER", "status": "DONE", "id": "b"})
        self.assertIsNotNone(session.value["request"])
        session.consume({"type": "ASK_USER", "status": "DONE", "id": "a"})
        self.assertIsNone(session.value["request"])
        session.consume({"type": "PLANNER_RESPONSE", "status": "DONE", "content": "Proceeding"})
        self.assertIsNone(session.value["request"])
        session.consume({"type": "ASK_USER", "status": "RUNNING"})
        session.consume({"type": "ASK_PERMISSION", "status": "DONE"})
        self.assertIsNotNone(session.value["request"])
        session.consume({"type": "ASK_USER", "status": "DONE"})
        self.assertIsNone(session.value["request"])

    def test_equal_size_and_larger_replacement_reset_session_identity(self):
        path = self.root / "events.jsonl"
        def row(sid): return json.dumps({"type": "session_meta", "payload": {"id": sid, "cwd": "/project"}}) + "\n"
        path.write_text(row("old")); session = Session(path, "Codex"); session.refresh()
        for contents in [row("new"), row("third-longer")]:
            replacement = self.root / "replacement.jsonl"; replacement.write_text(contents); replacement.replace(path)
            session.refresh()
            self.assertEqual(session.value["sessionId"], "new" if contents == row("new") else "third-longer")

    def test_legacy_report_rejects_a_changed_definition_without_overwriting_it(self):
        demo = Demo().feed(self.root); atomic_json(self.state, demo)
        latest = copy.deepcopy(demo["missions"][0]); latest.update(goal="Changed goal", definitionRevision=1)
        path = self.root / "missions" / mission_filename(latest["id"]); atomic_json(path, latest)
        with self.assertRaises(SystemExit):
            checkpoint(SimpleNamespace(state=str(self.state), agent="demo-bridge", checkpoint="bridge", evidence="Old-goal evidence", next="Review", trajectory="onCourse"))
        self.assertEqual(json.loads(path.read_text()), latest)
        self.assertFalse((self.root / "progress").exists())


if __name__ == "__main__": unittest.main()
