# Claude adversarial review follow-up

The subsequent [native signing simulation](human-action-simulation.md) now strips
unsigned acceptance in the native client and exercises definition/evidence-bound
receipts in a separate app. It uses an ephemeral software key and mock biometry;
the real signed-release/Keychain/Secure Enclave path remains unavailable. The
findings below describe the underlying unsigned transport, which is retained as
research input rather than a native human-authentication authority.

This branch follows merged main `84c0ccb`, which includes Copilot fix `ad4ded0` and mission/Taste features, not the older reviewed `e5d56d7`. Mission/Taste replaces bare checkpoint verification with evidence records and reviews bound to goal revision and record fingerprint. Those bindings address stale and mismatched evidence; they do not authenticate the reviewer. The integration retains the sidecar transport and does not restore legacy verification code.

## Findings and disposition

| Finding | Verified scope | Change / remaining boundary |
| --- | --- | --- |
| Peer-written permission file grants access | Reproduced with synthetic decisions; no dangerous command executes | Default Claude hook returns no permission, low-level reader rejects replies without opt-in, managed Codex runner refuses before starting a child. `--trusted-local-inline` retains the explicitly unsafe local experiment. |
| Forged human verification | Bare verification is rejected by mission tracking, but a forged goal/fingerprint-bound sidecar is accepted; full feed remains same-writer data | Not authenticated. The inspector states that reviews are unsigned local records. Evidence fingerprints/goal revisions are content-binding, not identity proof. |
| `managed: true` masks observed concerns | Fresh/active lease restriction alone remained forgeable | Removed unconditional lease precedence. Preserve observed goals, unresolved attention/requests, and observed risk; conflicting source or progress claims require inspection. Original logs/feed can still be forged by a writer. |
| State inside supervised checkout | Default app, runner, publisher and generated hooks used repo `runtime/` | Defaults now agree on `~/Library/Application Support/SneakPeek`. Explicit alternate state remains supported; no automatic import of old data. |
| Raw Markdown snippets | Compact excerpts retained formatting syntax | Strip common emphasis, code, heading/list and link syntax in display compaction. Never transform approval tool inputs, truncate them, or execute markup. |
| Goal taken from first prompt | Confirmed across transcript parsers | `goalOrigin: first-prompt` shown as inferred. Explicit generic goals are source-reported, managed launch arguments are labeled, native saved edits are local-edit. These labels are provenance claims, not signatures. |
| Old progress appears current | Newer-overlay conflict was fixed, age was already visible, but labels had no expiry | Course claims older than one hour, missing a timestamp, or more than five seconds future-dated become unknown/stale. Retain evidence, original trajectory and timestamp. |

The synthetic tests explicitly preserve a demonstration of the remaining forged-review vulnerability. Passing tests does not mean that human identity or the projected feed is secure. None of the probes launches a model or executes the example permission input.

## Defaults and migration

Run `scripts/run.sh` without a state override to use Application Support. Python observer, publisher, registry, connector, managed runner, and settings generators use the same default. `scripts/run.sh` no longer appends a repo state argument or overrides an explicit user choice. The application still accepts `--state /absolute/path/state.json` for isolated demos, tests, or a deliberately selected store.

Quit and restart after upgrading. Existing active hook configurations may still point to the old bundled script and repo-local store. Regenerate the per-invocation Claude settings and reconnect observation hooks, preserving unrelated host hooks. Do not copy old approval decisions or source leases into the new directory. If goals/settings are needed, manually review and migrate those records while the observer is stopped. Leaving old runtime files in place is not deletion or encryption.

Default Claude settings omit `--trusted-local-inline`; its permission hook immediately leaves the original host flow intact. The Codex runner needs that explicit flag because its owned app-server has no separate human UI to receive a default handoff. Without it, the runner exits before launching Codex and directs the user to the normal Codex interface. Ordinary transcript/hook observation remains available. The notch shows executable choices only for a marked opted-in source (or a synthetic Demo); that marker is not an authentication token.

Opt-in is an adapter invocation argument, not a mutable runtime setting. A writer who can change the adapter invocation, hook config, source code or binary can still bypass it. This mitigation assumes trusted host configuration and code; it is not a hostile same-account isolation boundary.

## What an authenticated version actually requires

Secure Enclave signing is a plausible component, not a complete fix by itself. Apple documents hardware-backed P-256 operations and Keychain access control; access to key material or to a signing operation still needs a protected caller identity and policy. The current bundle is ad-hoc signed, runs as the same user, and loads writable Python scripts. This branch creates no keys and displays no biometric prompts.

A complete implementation should be reviewed as one protocol:

1. Install the supervisor/broker and host adapters outside supervisees' write access. Protect their code, configuration, enrollment and trusted public keys. A replaceable public key beside a JSON signature allows an attacker to substitute both. App identity and appropriate Keychain access controls must survive rebuilds and upgrades without automatically enrolling arbitrary replacement code.
2. Authenticate request producers and their authoritative host events. A human signature over an attacker-forged request is still a valid signature over the wrong operation. The host adapter must keep the exact outstanding request, nonce, scope, tool-input digest and expiry, and compare those before applying a response.
3. Sign explicit typed actions with domain separation and canonical encoding: protocol version, installation/actor, action kind, exact request and agent identity, mission/criterion/goal revision, evidence fingerprint and decision, issue/expiry times, and one-use nonce. Do not equate a callback or mutable `source: human` field with a signed action. Optional or mandatory user presence must be a deliberate policy; silent signatures from a callable helper do not prove human intent.
4. Verify at every trust consumer. Host adapters verify permission signatures against protected pinned keys and the outstanding request; the native client independently verifies review/action provenance and recomputes projections or receives an authenticated projection. Signing a sidecar while trusting an unsigned `state.json` does not prevent false green checkpoints.
5. Reject unsigned, unknown-key, wrong-context, replayed, expired, downgraded, malformed or unsupported envelopes. Missing hardware, lost keys, denied authentication and process failure return to host permissions. Never silently fall back to unsigned accept. Key rotation, recovery and revoked installation IDs need explicit enrollment and test cases.
6. Add independent adversarial tests for key substitution, forged requests/projections, signing-oracle calls, replay, file replacement, producer disconnect, upgrade/key migration and hardware/Touch ID failure. Mock cryptographic tests do not validate Secure Enclave policy or trusted deployment.

An isolated authenticated IPC/broker or properly sandboxed host connection may be a better first implementation than extending writable JSON. Moving the files is useful exposure reduction, but an agent with general same-account filesystem access can still read or overwrite them. The retained local mode is unsuitable as a boundary against that agent.

Primary references: [Apple: protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave), [Apple: Keychain app access groups and code identity](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps), [Apple: user presence access control](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/userpresence). These support the key and caller constraints; they do not certify this prototype. No OpenSSL verification/signing integration is shipped or claimed here.

## Handoff for further mission work

This integration keeps the sidecar evidence/review/definition writer, stable checkpoint IDs, and goal/fingerprint binding. `goalOrigin` is present in the model and retained when inferred missions are pinned; native definition edits set `local-edit`. This metadata is not part of evidence truth. Both permission views require the opt-in marker and retain source handoff. Signed human provenance remains outstanding for sidecar reviews, Taste decisions, and the entire feed.

Apply Application Support defaults to any new command parsers, and retain explicit state paths for all synthetic tests/previews. Source validation must include optional metadata introduced here. Preserve the source scope, live approval-surface heartbeat, mode-bound sends, log replacement detection, optimistic definition locking, invalid-record isolation and acknowledgement rules from Copilot fixes.
