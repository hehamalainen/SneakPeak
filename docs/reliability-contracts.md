# Local supervision contracts and review handoff

This document defines the local transport rules for the adversarial-review fixes based on `e5d56d7`. It is a handoff for contributors and reviewers, not a claim of production security or support for thousands of agents.

## Scope applies to every source

`--project` includes the selected directory and its descendants. Transcript observation and connected JSON sources follow the same rule. Connected agents carry a `workspace` string. During scoped monitoring, unknown or out-of-scope workspaces are excluded, including their mission overrides and requests. The built-in Codex, Claude, Copilot, and Antigravity publishers set this metadata.

Older connected-source files without workspace metadata can still appear in unscoped monitoring. They must be republished by an updated adapter to appear in a scoped view. A filtered-out project cannot silently change the goal of an in-scope mission.

## Collector availability and approval availability are different

`state.json` is an observer snapshot; its freshness does not prove a person can see approvals. The native Store separately publishes `approval-surface.json` with:

- `generatedAt`: the surface heartbeat, refreshed by the Store.
- `live`: whether a readable, connected Live feed is currently displayed.
- `statePath`: the canonical path of the specific feed being displayed.
- `provider`: the current source filter (`All sources` or the selected provider).

In explicit `--trusted-local-inline` mode, Codex and Claude require both fresh snapshots and an available surface for their provider and workspace. Demo mode, unreadable feeds, mismatched state paths, incompatible source filters, or a disconnected observer make inline approval unavailable. Future-dated heartbeats beyond a small clock tolerance are rejected. This is a local liveness contract, not an authentication mechanism.

Claude immediately retains or returns to its original approval UI when the surface is unavailable. A managed Codex mission refuses to start without that surface and stops its owned app-server if availability is lost. Availability is checked around message processing as well as during quiet periods; a busy notification stream cannot defeat the check. Switching to Demo therefore interrupts a managed Codex run rather than leaving an invisible approval waiting.

Decisions still carry the exact request ID, agent ID, allowed single-step choice, and timestamp. Expiry cancels or falls back; it does not grant access. Copilot and Antigravity observation hooks do not provide permission decisions.

## Sends and acknowledgements retain their context

The Store retains separate sent-request state for Live and Demo. Switching modes cannot acknowledge an outstanding request from the other mode or erase its sent state. Returning to Live restores that state while the request is still present. Each disappeared request is cleared independently of other requests.

The Live message says that the source request cleared and asks the user to inspect its latest status. Disappearance is not proof that a tool succeeded, a permission was granted, or the mission finished. The underlying Codex adapter continues to wait for the host's request-resolution event after sending a decision.

## Source authority ends with the runner lease

A connected source lease (`managed`, `active`, `generatedAt`) describes liveness; a writable JSON claim does not authenticate a producer. The Claude follow-up therefore removes unconditional managed precedence. A newer observed log wins over an older source even when its lease is fresh. A connected source cannot replace an observed mission goal, clear log-observed attention or a pending request, or mask log-observed `atRisk`. Conflicts produce an inspection warning. Current source requests can appear when no observed concern conflicts; other state reconciles by activity time.

This conservative rule may retain an observed issue until the next log update corroborates its resolution. It does not establish trusted host events and cannot prevent someone modifying the original logs or projected feed. Completion and interruption still publish `active: false`; source scope, surface availability, and malformed-record checks remain in force.

Progress overlays replace current progress only when their `at` is at least as recent as `lastProgress`; an overlay also cannot clear a log-observed risk. A course claim older than one hour, lacking a progress timestamp, or future-dated beyond five seconds becomes `unknown` with `progressFreshness: stale`. Its original claim and timestamp remain available for inspection. Fresh activity alone does not renew the course claim. This window applies to an agent's course label, not to independently reviewed checkpoint records on the mission branch.

## Mission edits cannot replace a stale evidence snapshot

Native mission edits and Python checkpoint publishing use the same per-mission advisory lock: `missions/<sha256(id)>.lock`. Atomic JSON replacement protects file completeness; the shared lock protects the read–merge–write operation.

