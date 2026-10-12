# Security and privacy

SneakPeek observes local logs and hands permissions back to the host UI by default. Unsigned file-based inline approval adapters require an explicit `--trusted-local-inline` opt-in. It is a research prototype, not a security boundary. Anyone able to modify its state directory or provider logs operates within the local trust boundary. A supervised agent able to write that directory can forge a human review, source lease, projected feed, or an opted-in approval. Supervisees must not be assumed trustworthy merely because they share your account. Do not expose the transport to a network share or an untrusted account.

## Data handling

The observer retains visible prompt/message excerpts, project paths, session IDs, progress evidence, and approval inputs in local runtime files. It excludes private reasoning fields in known parsers. Unknown or changed provider schemas can break that assumption and need review. There is no application cloud upload or inference call in the observer. Provider CLIs run through the Codex adapter retain their own normal network behavior and model usage.

Default state lives in `~/Library/Application Support/SneakPeek`, outside the checkout; explicit `--state` paths remain supported and old repo-local state is not automatically imported. Moving the directory avoids some agents’ workspace-write scope but does not prevent another process running as the same user from accessing it.

`runtime/`, build outputs, environment files, and preview screenshots are excluded from Git. Exclusion is not encryption or a retention policy: files can remain locally after the app exits. Review local filesystem permissions and delete sensitive state when no longer required. Share synthetic examples instead of raw runtime files or transcripts.

## Local references and file permissions

Agent-supplied paths and local file URLs are revealed in Finder, never launched
through their associated application. This includes scripts, application bundles,
Terminal profiles, aliases and symbolic links. HTTPS links open in the browser;
other schemes and remote file URLs are rejected. Antigravity artifact handoff
also reveals its validated local reference instead of opening it.

New native state directories use 0700 permissions, and native state and decision
files are created as 0600 before content is written and atomically replaced. The
owned default Application Support directory is repaired when written. Existing
explicit/shared directories are not chmodded implicitly; their files are still
private. POSIX permissions separate local accounts, not an agent sharing your UID.

Decision replies must be dated at or after the exact request's issue time, before
its expiry, and within clock-skew tolerance. A legacy request without an issue
time is not eligible for a file-based reply. This timing check is not identity
authentication.

Native check acceptance is recomputed and unsigned reviews/Taste are displayed as
claims, with zero authenticated acceptance. Production human signing is currently
unavailable. A distinct simulation app exercises native P-256 receipts with a
session-only software key and explicit mock biometry; all its acceptance labels
and counts say SIMULATION. It does not access Keychain, Secure Enclave or real
biometry, and its buttons are not evidence of human presence. The native app does
not fall back to the unsigned command writer for review, Taste or resolution.
The command writer remains an unsigned research transport.

See [the signing experiment and production release checklist](docs/human-action-simulation.md).
Real signing needs validated code identity, provisioned Keychain isolation,
explicit enrollment and hardware policy tests. No production signing or durable
trust storage is implemented in this branch. Source truth, completeness and
durable rollback resistance remain outside this simulation.

## Decisions and adapters

In trusted-local mode, connected decisions are bound to a request ID, agent ID, available choice, and expiry. The UI waits for source acknowledgement. These checks prevent accidental misrouting and expiry mistakes; they do not authenticate who wrote the reply. A missing or expired reply never grants permission. Claude timeout returns to the host's normal permission handling. Codex cancellation/disconnection handling belongs to the included runner, not another client's session.

Antigravity, GitHub Copilot, and generic harnesses currently provide observation and source handoff; they do not accept executable approvals through SneakPeek. Adding a harness is data registration, not plugin execution. Logs and summaries are untrusted content and must never become commands or policy instructions.

First-prompt goals are inferred, not human-confirmed. A local `source: human` field, sidecar review, record fingerprint, or green checkpoint is not proof of human identity. Connected `managed: true` JSON is no longer granted authenticated precedence, but both logs and source files remain forgeable within the local writer boundary. See [the Claude review and authentication design requirements](docs/claude-review.md).

Known gaps include no authenticated human-action or projection transport, no authenticated remote transport, no tamper-evident audit log, no enterprise authorization model, no bounded adversarial input/load guarantee, and no notarized distribution. See [the scaling proposal](docs/scaling.md) for future requirements.

## Reporting

For non-sensitive defects, open a GitHub issue with a synthetic reproduction. Do not publish credentials, real approval payloads, private sessions, or exploit details involving a currently exposed installation. For a sensitive report, use the repository's private vulnerability reporting facility if enabled; otherwise contact the repository owner privately to arrange a secure channel before sharing details.
