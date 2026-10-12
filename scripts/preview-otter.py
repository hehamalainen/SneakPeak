#!/usr/bin/env python3
"""Render isolated synthetic previews. Never attach to the live observer."""
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
PREVIEW = ROOT / "runtime" / "otter-preview"
APP = PREVIEW / "SneakPeek.app" / "Contents" / "MacOS" / "SneakPeek"


def agent(identifier, course="unknown", status="working"):
    now = time.time()
    return {"id": identifier, "missionId": "otter-demo", "name": identifier,
            "provider": "Example", "status": status, "summary": "Synthetic preview",
            "lastActivity": now, "lastProgress": now, "evidence": "Example report only",
            "nextStep": "Inspect the evidence", "trajectory": course}


def render(name, *, agents, queue, disconnected=False, expanded=False, native=False):
    directory = PREVIEW / "fixtures" / name
    directory.mkdir(parents=True, exist_ok=True)
    now = time.time()
    feed = {"generatedAt": 0 if disconnected else now, "demo": not disconnected,
            "missions": [{"id": "otter-demo", "title": "Build a quieter workspace",
                          "goal": "Show meaningful agent status without breaking focus.",
                          "checkpoints": []}], "agents": agents, "queue": queue}
    (directory / "demo-state.json").write_text(json.dumps(feed))
    destination = PREVIEW / f"{name}.png"
    command = [str(APP), "--render-preview", str(destination), "--no-bridge", "--demo",
               "--native" if native else "--otter", "--state", str(directory / "state.json")]
    command += ["--render-raft"] if expanded else ["--render-collapsed"]
    if name == "attention":
        command += ["--render-gif", str(PREVIEW / "paw-gesture.gif")]
    subprocess.run(command, check=True, timeout=20)
    if not destination.exists():
        raise RuntimeError(f"Preview was not rendered: {destination}")
    print(destination)


if __name__ == "__main__":
    if not APP.exists():
        raise SystemExit("Build the isolated runtime/otter-preview/SneakPeek.app first.")
    render("working", agents=[agent("Builder")], queue=[])
    render("attention", agents=[agent("Builder")], queue=[
        {"id": "example-decision", "missionId": "otter-demo", "missionTitle": "Example",
         "kind": "judgment", "title": "Choose the direction", "why": "Example human choice",
         "impact": "Human judgment", "priority": 1}])
    render("resting", agents=[agent("Builder", status="done")], queue=[])
    render("disconnected", agents=[agent("Builder")], queue=[], disconnected=True)
    quiet = agent("Builder")
    quiet["lastActivity"] = time.time() - 301
    render("quiet", agents=[quiet], queue=[])
    render("raft", agents=[agent("Builder", "onCourse"), agent("Reviewer", "onCourse"),
                           agent("Explorer", "atRisk")], queue=[], expanded=True)
    render("native", agents=[agent("Builder")], queue=[], native=True)
    # Launching this preview bundle later still uses only its own synthetic data.
    (PREVIEW / "demo-state.json").write_text((PREVIEW / "fixtures" / "raft" / "demo-state.json").read_text())