Each definition edit carries its original mission snapshot. The writer checks `definitionRevision` and the original title, goal, and checkpoint identities/labels against the latest saved definition. A conflicting edit is rejected, the editor remains open, and the user is told to reopen the mission. Evidence arriving after an editor opened does not itself cause a definition conflict.

For unchanged goals and criteria, saves preserve the latest persisted evidence, verification status, and source by stable checkpoint ID. Changing a goal or criterion resets the affected evidence to pending. Human verification also reads the latest mission under that lock and verifies only the evidence/criterion the person actually saw; a changed report is refused. Verification preserves updates to other checkpoints. Python reports using an outdated goal or definition revision are refused without publishing a misleading progress overlay.

Checkpoint editing uses stable row IDs. Repeated labels remain independent rows, whitespace-only rows are dropped, and persistence refuses duplicate IDs. Text labels never determine identity.

This baseline branch still uses legacy checkpoint fields. The separately developed mission/Taste branch moves evidence and reviews into append-only sidecars and adds its own definition command/revision contract. **Reconcile these overlapping Store/editor/persistence changes deliberately before merging both branches.** The sidecar architecture should retain the concurrency and evidence-binding guarantees above; this baseline writer should not be copied over it blindly.

## Invalid records and replaced logs are isolated

Connected sources and saved mission/progress records are validated before merging. A malformed file or nested record yields a warning and is skipped while valid records continue updating. Harness IDs are checked before dictionary construction, including malformed array-valued IDs. This prevents the reviewed small malformed inputs from stopping observation; it is not a resource-exhaustion defense for arbitrary file sizes.

Log readers track the device/inode of the opened file in addition to its size. Replacing a log resets its parser/session state even when the replacement is the same size or larger. Partial trailing records remain unread until their newline arrives; truncation also resets the reader.

Antigravity `DONE` interactions clear the matching pending interaction by kind and host identity (`id` or `step_id`) when available. Unrelated identified completions do not clear the current request. Without host IDs, only a completion of the same interaction kind is matched. Overlapping anonymous interactions remain ambiguous; live host fixtures should guide any stronger reconciliation rule.

## Regression coverage and remaining validation

Run `./scripts/test.sh` and `./scripts/build.sh`. Tests and builds use the checkout's own scratch module cache. Tests never launch the app UI, call a model, or alter global harness settings.

| Review finding | Regression coverage |
| --- | --- |
| 1. Hidden live approvals in Demo | Real Store surface tests; collector-only refusal; Claude fallback on mode change |
| 2. Connected-source scope bypass | In/out/unknown workspace tests, goal-override exclusion, scoped surface checks |
| 3. Stale managed precedence | Unsigned managed lease cannot override newer observation; finished bridge publishes inactive |
| 4. Lost mission evidence | Real Store title-save and verification merge; stale-definition/report refusal; changed-evidence rejection |
| 5. Busy queue bypasses disconnect | Actual runner loop with a synthetic busy queue and stale heartbeat |
| 6. Old progress overrides new | Older overlay preserves newer evidence and trajectory |
| 7. Malformed files stop observer | Mixed valid/invalid records through `watch`; invalid registry ID retains valid overrides |
| 8. Antigravity request never clears | Matching/unrelated identified and anonymous interaction completions |
| 9. Replacement log is skipped | Equal-sized and larger replacement records reset session identity |
| 10. Duplicate checkpoint IDs | The editor's stable-row helper preserves duplicate labels and removes blank rows |
| 11. Cross-mode false acknowledgement | Real Store sends, switches modes, restores pending state, then observes source clearing |

Swift tests now exercise the application Store as well as the Core decision writer. Python tests retain the mock subprocess approval round trip and project-hook preservation checks.

Live Codex/Claude UI behavior, current provider log formats, and Antigravity's actual completion identities still need manual integration tests. Passing these local regressions does not prove successful human supervision at fleet scale. The subsequent Claude review confirmed peer-written decisions can grant permissions in trusted-local mode. Default adapters now refuse those files; the opted-in file transport remains inside the same-account writer trust boundary.
