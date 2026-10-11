from __future__ import annotations
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bridge"))
from common import atomic_json, read_decision, request
from observer import Observer, Session
from peek import Demo, checkpoint, merge_feed, mission_filename
from claude_hook import handle
from codex_runner import CodexBridge
from antigravity_hook import handle as handle_antigravity


def reply(directory, pending, agent_id, choice="accept", **overrides):
    value = {"requestId": pending["id"], "agentId": agent_id, "choiceId": choice, "createdAt": time.time()}
    value.update(overrides)
    atomic_json(directory / "decisions" / (pending["id"] + ".json"), value)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.state = self.directory / "state.json"
        atomic_json(self.directory / "approval-surface.json", {"generatedAt": time.time(), "live": True,
                    "statePath": str(self.state.resolve()), "provider": "All sources"})

    def tearDown(self):
        self.temporary.cleanup()

    def test_decision_is_scoped_and_expired_replies_never_grant(self):
        pending = request("Permission", "Exact command")
        reply(self.directory, pending, "other-agent")
        self.assertIsNone(read_decision(self.directory / "decisions", pending, "agent-a"))
        reply(self.directory, pending, "agent-a", choice="invented-choice")
        self.assertIsNone(read_decision(self.directory / "decisions", pending, "agent-a"))
        reply(self.directory, pending, "agent-a")
        self.assertEqual(read_decision(self.directory / "decisions", pending, "agent-a"), "accept")
        pending["expiresAt"] = time.time() - 1
        self.assertIsNone(read_decision(self.directory / "decisions", pending, "agent-a"))

    def test_codex_team_and_partial_log_record(self):
        path = self.directory / "agent.jsonl"
        rows = [
            {"type": "session_meta", "payload": {"id": "child", "cwd": "/project", "source": {"subagent": {"thread_spawn": {"parent_thread_id": "parent", "agent_nickname": "Validator"}}}}},
            {"type": "event_msg", "payload": {"type": "task_started"}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "phase": "analysis", "content": [{"type": "output_text", "text": "PRIVATE REASONING"}]}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "phase": "commentary", "content": [{"type": "output_text", "text": "Checking the return path"}]}},
        ]
        path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        session = Session(path, "Codex")
        session.refresh()
        self.assertEqual(session.value["missionId"], "codex:parent")
        self.assertEqual(session.value["name"], "Validator")
        self.assertEqual(session.value["summary"], "Checking the return path")
        self.assertEqual(session.value["trajectory"], "unknown")
        complete = json.dumps({"type": "event_msg", "payload": {"type": "task_complete", "last_agent_message": "Ready for review"}})
        with path.open("a") as stream:
            stream.write(complete[:20])
        session.refresh()
        self.assertEqual(session.value["status"], "working")
        with path.open("a") as stream:
            stream.write(complete[20:] + "\n")
        session.refresh()
        self.assertEqual(session.value["status"], "done")
        self.assertEqual(session.value["lastProgress"], 0)

    def test_claude_question_clears_on_tool_answer(self):
        path = self.directory / "claude.jsonl"
        path.touch()
        session = Session(path, "Claude")
        session.consume({"type": "user", "sessionId": "c1", "cwd": "/project", "message": {"content": "Build the monitor"}})
        session.consume({"type": "assistant", "sessionId": "c1", "message": {"content": [{"type": "thinking", "thinking": "hidden"}, {"type": "tool_use", "name": "AskUserQuestion"}]}})
        self.assertEqual(session.value["status"], "attention")
        self.assertEqual(session.value["request"]["mode"], "handoff")
        session.consume({"type": "user", "message": {"content": [{"type": "tool_result", "content": "yes"}]}})
        self.assertIsNone(session.value["request"])
        self.assertEqual(session.value["status"], "working")

    def test_nested_team_lands_under_the_root_mission(self):
        home = self.directory / "home"
        logs = home / ".codex/sessions"
        logs.mkdir(parents=True)
        for sid, parent in [("root", None), ("child", "root"), ("grandchild", "child")]:
            source = "cli" if not parent else {"subagent": {"thread_spawn": {"parent_thread_id": parent}}}
            row = {"type": "session_meta", "payload": {"id": sid, "cwd": "/project", "source": source}}
            (logs / (sid + ".jsonl")).write_text(json.dumps(row) + "\n")
        missions, agents = Observer(home).refresh()
        self.assertEqual(len(missions), 1)
        self.assertEqual({a["missionId"] for a in agents}, {"codex:root"})

    def test_antigravity_public_update_is_not_mission_completion(self):
        path = self.directory / "brain" / "conversation-a" / ".system_generated/logs/transcript.jsonl"
        path.parent.mkdir(parents=True)
        rows = [
            {"type": "USER_INPUT", "status": "DONE", "content": "<USER_REQUEST>Build a calm monitor</USER_REQUEST><ADDITIONAL_METADATA>not the goal</ADDITIONAL_METADATA>"},
            {"type": "PLANNER_RESPONSE", "status": "DONE", "content": "The public checkpoint is ready", "thinking": "PRIVATE REASONING"},
        ]
        path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        session = Session(path, "Antigravity")
        session.refresh()
        self.assertEqual(session.mission["goal"], "Build a calm monitor")
        self.assertEqual(session.value["summary"], "The public checkpoint is ready")
        self.assertEqual(session.value["status"], "observed")
        self.assertEqual(session.value["trajectory"], "unknown")
        self.assertEqual(session.value["sessionId"], "conversation-a")

    def test_antigravity_stop_is_finished_only_when_background_work_is_idle(self):
        base = {"conversationId": "conversation-a", "workspacePaths": ["/project"], "terminationReason": "model_stop"}
        result = handle_antigravity({**base, "fullyIdle": False}, self.state, "Stop")
        self.assertEqual(result, {"decision": "allow"})
        path = next((self.directory / "sources").glob("*.json"))
        self.assertEqual(json.loads(path.read_text())["agents"][0]["status"], "working")
        handle_antigravity({**base, "fullyIdle": True}, self.state, "Stop")
        self.assertEqual(json.loads(path.read_text())["agents"][0]["status"], "done")
        handle_antigravity({**base, "fullyIdle": True, "error": "Host error"}, self.state, "Stop")
        self.assertEqual(json.loads(path.read_text())["agents"][0]["status"], "attention")

    def test_antigravity_observer_hooks_do_not_override_permissions(self):
        event = {"conversationId": "conversation-a", "workspacePaths": ["/project"], "toolCall": {"name": "run_command", "args": {"CommandLine": "npm test"}}}
        result = handle_antigravity(event, self.state, "PostToolUse")
        self.assertEqual(result, {})
        self.assertNotIn("permissionOverrides", result)
        self.assertNotIn("injectSteps", result)

    def test_disconnected_source_does_not_offer_inline_approval(self):
        demo = Demo().feed(self.directory)
        demo["demo"] = False
        demo["generatedAt"] = time.time() - 100
        atomic_json(self.directory / "sources" / "offline.json", demo)
        result = merge_feed([], [], self.directory)
        waiting = next(a for a in result["agents"] if a["id"] == "demo-validation")
        self.assertIsNone(waiting["request"])
        self.assertEqual(waiting["status"], "attention")

    def test_progress_overlay_preserves_fresh_observed_activity(self):
        demo = Demo().feed(self.directory)
        a = demo["agents"][1]
        atomic_json(self.directory / "progress" / "check.json", {"agentId": a["id"], "evidence": "Test suite passed", "at": time.time() + 1, "trajectory": "onCourse", "nextStep": "Review the flow"})
        result = merge_feed(demo["missions"], [a], self.directory)
        observed = result["agents"][0]
        self.assertEqual(observed["status"], "working")
        self.assertEqual(observed["lastActivity"], a["lastActivity"])
        self.assertEqual(observed["evidence"], "Test suite passed")

    def test_human_mission_checks_survive_live_refresh(self):
        demo = Demo().feed(self.directory)
        mission = demo["missions"][0]
        mission["goal"] = "My explicit destination"
        atomic_json(self.directory / "missions" / mission_filename(mission["id"]), mission)
        result = merge_feed([], demo["agents"], self.directory)
        # A mission must have a source before an override can be applied.
        result = merge_feed(demo["missions"], demo["agents"], self.directory)
        self.assertEqual(result["missions"][0]["goal"], "My explicit destination")

    def test_back_to_back_landing_reports_preserve_both_checks(self):
        demo = Demo().feed(self.directory)
        atomic_json(self.state, demo)
        for check_id in ["bridge", "decision"]:
            checkpoint(SimpleNamespace(state=str(self.state), agent="demo-bridge", checkpoint=check_id,
                                       evidence="Evidence for " + check_id, next="Review", trajectory="onCourse"))
        mission = json.loads((self.directory / "missions" / mission_filename("demo-mission")).read_text())
        checks = {c["id"]: c for c in mission["checkpoints"]}
        self.assertEqual(checks["bridge"]["evidence"], "Evidence for bridge")
        self.assertEqual(checks["decision"]["evidence"], "Evidence for decision")
        self.assertEqual(checks["glance"]["status"], "verified")

    def test_demo_reply_reaches_waiting_agent(self):
        demo = Demo()
        reply(self.directory, demo.pending, "demo-validation")
        feed = demo.feed(self.directory)
        validation = feed["agents"][0]
        self.assertIsNone(validation["request"])
        self.assertEqual(validation["status"], "done")
        self.assertIn("reached", validation["evidence"])

    def test_claude_hook_round_trip_without_any_model_call(self):
        atomic_json(self.state, {"generatedAt": time.time(), "missions": [], "agents": []})
        result = []
        worker = threading.Thread(target=lambda: result.append(handle({"hook_event_name": "PermissionRequest", "session_id": "c1", "cwd": "/project", "tool_name": "Bash", "tool_input": {"command": "python3 -m unittest"}}, self.state, timeout=3)))
        worker.start()
        until = time.time() + 2
        source = None
        while time.time() < until:
            paths = list((self.directory / "sources").glob("*.json"))
            if paths:
                source = json.loads(paths[0].read_text())
                break
            time.sleep(0.02)
        self.assertIsNotNone(source)
        a = source["agents"][0]
        self.assertIn("python3 -m unittest", a["request"]["detail"])
        reply(self.directory, a["request"], a["id"])
        worker.join(timeout=4)
        self.assertFalse(worker.is_alive())
        decision = result[0]["hookSpecificOutput"]["decision"]
        self.assertEqual(decision, {"behavior": "allow"})
        self.assertNotIn("updatedPermissions", decision)

    def test_claude_hook_offline_falls_back_to_original_permission_ui(self):
        self.assertEqual(handle({"hook_event_name": "PermissionRequest"}, self.state), {})

    def test_codex_rpc_decision_waits_for_host_acknowledgement(self):
        sent = []
        bridge = CodexBridge(self.directory, "Build monitor", "/project", sent.append)
        bridge.setup({"id": "thread-a"})
        bridge.receive({"id": 81, "method": "item/commandExecution/requestApproval", "params": {"threadId": "different-thread", "command": "ignored"}})
        self.assertFalse(bridge.pending)
        bridge.receive({"id": 82, "method": "item/commandExecution/requestApproval", "params": {"threadId": "thread-a", "itemId": "cmd-a", "command": "python3 -m unittest"}})
        pending = bridge.value["request"]
        reply(self.directory, pending, bridge.value["id"], "decline")
        bridge.tick()
        self.assertEqual(sent, [{"id": 82, "result": {"decision": "decline"}}])
        self.assertIsNotNone(bridge.value["request"])
        bridge.tick()
        self.assertEqual(len(sent), 1)
        bridge.receive({"method": "serverRequest/resolved", "params": {"threadId": "thread-a", "requestId": 82}})
        self.assertIsNone(bridge.value["request"])

    def test_codex_expiry_cancels_instead_of_allowing(self):
        sent = []
        bridge = CodexBridge(self.directory, "Goal", "/project", sent.append)
        bridge.setup({"id": "thread-a"})
        bridge.receive({"id": 9, "method": "item/fileChange/requestApproval", "params": {"threadId": "thread-a"}})
        bridge.value["request"]["expiresAt"] = time.time() - 1
        bridge.tick()
        self.assertEqual(sent[0]["result"]["decision"], "cancel")

    def test_full_codex_process_round_trip_uses_default_permissions(self):
        atomic_json(self.state, {"generatedAt": time.time(), "missions": [], "agents": []})
        mock = self.directory / "mock-codex"
        transcript = self.directory / "rpc-transcript.jsonl"
        mock.write_text('''#!/usr/bin/env python3
import json, sys
def send(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    value = json.loads(line)
    with open(TRANSCRIPT, 'a') as stream:
        stream.write(json.dumps(value) + '\\n')
    if value.get('method') == 'initialize':
        send({'id': 1, 'result': {}})
    elif value.get('method') == 'thread/start':
        send({'id': 2, 'result': {'thread': {'id': 'mock-thread'}}})
    elif value.get('method') == 'turn/start':
        send({'id': 3, 'result': {'turn': {'id': 'turn-a'}}})
        send({'id': 44, 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'mock-thread', 'turnId': 'turn-a', 'itemId': 'cmd-a', 'command': 'python3 -m unittest', 'availableDecisions': ['accept', 'decline']}})
    elif value.get('id') == 44:
        send({'method': 'serverRequest/resolved', 'params': {'threadId': 'mock-thread', 'requestId': 44}})
        send({'method': 'turn/completed', 'params': {'threadId': 'mock-thread', 'turn': {'id': 'turn-a', 'status': 'completed'}}})
'''.replace("TRANSCRIPT", repr(str(transcript))))
        mock.chmod(0o700)
        runner = Path(__file__).resolve().parents[1] / "bridge/codex_runner.py"
        process = subprocess.Popen([sys.executable, str(runner), "--state", str(self.state), "--project", str(self.directory), "--goal", "A safe test mission", "--codex", str(mock)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            pending = None
            until = time.time() + 5
            while time.time() < until:
                for path in (self.directory / "sources").glob("*.json"):
                    feed = json.loads(path.read_text())
                    a = feed["agents"][0]
                    if a.get("request"):
                        pending = a["request"]
                        reply(self.directory, pending, a["id"])
                        break
                if pending:
                    break
                time.sleep(0.03)
            self.assertIsNotNone(pending)
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, stderr)
            messages = [json.loads(line) for line in transcript.read_text().splitlines()]
            thread_start = next(m for m in messages if m.get("method") == "thread/start")
            self.assertEqual(thread_start["params"], {"cwd": str(self.directory.resolve())})
            answer = next(m for m in messages if m.get("id") == 44)
            self.assertEqual(answer["result"], {"decision": "accept"})
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()
