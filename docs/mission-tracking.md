# Mission checkpoints, decisions, and Taste

This contract describes the local 0.3 implementation. Models and executable tests define the precise schema; this document explains the product decisions and boundaries that code alone does not capture.

## Human workflow

1. Edit a mission's outcome, constraints, owner, and acceptance checks. Each check has a stable identity, a required/optional setting, and either evidence or human Taste as its basis. Pinning keeps the mission available between worker sessions.
2. Attach evidence to a check. Include a short assertion and an inspectable file or HTTPS reference. A report can support, contradict, or leave the check uncertain.
3. Open the evidence and assess whether it meets the intended check. Acceptance is an explicit human action, attached to this record and goal revision. The application cannot establish that a linked result actually proves the assertion.
4. Inspect the queue when needed. Host decisions retain their original agent/request scope. A human judgment request records a choice of direction; missing evidence and drift remain review items.
5. Add Taste whenever something feels right or wrong. Words are optional. A note stays quiet unless **Ask for a human review** is selected.

The notch displays five queue items at most. **Decision queue…** opens a lazy-rendered list with Decisions, Review suggested, and All categories. Team activity is a detail view; the count of decisions is not a count of busy workers.

## What a course assessment means

| Assessment | Basis |
| --- | --- |
| Course unproven | No usable supporting report or accepted required check, or known incomplete monitoring coverage. |
| Progress has evidence | At least one required check has a usable supporting report or explicit acceptance. This does not establish that the whole workflow is aligned. |
| Drift suspected | A required check is contradicted or rejected, a required Taste check is rejected, or a worker explicitly reports a course risk. The source and reason are shown. |
| Checks met · review outcome | All required checks have current acceptance and no known coverage gap. A completed mission still needs outcome review. |

Missing evidence, inconclusive claims, old evidence, silence, and a finished turn do not themselves prove drift or success. Optional failed checks remain inspectable without changing the required-check course assessment. Semantic drift detection by a model is not implemented.

## Evidence and review lifetime

Evidence records live separately from editable mission definitions. A goal revision binds outcome, constraints, check identities, labels, kinds, and required settings. An evidence fingerprint binds its identity, scope, assertion, reference, verdict, timestamp, digest, and local artifact version. Human reviews bind both revision and fingerprint. A newer report supersedes an older accepted report; an old pass cannot hide a later failure.

The default evidence age window is 24 hours. The mission editor offers 1 hour, 24 hours, 7 days, or no age limit. Check-specific windows are supported by the model. A goal change invalidates earlier evidence even without an age limit. Local file reports capture a SHA-256 digest, size, and modification time. Projection checks size/time and availability; human acceptance also rehashes the content. This is a local freshness mechanism, not tamper-proof monitoring. Remote HTTPS references are not fetched or version-checked. Human acceptance records the person's assessment; it is not an independent automated test.

Older progress-only checkpoints and bare `status: verified` fields cannot establish acceptance. They remain progress history. Add a bound evidence record and review it to establish acceptance in this version.

## Taste has its own provenance

Taste is human judgment: **Feels right**, **Feels off**, or **Not sure**, with **A hunch** or **A considered preference**. There is no numeric confidence or requirement to invent a factual justification. An ordinary note cannot satisfy an objective evidence check or create a permission grant.

A person can deliberately define a **Human taste** acceptance check, for example “The experience feels calm enough to release.” A Taste judgment can meet or reject that particular check, visibly labeled human Taste. This is subjective acceptance, not objective verification. A rejected required Taste check is a course concern because the mission explicitly included that preference.

A requested Taste review or human judgment enters the decision queue. Resolving it records **keep**, **change**, or **dismiss** locally. It does not message, pause, or reconfigure workers. Open the source session to direct the work. After the goal changes, an old request can be dismissed; directing the new goal requires a new request.

## Local commands for adapters

Get mission and check IDs from the current `runtime/state.json`. Publish a report without pretending it is independently verified:

```sh
python3 bridge/peek.py evidence \
  --state runtime/state.json \
  --mission MISSION_ID --checkpoint CHECK_ID \
  --summary 'The acceptance suite passes for this revision.' \
  --reference /absolute/path/to/test-result.txt \
  --claim supports --actor 'Validation worker'
```

The native client sends structured JSON through standard input to `bridge/mission_commands.py --state … --action …`. Actions cover definition edits, evidence attachment/review, Taste, explicit judgment requests, and resolutions. This command is a local transport, not an authenticated human identity boundary. A process with the same filesystem permissions can forge local records. Do not extend it to remote approvals without authentication and authorization.

## Handoff map for the next agent

| Concern | Code / executable contract |
| --- | --- |
| Deterministic course/evidence projection and queue | `bridge/mission_tracking.py`; `Tests/test_mission_tracking.py` |
| Structured human actions, optimistic edits, review binding | `bridge/mission_commands.py` |
| Progress overlays, pinned mission loading, example feed | `bridge/peek.py` |
| Native feed contract | `Sources/SneakPeekCore/Models.swift`, `TrackingModels.swift` |
| Python-to-Swift compatibility | `Tests/SneakPeekCoreTests/TrackingIntegrationTests.swift` |
| Record transport and source handoff | `Sources/SneakPeek/Store.swift` |
| Queue, evidence inspection, Taste and guidance forms | `Sources/SneakPeek/TrackingViews.swift` |
| Stable acceptance-check editing | `Sources/SneakPeek/MissionEditor.swift` |

Definition saves use the same per-mission lock as progress publication and reject stale definition revisions. A title-only edit merges freshly published legacy evidence by stable check ID. Evidence/review/Taste records are separate from the definition, so saving an editor snapshot cannot overwrite them. IDs survive renaming; duplicate labels need not share identity.

Run `./scripts/test.sh` and `./scripts/build.sh` after changes. Tests use synthetic data and mock hosts. Offscreen native previews are available without mouse control:

```sh
dist/SneakPeek.app/Contents/MacOS/SneakPeek \
  --state /absolute/path/to/synthetic/state.json --demo --no-bridge \
  --render-preview /absolute/path/to/preview.png --render-taste
```

Use `--render-inspector` or `--render-queue` for those views; omit the final mode flag for the notch. Do not commit live runtime data or private captures.

## Remaining scale work

Projection indexes workers, evidence, and judgments by mission/check, and the visible notch is bounded. A synthetic 1,000-mission test confirms that evidence gaps remain grouped review items and do not become 1,000 human decisions. It does not measure responsiveness or establish support for 1,000 live agents.

The local observer still polls and rewrites full snapshots, replays discovered logs on restart, and caps discovery at 100 logs per harness. Queue details are lazy-rendered, but mission selection and team detail are not fleet interfaces. Sidecar history has no retention policy or incremental durable reducer. See [scaling.md](scaling.md) for ingestion, incremental projections, pagination, event ordering, coverage reconciliation, and human-supervision measurements needed next.

The Copilot adversarial-review fixes are developed on a separate branch/PR. Check their merge state before assuming the UI-heartbeat, source-scope, lease, rotation, malformed-input, or mode-switch fixes are included in a build. They overlap mission editing; preserve the stable IDs, locked optimistic saves, and separate evidence records when integrating.
