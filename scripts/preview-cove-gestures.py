#!/usr/bin/env python3
"""Capture only the isolated gesture demo using synthetic events."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "output/cove-gestures/Cove Gestures.app/Contents/MacOS/SneakPeek"
OUTPUT = ROOT / "output/cove-gestures/Gesture recordings"


def capture(name, scene, initial):
    command = [str(APP), "--render-preview", str(OUTPUT / f"{name}.png"),
               "--render-cove-only", "--no-bridge", "--render-scene", scene,
               "--render-from-scene", initial, "--render-gif", str(OUTPUT / f"{name}.gif")]
    subprocess.run(command, check=True, timeout=20)
    if not (OUTPUT / f"{name}.png").exists():
        raise RuntimeError(f"Capture failed: {name}")
    print(name, flush=True)


if __name__ == "__main__":
    OUTPUT.mkdir(parents=True, exist_ok=True)
    capture("01-wave-needs-you", "Paw up", "Working")
    capture("02-rest-clear-queue", "Clear queue", "Working")
    capture("03-disconnected-cant-see", "Can’t see", "Working")
    capture("04-holding-paws", "Holding paws", "Drift")
    capture("05-paws-release-drift", "Drift", "Holding paws")
    capture("06-paws-rejoin", "Rejoin", "Drift")
    command = [str(APP), "--render-preview", str(OUTPUT / "playground.png"),
               "--render-playground", "--no-bridge"]
    subprocess.run(command, check=True, timeout=20)
