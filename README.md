# SneakPeek

A quiet native Mac companion for long-running agent missions. Hover at the notch to see where the team is heading, what progress has been reported, and which decision needs you. Collapse it and get back to your work.

Version 0.3 is a **local research prototype** supporting **Codex, Claude Code, Antigravity, and GitHub Copilot**, including locally logged subagents. It runs on macOS 14+ with a Swift 6 toolchain (Xcode or Apple's Command Line Tools), Python 3.9+, and zsh. There are no third-party runtime packages, account connections, or inference calls in the observer. **Manage harnesses…** shows every connection even between builds and can register another harness without rebuilding the app.

For the Antigravity/Copilot test and additional harnesses, use the [harness connection guide](docs/harnesses.md).

The goal is supervision of hundreds or thousands of agents through mission-level evidence and a bounded queue of human decisions. This version has **not** been validated at that scale. Read the [scale architecture and current limits](docs/scaling.md), [security/privacy boundaries](SECURITY.md), and [contributor and adversarial-review guide](CONTRIBUTING.md).

## Run

```sh
git clone https://github.com/hehamalainen/SneakPeak.git
cd SneakPeak
./scripts/test.sh
./scripts/build.sh
./scripts/run.sh
```

SneakPeek appears at the top center of the built-in display, and in the menu bar. Hover to peek; move away to collapse. Pin it to keep it open. Escape collapses it when the panel has keyboard focus. The menu also opens the peek and quits the app. External displays without a notch use the same top-center position.

Use **Try demo** for an example mission. Its decision buttons send a real local reply to a simulated waiting agent. Example data is labeled throughout. Use **Go live** to return to your own sessions. `./scripts/run.sh --demo --expanded` opens the example immediately.

By default the observer discovers local sessions updated in the past 24 hours. The harness manager can extend this to 7 or 30 days and explains when a detected harness has no recent sessions. To scope it to one project:

```sh
./scripts/run.sh --project /absolute/path/to/project
```

The app enforces a single running instance; opening it again reveals the existing peek. Quit first when changing launch options or installing a new build. Runtime state is stored under `runtime/` and excluded from Git.

## Define the destination

Choose a mission and click its pencil. Give it a clear outcome and two or three observable landing checks. A **finished turn** is not the same as a **verified mission**.

**Inspect** opens the mission's evidence. Attach an artifact file or HTTPS reference to a check, inspect it, then choose **Check met** or **Check not met**. Reports remain claims until reviewed; a review is bound to that evidence record and the current goal. Changed goals, aged evidence, and changed local artifacts make an earlier acceptance stale. The app does not infer goal alignment from tool activity. Old bare “verified” labels without bound evidence no longer establish acceptance.

The **Queue** distinguishes host decisions and explicit human judgment requests from evidence gaps and suspected drift. Missing evidence is grouped once per mission; the notch shows at most five items, with a separate full queue. **Taste…** records “feels right,” “feels off,” or uncertainty, with optional words. A hunch stays quiet unless you request review. Taste affects acceptance only for checks explicitly defined as **Human taste**. Read the [mission tracking and handoff contract](docs/mission-tracking.md) for semantics, examples, and remaining limits.

Agents can publish a short progress checkpoint:

```sh
python3 bridge/peek.py checkpoint \
  --agent 'codex:SESSION_UUID' \
  --evidence 'The integration suite passes; the decision reached the waiting process.' \
  --next 'Review the hover flow on a MacBook display' \
  --trajectory onCourse
```

Use `--checkpoint CHECK_ID --reference /absolute/path/to/test-result.txt` to attach an evidence record to a landing check from `runtime/state.json`. Without a reference, a checkpoint is only a progress report. `atRisk` flags that a human should review the course; `unknown` leaves alignment unassessed. These labels are explicitly agent-reported. Checkpoints preserve the live session's subsequent activity and completion state.

## Decisions from the notch

Observation of existing sessions is automatic. An approval requires a return path to the host that owns that request. Merely reading a log cannot approve a step.

### Claude Code

Generate a per-session settings file, then start or resume Claude with it:

```sh
python3 scripts/claude-settings.py
claude --settings "$PWD/runtime/claude-settings.json"
# Or: claude --resume SESSION_UUID --settings "$PWD/runtime/claude-settings.json"
```

This adds a `PermissionRequest` hook to that invocation. It does not edit global or project Claude settings. The app must be running. The hook displays the tool, project, and complete input, and waits up to two minutes. Allow grants only that step; Decline returns a denial. Timeout or a missing observer returns to Claude's normal permission handling. Questions and some network prompts still need Claude's own UI. Existing deny policies remain in effect.

### Codex

Launch a new mission through the included app-server adapter:

```sh
python3 bridge/codex_runner.py \
  --project "$PWD" \
  --goal 'Implement the requested change and report the validation evidence.'
```

This starts a real Codex turn using your installed CLI and existing authentication; that turn can incur your normal model usage. It owns a separate app-server child process and inherits configured sandbox and approval defaults. It does not attach to or take over another running client's server.

Command and file-change approvals appear in the notch, with the exact input. Replies are bound to a unique request and agent, and the UI waits for host acknowledgement. Expiry cancels instead of approving. Rich questions and granular permission grants are not implemented by this small runner; use the full Codex interface for those workflows. A running mission stops if its observer disconnects.

## Session handoff

### Antigravity

The observer discovers public transcripts in Antigravity 2.0, Antigravity IDE, and Antigravity CLI. It reads only public response text; the separate `thinking` field is ignored. A completed transcript step is labeled **Update observed**, because it does not establish that the whole agent loop has stopped. Conversation artifacts can be opened, and the exact conversation ID copied for selection in the source app.

For authoritative start/stop and tool-error events, generate an optional lifecycle hook fragment:

```sh
python3 scripts/antigravity-hooks.py
```

Merge the `sneakpeek-observer` entry from `runtime/antigravity-hooks.json` into `.agents/hooks.json` in an Antigravity project, or configure it in Antigravity's Customizations > Hooks. Preserve other hooks. The generator does not modify active configuration. These hooks observe `PreInvocation`, `PostInvocation`, `PostToolUse`, and `Stop`; they do not register a permission gate or change tool permissions. `Stop` marks a turn finished only when `fullyIdle` is true and no stop error is reported. Without hooks, project-scoped monitoring excludes Antigravity transcripts whose workspace cannot be established. Questions and approvals remain in Antigravity's UI in this version.

Codex handoff attempts the local `codex://threads/…` deep link and also copies `codex resume SESSION_UUID`. If your installed client does not handle that URL, use the copied command. Claude handoff copies `claude --resume SESSION_UUID`; paste it into a terminal in the session's project. Logged subagent sessions may need their parent session for resume. This version does not control another app's terminal windows or approve prompts by clicking their UI.

## Verification

```sh
./scripts/test.sh
```

Tests cover request scope, invalid and expired replies, missing observers, partial log writes, nested subagent grouping, private-reasoning exclusion, checkpoint overlays, Claude hook round trips, a full Codex app-server subprocess round trip with a mock host, and Antigravity foreground/background completion semantics. Mission tests cover evidence freshness and review binding, conflicting reports, stale editor saves, Taste separation, and a synthetic 1,000-mission grouping scenario. A Swift integration test decodes the actual Python projection. These are correctness checks, not a fleet capacity benchmark. The script also accommodates the Testing framework location in Apple's Command Line Tools. No model call is made by these tests.

## Prototype limits

- Local session logs are a best-effort observation source. Their schemas can change, and they do not expose every permission or question. Discovery keeps the 100 newest eligible logs per harness and reports omitted logs as incomplete coverage; that cap also applies before project filtering.
- Lights show observed activity and explicit requests. Five minutes without an event is labeled quiet, not automatically failed or in need of human intervention.
- The app surfaces course risks explicitly reported by agents; it does not yet judge semantic drift automatically.
- No remote agents, push notifications, sound, auto-start, or background cloud service.
- The build uses ad-hoc signing for local development. Distribution needs proper signing and notarization.
- The observer retains recent visible prompt/message excerpts locally. Runtime files should be treated like local session data.

Protocol references: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [Claude Code hooks](https://code.claude.com/docs/en/hooks), and [Antigravity lifecycle hooks](https://www.antigravity.google/docs/hooks).

Licensed under the [MIT License](LICENSE).
