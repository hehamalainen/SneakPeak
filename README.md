# SneakPeek

A quiet native Mac companion for long-running agent missions. Hover at the notch to see where the team is heading, what progress has been reported, and which decision needs you. Collapse it and get back to your work.

Version 0.3.1 is a **local research prototype** supporting **Codex, Claude Code, Antigravity, and GitHub Copilot**, including locally logged subagents. It runs on macOS 14+ with a Swift 6 toolchain (Xcode or Apple's Command Line Tools), Python 3.9+, and zsh. There are no third-party runtime packages, account connections, or inference calls in the observer. **Manage harnesses…** shows every connection even between builds and can register another harness without rebuilding the app.

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

Choose **Appearance → Otter** from the menu bar for a quietly mischievous companion. A simple 32-point otter peeks while agents work, briefly waves a paw for a new decision, and rests only when a fresh feed explicitly confirms an empty queue. A disconnected observer, quiet agent, or unconfirmed queue gets a separate withdrawn “can’t see” state. Click it to open the same mission panel. Course concerns and missing evidence keep their own text; a resting otter does not establish that a mission is verified. Native appearance is the default. The choice is saved locally and can also be changed from the panel footer. Gestures play once on a state or attention change, with no repeating idle animation, and respect Reduce Motion.

In Otter mode, **Raft** adds a visual team view above the agent details. Paws link only between adjacent agents with fresh “on course” reports. Reported risk opens a gap; stale reports, quiet agents, and disconnection show unknown course. These are agent claims, not verified alignment. The same evidence and decision controls remain available.

`./scripts/run.sh --otter` selects Otter; `--native` switches back. For a synthetic screenshot, pass `--render-preview /absolute/path.png --render-collapsed --otter --no-bridge --state /absolute/path/to/synthetic-state.json` directly to the built executable. Previews do not save appearance preferences or publish an approval surface.

To build and inspect Otter separately while the normal app and other jobs keep running:

```sh
./scripts/build.sh --scratch-path "$PWD/runtime/otter-build" \
  --app "$PWD/runtime/otter-preview/SneakPeek.app" \
  --bundle-id local.sneakpeek.otter.preview
./scripts/test.sh --scratch-path "$PWD/runtime/otter-tests"
python3 scripts/preview-otter.py
```

That preview bundle has its own identity, synthetic state, and show notification. It never starts an observer or publishes an approval surface, including when opened later. The preview script renders all four silhouettes, quiet-agent behavior, the Raft, Native appearance, and a short GIF of the paw gesture under `runtime/otter-preview/`. The GIF loops for inspection; the in-app gesture plays once. Generated artwork prompts are recorded in [otter-artwork.json](docs/otter-artwork.json).

Opening the separate preview app launches an interactive playground. **Play demo** runs through working, a decision, clear queue, lost visibility, quiet agent, drift, and rejoining. Individual buttons replay each event; **Holding paws**, **Drift**, and **Rejoin** let you inspect the Raft. **Otter only** hides the playground and shows a small draggable companion in a screen corner. Click it to restore the Raft and controls. These gestures run from synthetic in-memory events, with no observer or live state writes. `--play-all` starts the sequence on launch; `--render-playground` can capture the playground using the existing preview renderer.

The selected character is **Sculptural Cove**. The preview uses its actual transparent artwork and a separately articulated forearm for the attention gesture. The Raft separates the two authored halves at their paw seam, and wakes or withdraws them when the queue needs attention, course is at risk, coverage is incomplete, or visibility is unavailable. Sleeping requires a fresh feed, an explicitly clear queue, and two fresh on-course reports; it does not verify a mission. The interactive isolated preview ignores external state overrides and saves no appearance preference. `--render-cove-only` and `--render-cove-raft`, with `--render-scene 'Paw up'` or another button label, capture the character and Raft using synthetic data only.

## Cove presentation demo

The portable presentation app is `output/cove-demo/Cove Demo.app`, with a complete handoff archive at `output/cove-demo.zip`. It has a separate `local.sneakpeek.cove.demo` identity and notification, supports macOS 14+ on Apple silicon and Intel, and bundles its artwork. It needs no repository, Python, Swift installation, account, live state, or observer to run. The build is signed for local development, not notarized distribution.

Open the app and press **Play demo** or **Space** for the 32-second story. **Stop demo** or any scene button stops the timed sequence. **Acknowledge example** clears only a synthetic request. **Otter only** switches to the draggable companion; clicking Cove restores the controls. **Command-Q** quits only the demo. The package includes a short presenter guide and six gesture GIFs as backup. The normal app and agent jobs remain independent.

`scripts/package-cove-demo.sh` builds this release from the frozen `runtime/cove-demo-source` snapshot, avoiding races with native-app work. It builds both CPU architectures, combines them, verifies the signature, and packages the app, guide, review, and recordings.

By default the observer discovers local sessions updated in the past 24 hours. The harness manager can extend this to 7 or 30 days and explains when a detected harness has no recent sessions. To scope it to one project:

```sh
./scripts/run.sh --project /absolute/path/to/project
```

The app enforces a single running instance; opening it again reveals the existing peek. Quit first when changing launch options or installing a new build. Runtime state defaults to `~/Library/Application Support/SneakPeek`, outside the supervised checkout. An explicit `--state /absolute/path/state.json` selects an alternate directory. Existing `runtime/` data is not automatically migrated. See [the Claude review follow-up](docs/claude-review.md) for trust boundaries and manual migration.

## Clearer Cove gestures

The revised standalone demo uses **the same Sculptural Cove character** with
stronger visual state changes:

- **Needs you:** the paw rises high, waves twice, and stays up until acknowledged.
- **Watching:** an upright, open-eyed bust that stays still after entering.
- **Resting:** a horizontal, closed-eye pose after a fresh, explicitly clear queue.
- **Can't see:** a turned back and crossed-eye mark, distinct from resting.
- **Holding paws:** the pair is visible in the main scene and floating companion;
  it joins at the central paws, releases and drifts apart, then reconnects.

The playground includes actual 32-point and 64-point previews. Start **Play demo**
and choose **Otter only** to watch the full sequence in the floating companion.
Click the companion to return. Each movement plays once; Reduce Motion uses
settled poses.

Build a separate presentation package without replacing the native app:

```sh
./scripts/package-cove-gestures.sh
```

This snapshots source under `runtime/cove-gestures-source`, uses its own build
folders and the `local.sneakpeek.cove.gestures` identity, and writes
`output/cove-gestures/Cove Gestures.app`, six real-renderer GIFs, and
`output/cove-gestures.zip`. The new identity also has separate notifications,
ignores live-state overrides in interactive use, and cannot start an observer,
publish approvals, save decisions, or persist appearance preferences. The native
app and earlier demos can remain running.

The app targets macOS 14+ on Apple silicon and Intel. It is locally signed,
not notarized. Runtime/UI testing is on Apple silicon; Intel is compiled.
See [demo instructions](docs/cove-gestures-guide.txt) and
[artwork prompts](docs/cove-gesture-prompts.json). Build products, captures,
private resume checkpoints and design scratch are excluded from Git.

Native auxiliary windows now reuse and focus existing inspectors, preserve
unsaved editor drafts per target, and hide the notch while a tool window is in
front. Reopening the notch keeps it below the tool windows. Escape reaches the
focused editor rather than being consumed by the notch.

## Define the destination

Choose a mission and click its pencil. Give it a clear outcome and two or three observable landing checks. A **finished turn** is not the same as a **verified mission**.

**Inspect** opens the mission's evidence. Attach an artifact file or HTTPS reference to a check, inspect it, then choose **Check met** or **Check not met**. Reports remain claims until reviewed; a review is bound to that evidence record and the current goal. Changed goals, aged evidence, and changed local artifacts make an earlier acceptance stale. The app does not infer goal alignment from tool activity. Old bare “verified” labels without bound evidence no longer establish acceptance. Reviews and Taste records are unsigned local claims: a writer of the state can forge them. First-prompt goals are labeled as inferred until locally edited.

The **Queue** distinguishes host decisions and explicit human judgment requests from evidence gaps and suspected drift. Missing evidence is grouped once per mission; the notch shows at most five items, with a separate full queue. **Taste…** records “feels right,” “feels off,” or uncertainty, with optional words. A hunch stays quiet unless you request review. Taste affects acceptance only for checks explicitly defined as **Human taste**. Read the [mission tracking and handoff contract](docs/mission-tracking.md) for semantics, examples, and remaining limits.

Agents can publish a short progress checkpoint:

```sh
python3 bridge/peek.py checkpoint \
  --agent 'codex:SESSION_UUID' \
  --evidence 'The integration suite passes; the decision reached the waiting process.' \
  --next 'Review the hover flow on a MacBook display' \
  --trajectory onCourse
```

Use `--checkpoint CHECK_ID --reference /absolute/path/to/test-result.txt` to attach an evidence record to a landing check from the selected `state.json`. Without a reference, a checkpoint is only a progress report. `atRisk` flags that a human should review the course; `unknown` leaves alignment unassessed. These labels are explicitly agent-reported. Checkpoints preserve the live session's subsequent activity and completion state.

## Decisions and host approvals

**Codex and Claude retain permissions in their own UI by default.** SneakPeek observes and hands off to the source session. No unsigned decision file is applied by the default adapters. The small managed Codex runner refuses to launch without the explicit trusted-local opt-in; start Codex normally for host-owned permissions.

### Optional trusted local prototype

The file-based inline permission experiment is available only when **every process able to write the state directory is trusted**. A peer writer can forge an approval. Moving state out of the repo reduces accidental sandbox exposure; it does not authenticate a human or defeat a same-account process with wider access. Review [SECURITY.md](SECURITY.md) before opting in.

For one Claude invocation:

```sh
python3 scripts/claude-settings.py --trusted-local-inline
claude --settings "$HOME/Library/Application Support/SneakPeek/claude-settings.json"
```

The generator does not modify active Claude configuration. Without `--trusted-local-inline`, its hook immediately leaves permission handling with Claude. With the opt-in, it displays the complete tool input and waits up to two minutes; Allow applies only to that step, Decline denies, and an unavailable surface or expiry returns to Claude's own handling. Existing host policies remain in effect.

For a managed Codex experiment:

```sh
python3 bridge/codex_runner.py --trusted-local-inline \
  --project "$PWD" \
  --goal 'Implement the requested change and report validation evidence.'
```

This starts a real Codex turn using your installed CLI, authentication, configured sandbox and approval defaults; normal model usage can apply. It owns a separate app-server and does not attach to another client's session. Replies are bound to the exact request and wait for host acknowledgement, but they are unsigned and forgeable by a local writer. Expiry cancels, a disconnected live surface stops the owned process, and unsupported rich requests require the full host interface.

Do not opt in for hostile or drifting agents with access to the supervisor state. Use host approvals while the authenticated transport described in [the security handoff](docs/claude-review.md) remains unimplemented.

## Session handoff

### Antigravity

The observer discovers public transcripts in Antigravity 2.0, Antigravity IDE, and Antigravity CLI. It reads only public response text; the separate `thinking` field is ignored. A completed transcript step is labeled **Update observed**, because it does not establish that the whole agent loop has stopped. Conversation artifacts can be opened, and the exact conversation ID copied for selection in the source app.

For authoritative start/stop and tool-error events, generate an optional lifecycle hook fragment:

```sh
python3 scripts/antigravity-hooks.py
```

Merge the `sneakpeek-observer` entry from `~/Library/Application Support/SneakPeek/antigravity-hooks.json` into `.agents/hooks.json` in an Antigravity project, or configure it in Antigravity's Customizations > Hooks. Preserve other hooks. The generator does not modify active configuration. These hooks observe `PreInvocation`, `PostInvocation`, `PostToolUse`, and `Stop`; they do not register a permission gate or change tool permissions. `Stop` marks a turn finished only when `fullyIdle` is true and no stop error is reported. Without hooks, project-scoped monitoring excludes Antigravity transcripts whose workspace cannot be established. Questions and approvals remain in Antigravity's UI in this version.

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
