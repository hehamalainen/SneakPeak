# Harness connections and your first test

SneakPeek 0.3 includes Codex, Claude Code, Antigravity, and GitHub Copilot as permanent choices. They stay in the source picker even when no session is running. A harness is an agent runtime; a session is one conversation or build managed by it.

## Antigravity and Copilot

1. Open the eye menu in the menu bar and choose **Manage harnesses…**, or use the sliders button at the bottom of the peek.
2. Find **Antigravity** and **GitHub Copilot**. Their cards show detection status, event-log locations, and the last observed log update.
3. Start or resume a session in each source application. Recent sessions appear automatically, normally within eight seconds. Copilot CLI sessions are also covered.
4. Select that harness from the source picker, then choose its mission. Peek at the visible update and status while it works.
5. For clearer start/stop signals, use **Set up in a project…** on either card, select the project for your test, then start or resume the session there. This adds observer hooks to that project and preserves other hooks.

Copilot uses `~/.copilot/session-state/*/events.jsonl`. Antigravity uses public transcripts from its desktop app, IDE, and CLI under their respective `~/.gemini/…/brain/` folders. The observer excludes private reasoning text. Recorded permission requests are surfaced as handoffs; answer them in the source application. These two observer connections do not grant permission from the notch.

The normal history window is 24 hours. An installed harness with no recent session shows **waiting**, with its last log update, instead of disappearing. Choose 7 or 30 days in the manager if you want older sessions visible. An old session is history, not evidence of a currently running agent.

The local prototype observes at most the 100 newest eligible log files per harness. The manager and peek warn when additional recent logs are omitted. That is a log-file limit, not a worker-count guarantee; a file can contain multiple sessions or subagents. Project filtering occurs after this selection. See [scale limits and the proposed architecture](scaling.md) before using it for a larger fleet.

Optional hook setup writes `.agents/hooks.json` for Antigravity or `.github/hooks/sneakpeek.json` for Copilot in the project you select. It does not edit global settings. A previous target file is backed up on first setup. Observer hooks return no tool-permission decisions, rewritten prompts, or forced continuation. The hooks need access to the local SneakPeek script and state directory; if the harness sandbox blocks that access, the public-log connection still works and the source application may show a hook warning.

To configure hooks from a terminal instead of the manager:

```sh
python3 bridge/connect.py --provider antigravity --project /absolute/project
python3 bridge/connect.py --provider copilot --project /absolute/project
```

## Add another harness

Open **Manage harnesses → Add harness…**. Give it a name. Keep **SneakPeek events · any harness** as the format to create a new local event file, or choose a supported existing format and its log path. The observer picks it up within eight seconds. There is no app rebuild.

For a new runtime, register it and emit lifecycle events from its hooks or wrapper:

```sh
python3 bridge/peek.py register --name "My Harness"

python3 bridge/peek.py emit --harness my-harness --session build-42 \
  --event started --goal "Ship the agreed change" --summary "Starting the implementation"

python3 bridge/peek.py emit --harness my-harness --session build-42 \
  --event progress --evidence "The integration suite passes" \
  --next "Review the user flow" --trajectory onCourse

python3 bridge/peek.py emit --harness my-harness --session build-42 \
  --event needs_input --summary "Choose which release target to use"

python3 bridge/peek.py emit --harness my-harness --session build-42 --event resolved
python3 bridge/peek.py emit --harness my-harness --session build-42 \
  --event completed --summary "Ready for review"
```

The publisher is also bundled at `SneakPeek.app/Contents/Resources/bridge/peek.py`. The manager's **Copy event command** includes the actual script and state paths. Fill in the session ID and outcome before using it. Use `--state /absolute/state.json` when observing an alternate or installed-app state directory.

The standard log is newline-delimited JSON, one event per line:

```json
{"schema":1,"event":"progress","session_id":"build-42","timestamp":1791740000,"summary":"Validation complete","evidence":"Integration suite passes","next_step":"Review the flow","trajectory":"onCourse"}
```

Supported events: `started`, `activity`, `progress`, `needs_input`, `resolved`, `completed`, and `failed`. `timestamp` accepts Unix seconds, Unix milliseconds, or an ISO 8601 string. Optional fields include `goal`, `cwd`, `name`, and `parent_session_id`. Use `--parent ROOT_SESSION_ID` when publishing a child agent's events; root and child sessions share the root mission.

Only explicit progress evidence updates the course assessment. `needs_input` creates a source handoff, not an executable approval. The generic adapter never imports plugins, executes commands from log entries, or claims it can answer an unknown runtime's permission protocol.

Harness definitions and the history window are stored in the selected state directory’s `harnesses.json` (by default `~/Library/Application Support/SneakPeek`). Definitions contain a stable `id`, display `name`, `format`, `logs`, and `enabled` flag. Log paths must be absolute (or start with `~/`). Built-in roots can be customized in that file; additional formats use the same four known parsers or the standard SneakPeek format.

References: [Copilot event schema](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/streaming-events), [Copilot hooks](https://docs.github.com/en/copilot/reference/hooks-reference), and [Antigravity hooks](https://www.antigravity.google/docs/hooks).
