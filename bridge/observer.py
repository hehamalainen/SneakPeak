"""Best-effort local session observation. Log formats are not a stable API."""
from __future__ import annotations
from datetime import datetime
import json
import os
from pathlib import Path
import re
import time
from common import agent, short, text_content, request
from harnesses import Registry


def timestamp(value) -> float:
    try:
        if isinstance(value, (int, float)):
            return value / 1000 if value > 100_000_000_000 else float(value)
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return time.time()


class Session:
    def __init__(self, path: Path, provider: str, namespace: str | None = None, parser: str | None = None):
        self.path, self.provider, self.offset = path, provider, 0
        self.namespace = namespace or ("copilot" if provider == "GitHub Copilot" else provider.lower())
        self.parser = parser or {"Codex": "codex", "Claude": "claude", "GitHub Copilot": "copilot", "Antigravity": "antigravity"}.get(provider, "sneakpeek")
        self.value = None
        self.mission = None
        self.cwd = ""
        self.pending_call = None
        self.has_goal = False
        self.parent_id = None
        self.children = {}
        self.copilot_requests = {}
        self.final_turn = None
        self.file_identity = None
        self.antigravity_request_id = None

    def initialize(self, session_id: str, cwd: str, parent: str | None = None, name: str | None = None):
        self.cwd = cwd
        self.parent_id = self.namespace + ":" + parent if parent else None
        mid = self.namespace + ":" + (parent or session_id)
        self.value = agent(self.namespace + ":" + session_id, mid,
                           name or f"{self.provider} · {Path(cwd).name or 'Session'}", self.provider)
        self.value["sessionId"] = session_id
        self.value["lastActivity"] = self.path.stat().st_mtime
        self.mission = {"id": mid, "title": Path(cwd).name or "Untitled mission",
                        "goal": "Define the outcome this session should deliver", "goalOrigin": "unset", "checkpoints": []}

    def consume(self, row: dict):
        now = timestamp(row.get("timestamp"))
        if self.parser == "codex":
            self.codex(row, now)
        elif self.parser == "claude":
            self.claude(row, now)
        elif self.parser == "antigravity":
            self.antigravity(row, timestamp(row.get("created_at", row.get("timestamp"))))
        elif self.parser == "copilot":
            self.copilot(row, now)
        else:
            self.generic(row, now)

    def goal(self, text: str):
        if text and not self.has_goal and not text.startswith(("<environment_context>", "<external_codex")):
            self.mission["goal"] = short(text, 600)
            self.mission["goalOrigin"] = "first-prompt"
            self.has_goal = True

    def codex(self, row: dict, now: float):
        p = row.get("payload", {})
        if not isinstance(p, dict):
            return
        if row.get("type") == "session_meta":
            source = p.get("source", {})
            spawn = source.get("subagent", {}).get("thread_spawn", {}) if isinstance(source, dict) else {}
            self.initialize(p.get("id", self.path.stem), p.get("cwd", ""),
                            spawn.get("parent_thread_id"), spawn.get("agent_nickname"))
        if self.value is None:
            return
        a = self.value
        if row.get("type") == "event_msg":
            kind = p.get("type")
            if kind == "task_started":
                a.update(status="working", request=None, lastActivity=now)
            elif kind == "user_message":
                self.goal(p.get("message", ""))
                a.update(status="working", request=None, lastActivity=now)
            elif kind == "agent_message":
                a.update(summary=short(p.get("message", "")), lastActivity=now)
            elif kind == "task_complete":
                a.update(status="done", request=None, lastActivity=now,
                         summary=short(p.get("last_agent_message") or "Turn finished. Review the result."))
            elif kind in {"turn_aborted", "task_failed"}:
                a.update(status="attention", request=None, lastActivity=now, summary="Turn stopped. Check the session.")
            return
        if row.get("type") != "response_item":
            return
        kind = p.get("type")
        # Explicitly ignore reasoning items and hidden analysis channels.
        if kind == "reasoning":
            a["lastActivity"] = now  # Timing only; no reasoning text is consumed.
        if kind == "message":
            text = text_content(p.get("content"))
            if p.get("role") == "user":
                self.goal(text)
                a.update(request=None, status="working", lastActivity=now)
            elif p.get("role") == "assistant" and p.get("phase") in {"commentary", "final_answer"}:
                a.update(summary=short(text), lastActivity=now)
                if p.get("phase") == "final_answer":
                    a.update(status="done", request=None)
        elif kind in {"function_call", "custom_tool_call"}:
            a["lastActivity"] = now
            name = p.get("name", "")
            if "request_user_input" in name or "requestUserInput" in name:
                a.update(status="attention", summary="A question is waiting in this session",
                         request=request("Your answer is needed", "Open the session to answer the agent's question.", mode="handoff", ttl=86400))
                self.pending_call = p.get("call_id")
            elif a["request"] is None:
                a["status"] = "working"
        elif kind in {"function_call_output", "custom_tool_call_output"}:
            a["lastActivity"] = now
            # Async question tool outputs only acknowledge delivery, not a human answer.

    def claude(self, row: dict, now: float):
        if self.value is None and row.get("sessionId"):
            is_subagent = self.path.parent.name == "subagents"
            parent = self.path.parent.parent.name if is_subagent else None
            sid = self.path.stem if is_subagent else row["sessionId"]
            self.initialize(sid, row.get("cwd", ""), parent,
                            "Claude · " + self.path.stem if is_subagent else None)
        if self.value is None:
            return
        a = self.value
        kind = row.get("type")
        message = row.get("message", {})
        content = message.get("content", []) if isinstance(message, dict) else []
        if kind == "user" and text_content(content):
            self.goal(text_content(content))
            a.update(status="working", request=None, lastActivity=now)
        elif kind == "assistant":
            text = short(text_content(content))
            if text:
                a["summary"] = text
            a["lastActivity"] = now
            if row.get("isApiErrorMessage"):
                a.update(status="attention", summary=text or "Session error. Check the source.")
            elif message.get("stop_reason") == "end_turn":
                a.update(status="done", request=None)
            else:
                a["status"] = "working"
            for block in content if isinstance(content, list) else []:
                if block.get("type") == "tool_use" and block.get("name") == "AskUserQuestion":
                    a.update(status="attention", request=request("Claude has a question", "Answer in the original session.", mode="handoff", ttl=86400))
        elif kind == "user" and isinstance(content, list):
            if any(c.get("type") == "tool_result" for c in content):
                a.update(status="working", request=None, lastActivity=now)
        elif kind == "system" and row.get("subtype") == "turn_duration":
            a.update(status="done", request=None, lastActivity=now)

    def antigravity(self, row: dict, now: float):
        if self.value is None:
            sid = self.path.parent.parent.parent.name
            self.initialize(sid, "", name="Antigravity · " + sid[:8])
            self.value["sourceApp"] = "Antigravity IDE" if "antigravity-ide" in self.path.parts else "Antigravity CLI" if "antigravity-cli" in self.path.parts else "Antigravity"
            self.value["artifactPath"] = str(self.path.parent.parent.parent)
            self.mission["title"] = "Antigravity · " + sid[:8]
        a = self.value
        kind = row.get("type", "")
        status = row.get("status", "")
        a["lastActivity"] = now
        if kind == "USER_INPUT":
            content = row.get("content", "")
            match = re.search(r"<USER_REQUEST>(.*?)</USER_REQUEST>", content, re.S)
            text = match.group(1).strip() if match else content
            self.goal(text)
            if self.has_goal:
                self.mission["title"] = short(self.mission["goal"], 48)
            a.update(status="working", request=None, summary="Working toward the requested outcome")
        elif kind == "PLANNER_RESPONSE":
            # The public transcript may contain a separate `thinking` field. Never read it.
            a.update(summary=short(row.get("content", "")) or "An agent update was observed",
                     status="working" if status == "RUNNING" else "observed")
        elif kind in {"ASK_QUESTION", "ASK_PERMISSION", "ASK_USER"}:
            interaction_id = row.get("id") or row.get("step_id")
            if status == "DONE":
                if (kind, interaction_id) == self.antigravity_request_id:
                    a.update(status="observed", request=None)
                    self.antigravity_request_id = None
            else:
                self.antigravity_request_id = (kind, interaction_id)
                a.update(status="attention", request=request("Antigravity needs your input", "An interaction step was observed. Open the source session to review and answer it.", mode="handoff", ttl=86400))
        elif kind == "ERROR_MESSAGE" or status == "ERROR":
            a.update(status="attention", summary="Antigravity reported an error. Check the session.")
        elif status == "RUNNING":
            a.update(status="working", summary="The agent is running a step")
        elif kind not in {"SYSTEM_MESSAGE", "EPHEMERAL_MESSAGE", "CONVERSATION_HISTORY", "CHECKPOINT", "KNOWLEDGE_ARTIFACTS"}:
            a["status"] = "observed"

    def copilot(self, row: dict, now: float, embedded=False):
        data = row.get("data", {})
        if not isinstance(data, dict):
            return
        kind = row.get("type", "")
        if self.value is None:
            sid = data.get("sessionId") or self.path.parent.name
            cwd = data.get("context", {}).get("cwd", "")
            self.initialize(sid, cwd)
            self.value["sourceApp"] = "GitHub Copilot"
        if not embedded and row.get("agentId"):
            cid = str(row["agentId"])
            child = self.children.get(cid)
            if child is None:
                child = Session(self.path, self.provider, self.namespace, "copilot")
                sid = self.value["sessionId"]
                child.initialize(sid + ":" + cid, self.cwd, parent=sid, name=data.get("agentDisplayName") or "Copilot · subagent")
                child.value["sessionId"] = sid  # Handoff resumes the root conversation.
                child.value["sourceApp"] = "GitHub Copilot"
                self.children[cid] = child
            child.copilot(row, now, embedded=True)
            return
        a = self.value
        if kind in {"session.start", "session.resume", "session.context_changed"}:
            cwd = data.get("context", {}).get("cwd") or data.get("cwd")
            if cwd:
                self.cwd = cwd
                self.mission["title"] = Path(cwd).name
                a["name"] = f"{self.provider} · {Path(cwd).name}"
            a["lastActivity"] = now
        elif kind == "user.message":
            self.goal(text_content(data.get("content")))
            a.update(status="working", request=None, lastActivity=now)
            self.copilot_requests.clear()
        elif kind == "assistant.turn_start":
            self.final_turn = None
            a.update(status="working", lastActivity=now)
        elif kind == "assistant.message":
            # Only public content; reasoningText, reasoningBlocks and encryptedContent are ignored.
            if data.get("phase") not in {"analysis", "reasoning"}:
                text = text_content(data.get("content"))
                if text:
                    a.update(summary=short(text), lastActivity=now)
                if data.get("phase") == "final_answer":
                    self.final_turn = data.get("turnId")
        elif kind in {"assistant.reasoning", "assistant.reasoning_delta"}:
            a["lastActivity"] = now
        elif kind in {"permission.requested", "user_input.requested", "elicitation.requested"}:
            rid = str(data.get("requestId", row.get("id", "request")))
            detail = ("Review this request in the original Copilot session.\n\n" +
                      (json.dumps(data.get("permissionRequest", {}), indent=2) if kind == "permission.requested" else str(data.get("question") or data.get("message") or "Your input is needed.")))
            pending = self.copilot_requests.setdefault(rid, request("Copilot needs your decision" if kind == "permission.requested" else "Copilot has a question", detail, mode="handoff", ttl=86400))
            a.update(status="attention", request=pending, summary="A request is waiting in Copilot", lastActivity=now)
        elif kind in {"permission.completed", "user_input.completed", "elicitation.completed"}:
            rid = str(data.get("requestId", ""))
            owner = next((s for s in [self, *self.children.values()] if rid in s.copilot_requests), None)
            if owner:
                owner.copilot_requests.pop(rid)
                pending = next(iter(owner.copilot_requests.values()), None)
                owner.value.update(request=pending, status="attention" if pending else "working", lastActivity=now)
        elif kind == "tool.execution_start":
            a.update(lastActivity=now)
            if not a["request"]:
                a["status"] = "working"
        elif kind == "tool.execution_complete":
            a["lastActivity"] = now
        elif kind == "assistant.turn_end":
            if not a["request"]:
                # A model turn can end before the agent's tool loop ends.
                a.update(status="done" if self.final_turn is not None and self.final_turn == data.get("turnId") else "observed", lastActivity=now)
        elif kind in {"session.idle", "session.task_complete"}:
            a.update(status="attention" if data.get("aborted") else "done", request=None, lastActivity=now)
            if data.get("summary"):
                a["summary"] = short(data["summary"])
        elif kind == "session.error":
            a.update(status="attention", request=None, summary=short(data.get("message", "Copilot reported an error")), lastActivity=now)
        elif kind == "session.shutdown":
            a.update(status="done" if a["status"] == "done" else "idle", request=None, lastActivity=now)
        elif kind in {"subagent.started", "subagent.completed", "subagent.failed"}:
            cid = "task:" + str(data.get("toolCallId", data.get("agentName", "subagent")))
            child = self.children.get(cid)
            if child is None:
                child = Session(self.path, self.provider, self.namespace, "copilot")
                sid = a["sessionId"]
                child.initialize(sid + ":" + cid, self.cwd, parent=sid, name=data.get("agentDisplayName") or "Copilot · subagent")
                child.value["sessionId"] = sid
                self.children[cid] = child
            child.value.update(status="working" if kind.endswith("started") else "attention" if kind.endswith("failed") else "done",
                               summary=short(data.get("agentDescription") or data.get("error") or "Subagent handoff ready"), lastActivity=now)

    def generic(self, row: dict, now: float, embedded=False):
        kind, sid = row.get("event"), row.get("session_id")
        if row.get("schema") != 1 or not isinstance(sid, str) or not sid or kind not in {"started", "activity", "progress", "needs_input", "resolved", "completed", "failed"}:
            return
        if not embedded and self.value is not None and sid != self.value["sessionId"]:
            child = self.children.setdefault(sid, Session(self.path, self.provider, self.namespace, "sneakpeek"))
            child.generic(row, now, embedded=True)
            return
        if self.value is None:
            self.initialize(sid, row.get("cwd", ""), parent=row.get("parent_session_id"), name=row.get("name"))
            self.value["handoffKind"] = "copy-id"
        a = self.value
        a["lastActivity"] = now
        if row.get("goal"):
            self.goal(row["goal"])
            self.mission["goalOrigin"] = "source-reported"
        if row.get("summary"):
            a["summary"] = short(row["summary"])
        if kind == "started":
            a.update(status="working", request=None)
        elif kind == "activity":
            if not a["request"]:
                a["status"] = "working"
        elif kind == "progress":
            evidence = row.get("evidence")
            if isinstance(evidence, str) and evidence.strip():
                a.update(evidence=short(evidence, 1000), lastProgress=now,
                         trajectory=row.get("trajectory") if row.get("trajectory") in {"unknown", "onCourse", "atRisk"} else "unknown")
            if row.get("next_step"):
                a["nextStep"] = short(row["next_step"])
        elif kind == "needs_input":
            a.update(status="attention", request=request(row.get("request_title") or "Your input is needed",
                     row.get("request_detail") or row.get("summary") or "Answer in the source session.", mode="handoff", ttl=86400))
        elif kind == "resolved":
            a.update(status="working", request=None)
        elif kind == "completed":
            a.update(status="done", request=None)
        elif kind == "failed":
            a.update(status="attention", request=None)

    def refresh(self):
        try:
            with self.path.open("rb") as stream:
                stat = os.fstat(stream.fileno())
                identity = (stat.st_dev, stat.st_ino)
                if identity != self.file_identity or stat.st_size < self.offset:
                    self.offset, self.value, self.has_goal = 0, None, False
                    self.mission, self.cwd, self.parent_id, self.pending_call = None, "", None, None
                    self.children.clear(); self.copilot_requests.clear(); self.final_turn = None
                    self.antigravity_request_id = None
                self.file_identity = identity
                stream.seek(self.offset)
                while line := stream.readline():
                    if not line.endswith(b"\n"):
                        break  # A writer may still be appending this record.
                    self.offset = stream.tell()
                    try:
                        self.consume(json.loads(line))
                    except (ValueError, KeyError, TypeError, AttributeError):
                        continue
        except OSError:
            pass


