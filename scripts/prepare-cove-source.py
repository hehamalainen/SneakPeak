#!/usr/bin/env python3
"""Freeze the current demo source without changing any running app bundle."""
from pathlib import Path
import argparse
import shutil

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--destination", type=Path, default=ROOT / "runtime/cove-gestures-source")
args = parser.parse_args()
destination = args.destination.resolve()
if not destination.is_relative_to((ROOT / "runtime").resolve()):
    parser.error("the snapshot must be inside this repository's runtime directory")
destination.mkdir(parents=True, exist_ok=True)
for name in ("Sources", "Tests", "bridge", "scripts", "docs"):
    shutil.copytree(ROOT / name, destination / name, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
for name in ("Package.swift", "README.md", ".gitignore"):
    shutil.copy2(ROOT / name, destination / name)
print(destination)
