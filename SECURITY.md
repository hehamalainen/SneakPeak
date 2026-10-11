# Security and privacy

SneakPeek observes local logs and can send replies through explicitly connected approval adapters. It is a research prototype, not a security boundary. Anyone able to modify its state directory or provider logs operates within the local trust boundary. Do not expose the file transport to a network share or an untrusted account.

## Data handling

The observer retains visible prompt/message excerpts, project paths, session IDs, progress evidence, and approval inputs in local runtime files. It excludes private reasoning fields in known parsers. Unknown or changed provider schemas can break that assumption and need review. There is no application cloud upload or inference call in the observer. Provider CLIs run through the Codex adapter retain their own normal network behavior and model usage.

`runtime/`, build outputs, environment files, and preview screenshots are excluded from Git. Exclusion is not encryption or a retention policy: files can remain locally after the app exits. Review local filesystem permissions and delete sensitive state when no longer required. Share synthetic examples instead of raw runtime files or transcripts.

## Decisions and adapters

Connected decisions are bound to a request ID, agent ID, available choice, and expiry. The UI waits for source acknowledgement. A missing or expired reply never grants permission. Claude timeout returns to the host's normal permission handling. Codex cancellation/disconnection handling belongs to the included runner, not another client's session.

Antigravity, GitHub Copilot, and generic harnesses currently provide observation and source handoff; they do not accept executable approvals through SneakPeek. Adding a harness is data registration, not plugin execution. Logs and summaries are untrusted content and must never become commands or policy instructions.

Known gaps include no authenticated remote transport, no tamper-evident audit log, no enterprise authorization model, no bounded adversarial input/load guarantee, and no notarized distribution. See [the scaling proposal](docs/scaling.md) for future requirements.

## Reporting

For non-sensitive defects, open a GitHub issue with a synthetic reproduction. Do not publish credentials, real approval payloads, private sessions, or exploit details involving a currently exposed installation. For a sensitive report, use the repository's private vulnerability reporting facility if enabled; otherwise contact the repository owner privately to arrange a secure channel before sharing details.
