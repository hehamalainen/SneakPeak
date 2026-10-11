# Contributing and reviewing

SneakPeek is a local macOS research prototype. Changes should preserve its central distinction: observed activity, agent-reported progress, and human-verified outcomes are separate facts.

## Development

Requirements: macOS 14 or later, a Swift 6 toolchain (Xcode or Apple Command Line Tools), Python 3.9 or later, and zsh. There are no third-party runtime dependencies. The package uses SwiftPM; Python adapters use the standard library. Provider CLIs are optional unless testing a real integration.

```sh
git clone https://github.com/hehamalainen/SneakPeak.git
cd SneakPeak
./scripts/test.sh
./scripts/build.sh
./scripts/run.sh --demo --expanded
```

Tests use synthetic sessions and mock hosts. They do not call a model, connect an account, read real provider sessions, or modify global provider configuration. The run command launches the app and observer; live observation does read local provider logs. Quit from the eye menu when finished.

## Layout

- `Sources/SneakPeek/`: AppKit panel lifecycle and SwiftUI views.
- `Sources/SneakPeekCore/`: feed models and scoped decision writing.
- `bridge/`: local observation, data-only harness registration, hooks, checkpoint transport, and the Codex app-server runner.
- `Tests/`: Python integration tests and Swift decision tests.
- `scripts/`: build, run, test, and optional hook generators.
- `docs/`: product intent, connection instructions, and the proposed scale architecture.

Keep runtime files, credentials, real transcripts, compiled apps, and screenshots containing live session details out of commits and reports. Share minimal synthetic fixtures for reproduction. New adapters must exclude private reasoning, treat source logs as untrusted data, and describe whether they support observation, handoff, or authoritative approvals.

Run `./scripts/test.sh` and `./scripts/build.sh` before proposing changes. GitHub CI repeats those checks on macOS and tests the Python bridge on Python 3.9 and 3.14. CI does not launch the GUI or validate real providers.

## Adversarial review

Start with [SECURITY.md](SECURITY.md) and [docs/scaling.md](docs/scaling.md). Useful review targets include cross-request or cross-agent decision confusion, expired or replayed replies, malformed or oversized log events, source disconnection, misleading completion/coverage, private text leakage, and project-hook configuration preservation. Tests passing do not establish production security or fleet capacity.

For mission checkpoints, Taste, or the queue, read [docs/mission-tracking.md](docs/mission-tracking.md). It records the intended semantics and handoff map; use code and executable tests for field-level contracts. Preserve evidence provenance, goal/review binding, stable check identities, optimistic saves, and the separation between a human hunch and an executable host decision.
