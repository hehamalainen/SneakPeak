from __future__ import annotations
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bridge"))
from observer import Observer, Session
from peek import merge_feed


class AntigravityReviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.project = self.root / "project"
        self.project.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def log(self, sid, rows):
        path = self.home / ".gemini/antigravity/brain" / sid / ".system_generated/logs/transcript.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps({"created_at": time.time(), **r}) + "\n" for r in rows))
        return path

    def session(self):
        return Session(self.log(str(uuid.uuid4()), []), "Antigravity")

    def tool(self, cwd=None, **args):
        if cwd is not None:
            args["Cwd"] = cwd
        return {"type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [{"name": "run_command", "args": args}]}

    def created(self, child):
        return {"type": "INVOKE_SUBAGENT", "status": "DONE", "content": "Created the following subagents:\n" + json.dumps({"conversationId": child, "logAbsoluteUri": "file:///untrusted/path"})}

    def test_tool_arguments_supply_workspace_and_meaningful_summary(self):
        s = self.session()
        s.consume(self.tool(str(self.project), toolAction="Running the test suite", toolSummary="Execute tests", CommandLine="PRIVATE COMMAND"))
        self.assertEqual(s.cwd, str(self.project))
        self.assertEqual(s.mission["workspace"], str(self.project))
        self.assertEqual(s.value["status"], "working")
        self.assertEqual(s.value["summary"], "Running the test suite")
        s.consume({"type": "RUN_COMMAND", "status": "RUNNING", "content": "PRIVATE OUTPUT"})
        self.assertEqual(s.value["summary"], "Running the test suite")
        s.consume({"type": "PLANNER_RESPONSE", "status": "DONE", "content": "", "thinking": "PRIVATE REASONING"})
        self.assertEqual(s.value["summary"], "Running the test suite")
        self.assertNotIn("PRIVATE", json.dumps(s.value))

    def test_workspace_anchor_does_not_follow_every_command_or_arbitrary_file(self):
        s = self.session()
        s.consume({"type": "PLANNER_RESPONSE", "tool_calls": [{"name": "view_file", "args": {"AbsolutePath": str(self.project / "file.txt")}}]})
        self.assertEqual(s.cwd, "")
        s.consume(self.tool("relative/path"))
        self.assertEqual(s.cwd, "")
        s.consume({"type": "USER_INPUT", "content": "Goal", "workspacePaths": [str(self.project)]})
        s.consume(self.tool("/tmp/other-project"))
        self.assertEqual(s.cwd, str(self.project))

    def test_planner_done_does_not_finish_loop_and_stop_requires_explicit_idle(self):
        s = self.session()
        s.consume({"type": "PLANNER_RESPONSE", "status": "DONE", "content": "Public checkpoint"})
        self.assertEqual(s.value["status"], "observed")
        s.consume(self.tool(str(self.project), toolSummary="Continuing work"))
        self.assertEqual(s.value["status"], "working")
        s.consume({"type": "STOP", "status": "DONE"})
        self.assertEqual(s.value["status"], "observed")
        s.consume({"type": "STOP", "status": "DONE", "fullyIdle": False})
        self.assertEqual(s.value["status"], "working")
        s.consume({"type": "STOP", "status": "DONE", "fullyIdle": True})
        self.assertEqual(s.value["status"], "done")
        self.assertEqual(s.value["trajectory"], "unknown")
        s.consume({"type": "STOP", "status": "ERROR", "fullyIdle": True})
        self.assertEqual(s.value["status"], "attention")

    def test_tool_update_does_not_clear_a_pending_question(self):
        s = self.session()
        s.consume({"type": "ASK_USER", "status": "RUNNING", "id": "question"})
        pending = s.value["request"]["id"]
        s.consume(self.tool(str(self.project), toolAction="Other tool work"))
        self.assertEqual(s.value["status"], "attention")
        self.assertEqual(s.value["request"]["id"], pending)

    def test_scoped_observer_links_reported_nested_children_and_preserves_parent_goal(self):
        parent, child, grandchild = [str(uuid.uuid4()) for _ in range(3)]
        self.log(parent, [{"type": "USER_INPUT", "content": "Parent mission"}, self.tool(str(self.project)), self.created(child)])
        self.log(child, [{"type": "USER_INPUT", "content": "Child task"}, self.created(grandchild)])
        self.log(grandchild, [{"type": "USER_INPUT", "content": "Grandchild task"}])
        observer = Observer(self.home, str(self.project), self.root)
        missions, agents = observer.refresh()
        self.assertEqual(len(missions), 1)
        self.assertEqual(missions[0]["goal"], "Parent mission")
        self.assertEqual(len(agents), 3)
        self.assertEqual({a["missionId"] for a in agents}, {"antigravity:" + parent})
        self.assertEqual({a["workspace"] for a in agents}, {str(self.project)})

    def test_unknown_workspace_exclusion_is_explained_and_bad_shapes_are_ignored(self):
        self.log(str(uuid.uuid4()), [{"type": "USER_INPUT", "content": "Unknown scope"}, {"type": "PLANNER_RESPONSE", "tool_calls": [{"name": "run_command", "args": []}, None]}])
        observer = Observer(self.home, str(self.project), self.root)
        missions, agents = observer.refresh()
        self.assertEqual((missions, agents), ([], []))
        feed = merge_feed(missions, agents, self.root, observer.catalog, project=self.project)
        ant = next(c for c in feed["harnesses"] if c["id"] == "antigravity")
        self.assertIn("lack a reported workspace", ant["detail"])
        self.assertTrue(any("project coverage is incomplete" in w for w in feed["warnings"]))

    def test_partial_unknown_scope_warning_survives_ready_status_and_repeated_refresh(self):
        self.log(str(uuid.uuid4()), [self.tool(str(self.project))])
        self.log(str(uuid.uuid4()), [{"type": "USER_INPUT", "content": "Unknown workspace"}])
        observer = Observer(self.home, str(self.project), self.root)
        for _ in range(2):
            missions, agents = observer.refresh()
            feed = merge_feed(missions, agents, self.root, observer.catalog, project=self.project)
            ant = next(c for c in feed["harnesses"] if c["id"] == "antigravity")
            self.assertEqual(ant["sessionCount"], 1)
            self.assertEqual(ant["unscopedSessions"], 1)
            self.assertEqual(ant["detail"].count("lack a reported workspace"), 1)
            self.assertTrue(any("project coverage is incomplete" in w for w in feed["warnings"]))

    def test_conflicting_parent_claims_do_not_select_an_arbitrary_owner(self):
        p1, p2, child = [str(uuid.uuid4()) for _ in range(3)]
        for parent in (p1, p2):
            self.log(parent, [self.tool(str(self.project)), self.created(child)])
        self.log(child, [self.tool(str(self.project))])
        missions, agents = Observer(self.home, str(self.project), self.root).refresh()
        self.assertEqual(len(missions), 3)
        c = next(a for a in agents if a["sessionId"] == child)
        self.assertEqual(c["missionId"], "antigravity:" + child)

    def test_rotation_discards_old_workspace_and_child_links(self):
        path = self.log(str(uuid.uuid4()), [self.tool(str(self.project)), self.created(str(uuid.uuid4()))])
        s = Session(path, "Antigravity"); s.refresh()
        self.assertTrue(s.antigravity_children)
        path.write_text(json.dumps({"type": "USER_INPUT", "content": "New session"}) + "\n")
        s.refresh()
        self.assertEqual(s.cwd, "")
        self.assertFalse(s.antigravity_children)


if __name__ == "__main__":
    unittest.main()
