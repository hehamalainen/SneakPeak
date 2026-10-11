# From a local peek to mission supervision at scale

The product goal is to free human attention while preserving the ability to inspect what autonomous work is accomplishing. Hundreds or thousands of agents are a design target, not a capacity claim for this prototype. No fleet load validation has been performed.

## Current implementation and limits

The native app supervises a local observer using file-based state. Each harness discovery scan keeps the 100 most recently modified eligible log files. That is a limit on logs, not an agent limit: one log can contain several subagents or generic sessions. Older eligible logs are omitted. The harness manager reports the omitted count, and the live feed warns when coverage is incomplete. Project filtering happens after discovery, so a busy harness can crowd out logs from the selected project.

Discovery rescans configured log folders every eight seconds. New sessions replay their log from the beginning; subsequent reads track an in-memory byte offset. Offsets are lost on observer restart. The bridge rewrites a full state snapshot every second, and the Swift app decodes that snapshot every second. Version 0.3 bounds the notch to five queue items and uses lazy rendering in the full queue, but mission/team detail still performs full-array filters and sorting. Those choices support a local prototype; increasing the discovery limit alone does not make them suitable for a fleet. There are no distributed durable queue, remote authorization, backpressure, retention service, or measured fleet latency/resource budgets.

Local log schemas are best-effort sources. A quiet agent is not necessarily blocked, an ended turn is not a verified mission, and a missing log is not proof that no decision is waiting. Hooks improve lifecycle fidelity but do not replace an authoritative runtime contract.

## Proposed unit of attention

The primary object should be a **mission** with a human-owned outcome, observable acceptance checks, current evidence, dependencies, and an accountable owner. Agents are workers within that mission. The surface should show a small set of mission summaries and an intervention queue; a person can drill down to a team or individual event when needed. The number of lights and interruptions must not grow with worker count.

An intervention should say what decision is required, why now, the affected scope, the evidence behind it, and the consequences of answering or waiting. Similar non-permission alerts may be grouped, but grouping must preserve individual request ownership and never silently grant multiple permissions. Prioritization must expose its basis; semantic assessments remain separate from factual runtime events and human verification.

## Proposed architecture

1. **Harness adapters** publish a versioned event envelope: organization/project/mission/run/agent identity, parent/dependency links, event ID, source sequence, timestamp, lifecycle or intervention type, and provenance. Transcript excerpts are optional and minimized. Each adapter documents authoritative versus inferred fields.
2. **Ingestion** authenticates producers, enforces tenant/project scope, validates bounded payloads, deduplicates events, handles ordering gaps, and applies backpressure. Durable storage supports replay and retention. Missing producers and incomplete coverage become explicit state.
3. **Mission reducers** maintain incremental projections of outcomes, evidence, dependencies, worker health, and open decisions. Reconciliation compares producer sequence/watermarks with stored events. Late, duplicate, or out-of-order events cannot silently overwrite a newer decision.
4. **Attention service** builds a bounded queue of actionable human decisions, with escalation deadlines and deduplication. Machine-reported risks and model-generated alignment assessments carry their evidence and uncertainty. Attention rules must be tunable and auditable.
5. **Clients** subscribe to compact deltas and request paginated details. The notch is one quiet client; team review and history need another inspection surface. Large lists use virtualized rendering, and UI changes do not require full-fleet decoding or sorting.
6. **Decision return path** authenticates the human and receiving host, checks scope and policy, expires stale requests, records an audit event, and requires host acknowledgement. An observation-only adapter cannot gain approval rights by publishing a different event type.

The existing standard event format is a local adapter experiment. It lacks the distributed identity, authorization, ordering, and delivery contracts described above; it should not be presented as that future protocol.

## Evidence required before claiming scale

Use synthetic data first, then representative consenting provider sessions. Benchmark 100, 1,000, and 10,000 workers across both many missions and one large team. Exercise bursty starts/completions, duplicate/out-of-order events, huge or malformed records, disconnected producers, restart/replay, and a simultaneous intervention storm. Establish CPU, memory, storage, event-to-display latency, dropped-event/coverage, and recovery budgets before release. No numerical performance result is asserted here.

Measure the human outcome too: missed decisions, time to understand why intervention is needed, interruption rate, incorrect confidence that a mission is finished, and time to recover from drift. A throughput benchmark cannot show whether people can supervise effectively.

## Reviewable next steps

Coverage reporting is included. Version 0.3 adds [mission checkpoints, an explicit decision queue, and Taste](mission-tracking.md), with separate evidence/review records and a synthetic 1,000-mission correctness fixture. The bounded notch and grouped evidence gaps are attention improvements, not a capacity claim. Next benchmark the current system and establish a versioned event contract. Introduce persistent incremental projections and paginated mission inspection before adding remote transport. Design and review authentication/authorization before implementing remote approvals. Semantic drift assessment follows reliable evidence capture and must remain distinguishable from verification.
