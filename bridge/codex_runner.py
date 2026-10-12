#!/usr/bin/env python3
"""Run a new Codex mission through app-server with scoped notch approvals.

This owns its child app-server. It does not attach to or mutate an existing UI's
server, and it does not change the user's configured approval policy.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
from common import default_state_path, agent, atomic_json, read_decision, request, short, approval_surface_available


class CodexBridge:
    APPROVALS = {"item/commandExecution/requestApproval", "item/fileChange/requestApproval"}

    def __init__(self, directory: Path, goal: str, cwd: str, send, *, trusted_local_inline=False):
        self.directory, self.goal, self.cwd, self.send = directory, goal, cwd, send
        self.trusted_local_inline = trusted_local_inline
        self.value = None
        self.mission = None
        self.pending = {}  # request UUID -> exact JSON-RPC request and agent
        self.error = None
        self.finished = False

    def setup(self, thread: dict):
        sid = thread["id"]
        aid = "codex:" + sid
        self.value = agent(aid, aid, "Codex · " + Path(self.cwd).name, "Codex")
        self.value.update(sessionId=sid, workspace=self.cwd, status="working", summary="Starting the mission")
        self.mission = {"id": aid, "title": Path(self.cwd).name, "goal": self.goal, "goalOrigin": "launch-argument", "checkpoints": []}

    def receive(self, message: dict):
        if self.value is None:
            return
        method = message.get("method", "")
        p = message.get("params", {})
        # Do not accept an approval for another thread through this single-mission runner.
        if p.get("threadId") and p["threadId"] != self.value["sessionId"]:
            return
        if method in self.APPROVALS and "id" in message:
            command = p.get("command")
            detail = "Project: " + p.get("cwd", self.cwd) + "\n"
            if p.get("networkApprovalContext"):
                detail += "Network request:\n" + json.dumps(p["networkApprovalContext"], indent=2)
            elif command:
                detail += "Command:\n" + command
            else:
                detail += json.dumps(p, indent=2, ensure_ascii=False)
            if p.get("reason"):
                detail += "\n\nReason: " + p["reason"]
            pending = request("Allow this Codex step?", detail, ttl=300)
            decisions = p.get("availableDecisions")
            if decisions is not None:
                # Only offer exact single-step accept/decline variants provided by the host.
                pending["choices"] = [c for c in pending["choices"] if c["id"] in decisions]
            if not pending["choices"]:
                self.send({"id": message["id"], "result": {"decision": "cancel"}})
                return
            self.pending[pending["id"]] = {"request": pending, "rpcId": message["id"], "agentId": self.value["id"], "itemId": p.get("itemId"), "sent": False}
            self.refresh_request()
            self.value.update(status="attention", summary="A permission is waiting for your decision", lastActivity=time.time())
        elif method == "serverRequest/resolved":
            for rid, waiting in list(self.pending.items()):
                if waiting["rpcId"] == p.get("requestId"):
                    self.pending.pop(rid)
            self.refresh_request()
        elif "id" in message and "method" in message:
            # User questions and granular permissions require richer UI. Decline through
            # JSON-RPC instead of pretending they were answered or granting broad access.
            self.send({"id": message["id"], "error": {"code": -32601, "message": "This request needs a richer host UI. Use the Codex session."}})
            self.value.update(status="attention", summary="This step needs the full Codex interface")
        elif method == "item/completed":
            item = p.get("item", {})
            for rid, waiting in list(self.pending.items()):
                if waiting.get("itemId") == item.get("id") and item.get("id") is not None:
                    self.pending.pop(rid)
            self.refresh_request()
            if item.get("type") == "agentMessage":
                self.value.update(summary=short(item.get("text", "")), lastActivity=time.time())
            elif item.get("type") in {"commandExecution", "fileChange"}:
                self.value["lastActivity"] = time.time()
        elif method == "turn/completed":
            turn = p.get("turn", {})
            status = turn.get("status", "failed")
            self.value.update(status="done" if status == "completed" else "attention", request=None, lastActivity=time.time())
            self.pending.clear()
            self.finished = True
            if status != "completed":
                self.error = turn.get("error") or {"message": "Turn " + status}
                self.value["summary"] = short(str(self.error))

    def refresh_request(self):
        first = next(iter(self.pending.values()), None)
        if first and self.trusted_local_inline:
            first["request"]["transport"] = "trusted-local-file"
        self.value["request"] = first["request"] if first else None
        self.value["status"] = "attention" if first else "working"

    def tick(self):
        if self.value is None:
            return
        for rid, waiting in list(self.pending.items()):
            pending = waiting["request"]
            if waiting["sent"]:
                continue
            answer = read_decision(self.directory / "decisions", pending, waiting["agentId"], trusted_local_inline=self.trusted_local_inline)
            if answer or time.time() >= pending["expiresAt"]:
                # Expiry cancels; it never grants access.
                self.send({"id": waiting["rpcId"], "result": {"decision": answer or "cancel"}})
                waiting["sent"] = True
                self.value["summary"] = "Decision sent · waiting for Codex to confirm" if answer else "Permission expired · cancellation sent to Codex"
        self.publish()

    def publish(self):
        if self.value is not None:
            filename = "codex-run-" + hashlib.sha256(self.value["id"].encode()).hexdigest() + ".json"
            atomic_json(self.directory / "sources" / filename,
                        {"generatedAt": time.time(), "managed": True, "active": not self.finished, "missions": [self.mission], "agents": [self.value]})


def run(args):
    if not getattr(args, "trusted_local_inline", False):
        raise SystemExit("Unsigned inline permissions are disabled. Start Codex in its normal UI for host-owned approvals. Use --trusted-local-inline only if every process able to write this state is trusted.")
    state = Path(args.state).resolve()
    # Start only when the app is present; otherwise approvals would be invisible.
    if not approval_surface_available(state, "Codex", str(Path(args.project).resolve())):
        raise SystemExit("Start SneakPeek in Live mode before launching a managed Codex mission.")
    process = subprocess.Popen([args.codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    messages = queue.Queue()

    def send(value):
        if process.poll() is None:
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()

    def reader():
        for line in process.stdout:
            try:
                messages.put(json.loads(line))
            except ValueError:
                continue
        messages.put(None)

    threading.Thread(target=reader, daemon=True).start()
    bridge = CodexBridge(state.parent, args.goal, str(Path(args.project).resolve()), send, trusted_local_inline=args.trusted_local_inline)
    send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "sneakpeek", "title": "SneakPeek", "version": "0.3.1"}}})
    try:
        while not bridge.finished:
            if not approval_surface_available(state, "Codex", bridge.cwd):
                raise RuntimeError("The SneakPeek live approval surface disconnected")
            try:
                message = messages.get(timeout=0.25)
            except queue.Empty:
                bridge.tick()
                continue
            if not approval_surface_available(state, "Codex", bridge.cwd):
                raise RuntimeError("The SneakPeek live approval surface disconnected")
            if message is None:
                raise RuntimeError("Codex app-server disconnected")
            if "error" in message:
                raise RuntimeError(str(message["error"]))
            if message.get("id") == 1:
                send({"method": "initialized", "params": {}})
                send({"id": 2, "method": "thread/start", "params": {"cwd": bridge.cwd}})
            elif message.get("id") == 2:
                bridge.setup(message["result"]["thread"])
                print("SneakPeek mission: " + bridge.value["sessionId"], flush=True)
                send({"id": 3, "method": "turn/start", "params": {"threadId": bridge.value["sessionId"], "input": [{"type": "text", "text": args.goal}]}})
            else:
                bridge.receive(message)
            bridge.tick()
    except (KeyboardInterrupt, RuntimeError, OSError, ValueError, KeyError) as error:
        if bridge.value:
            bridge.finished = True
            bridge.value.update(status="attention", request=None, summary=short(str(error) or "Mission interrupted"), lastActivity=time.time())
            bridge.publish()
        print(str(error), file=sys.stderr)
        return 1
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    return 1 if bridge.error else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", default=str(default_state_path()))
    parser.add_argument("--project", default=".")
    parser.add_argument("--goal", required=True)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--trusted-local-inline", action="store_true", help="Opt in to unsigned local permissions; every writer can forge a reply")
    sys.exit(run(parser.parse_args()))
