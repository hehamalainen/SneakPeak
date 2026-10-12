#!/usr/bin/env python3
"""Capture the real isolated Cove renderer using in-memory synthetic scenes."""
from pathlib import Path
import subprocess
import os

ROOT = Path(__file__).resolve().parent.parent
APP = Path(os.environ.get("COVE_PREVIEW_APP", ROOT / "runtime/otter-preview/SneakPeek.app/Contents/MacOS/SneakPeek"))
OUTPUT = ROOT / "output/cove-animation-assets"


def capture(name, scene, *, raft=False, initial=None, animated=True):
    command = [str(APP), "--render-preview", str(OUTPUT / f"{name}.png"), "--no-bridge",
               "--render-cove-raft" if raft else "--render-cove-only", "--render-scene", scene]
    if initial:
        command += ["--render-from-scene", initial]
    if animated:
        command += ["--render-gif", str(OUTPUT / f"{name}.gif")]
    subprocess.run(command, check=True, timeout=20)
    if not (OUTPUT / f"{name}.png").exists():
        raise RuntimeError(f"Capture failed: {name}")
    print(name)


if __name__ == "__main__":
    OUTPUT.mkdir(parents=True, exist_ok=True)
    capture("paw-up", "Paw up", initial="Clear queue")
    capture("settle", "Clear queue", initial="Paw up")
    capture("withdraw", "Can’t see", initial="Working")
    capture("holding-paws", "Holding paws", raft=True, initial="Drift")
    capture("drift", "Drift", raft=True, initial="Holding paws")
    capture("rejoin", "Rejoin", raft=True, initial="Drift")
    command = [str(APP), "--render-preview", str(OUTPUT / "playground.png"),
               "--render-playground", "--no-bridge"]
    subprocess.run(command, check=True, timeout=20)