class Observer:
    def __init__(self, home: Path, project: str | None = None, directory: Path | None = None):
        self.home, self.project = home, Path(project).resolve() if project else None
        self.sessions = {}
        self.last_scan = 0
        self.registry = Registry(home, directory or home / ".sneakpeek")
        self.catalog = []

    def records(self):
        for session in self.sessions.values():
            yield session
            yield from session.children.values()

    def refresh(self):
        now = time.time()
        if now - self.last_scan > 8:
            self.last_scan = now
            self.registry.reload()
            self.catalog = []
            current = set()
            for definition in self.registry.definitions:
                files, catalog = self.registry.discover(definition)
                self.catalog.append(catalog)
                for path in files:
                    key = (definition["id"], path)
                    current.add(key)
                    if key not in self.sessions:
                        self.sessions[key] = Session(path, definition["provider"], definition["id"], definition["format"])
            self.sessions = {key: value for key, value in self.sessions.items() if key in current}
        missions, agents = {}, []
        for session in self.sessions.values():
            session.refresh()
        indexed = {s.value["id"]: s for s in self.records() if s.value}
        for session in self.records():
            if session.value is None:
                continue
            root = session
            visited = {session.value["id"]}
            while root.parent_id in indexed and root.parent_id not in visited:
                visited.add(root.parent_id)
                root = indexed[root.parent_id]
            scope_cwd = root.cwd or session.cwd
            if self.project and (not scope_cwd or not Path(scope_cwd).resolve().is_relative_to(self.project)):
                continue
            if now - session.value["lastActivity"] > self.registry.recent_hours * 3600:
                continue
            mid = root.mission["id"]
            # Parent session owns the mission goal when a team is observed.
            is_parent = session.value["id"] == mid
            if mid not in missions or is_parent:
                missions[mid] = root.mission
            value = dict(session.value)
            value["harnessId"] = session.namespace
            value["workspace"] = str(scope_cwd) if scope_cwd else ""
            value["missionId"] = mid
            agents.append(value)
        for catalog in self.catalog:
            catalog["sessionCount"] = sum(a.get("harnessId") == catalog["id"] for a in agents)
        return list(missions.values()), agents
