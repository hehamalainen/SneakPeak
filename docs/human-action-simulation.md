# Native human-action signing experiment

This is an interactive **simulation**, not production human authentication. It exercises the proposed app-as-broker flow without Developer ID, Secure Enclave, Keychain access, enrollment, or biometric prompts. A software P-256 key and its pinned public key exist only in the separate simulation app's memory. Quit discards the key and receipts. Normal SneakPeek builds have no signer and count **zero authenticated human acceptances**.

## Try the simulation

Build a separate app, without replacing or restarting your existing SneakPeek:

```sh
./scripts/build.sh --app /tmp/SneakPeek-Human-Action-Simulation.app \
  --scratch-path /tmp/sneakpeek-human-action-simulation-build \
  --bundle-id local.sneakpeek.human-actions.simulation
open /tmp/SneakPeek-Human-Action-Simulation.app
```

This bundle identity selects a dedicated window and a new temporary fixture on every launch. It ignores `--state` and other ordinary launch arguments; it starts no observer, writes no live approval heartbeat, imports no sidecars or signing keys, and has no live/demo switch or host-setup menu. Its bundle omits Python bridge scripts. It does not contact a model. Temporary synthetic artifacts remain until normal system temp cleanup; there is no private-key file.

1. Choose **Confirm mission in simulation**. The scrollable native confirmation shows the full goal, constraints, checks, kinds, required flags, age rules, and digest.
2. Choose **Simulate successful Touch ID**. **Cancel** produces no receipt. This button is an explicit test input: automation can click it, so it proves no human presence.
3. Use **Check met** on the synthetic local result. Its exact evidence summary, reference, artifact SHA-256 and decision appear in the confirmation. The native app rechecks context and file bytes after the confirmation.
4. Add **Taste**, select the presentation check, mark it met, and optionally request review. The count becomes **2 of 2 checks · SIMULATED**, while authenticated human approvals remain zero.
5. Open **Review queue** to keep/change/dismiss that Taste concern. The confirmation includes the request text and outcome. No host permission is issued.

The example result file can be inspected using **Show in Finder**. If you change its bytes, delete it, or corrupt the fixture feed, the next refresh clears simulated acceptance. Closing and reopening the app starts a new untrusted session.

## What the experiment implements

The native app creates typed actions for definition confirmation, evidence review, Taste, and judgment resolution. A canonical UTF-8 length-prefixed payload binds a protocol domain/version, installation/key identity, sequence, previous receipt digest, nonce, issue/expiry milliseconds, mission, full definition digest and confirmation epoch, check, exact subject digest, decision and note/Taste fields. Signatures use CryptoKit P-256/SHA-256. The current session pins the verification key; records cannot nominate a replacement key.

The first click prepares an action; only its exact pending action can receive the explicit mock biometric success. Cancellation, expiry, changed mission context, changed evidence, replay, unknown version or malformed signature cannot issue/validate a receipt. An action has a two-minute confirmation window. Completed receipts remain useful while the goal/evidence remain current; their confirmation expiry is not an expiration of the recorded judgment.

Native acceptance is rebuilt independently of `state.json` statuses, counts, supplied fingerprints, `source: human`, resolved flags, or signed-looking fields. The app recomputes the source goal revision from content and binds all acceptance rules, including required flags, evidence age limits, check kind, workspace and constraints. A new confirmed definition invalidates earlier judgments even if the text later reverts. Signed Taste requests are reconstructed from receipts, so a forged resolved flag or omitted queue item cannot erase them. Resolutions apply only to Taste/judgment items, never host requests.

For evidence, the native app validates the exact mission/check/goal and hashes the current local regular file through an open descriptor. It checks recorded size/time, rejects final symlinks and files over 16 MiB, detects replacement during inspection, and compares content SHA-256. Local file URLs get the same checks as paths. HTTPS references remain inspectable unsigned claims; authenticating remote mutable content needs a later snapshot design. File hashing runs on refresh in this small fixture, not a production-scale cache.

The ordinary app displays outside evidence and Taste as unsigned claims and clears their alleged acceptance. Its native review/Taste/resolution buttons report authentication unavailable rather than writing an unsigned substitute. The Python research commands still create unsigned claims; their projections are not a trusted native acceptance authority. Host permission behavior, including the pre-existing explicitly opted-in unsafe local experiment, is unchanged.

Tests cover real software P-256 signature verification and mock confirmation, malicious projection fields, substituted keys, tampered/copied receipts, nonce/sequence replay, definition/check changes, evidence metadata forgery, same-size content replacement with restored mtime, unavailable artifacts, cancelled/expired confirmations, stale-feed clearing, Taste resolution and host-request preservation. These are not Secure Enclave, biometric, code-signing or deployment tests.

## Pushback and production release requirement

The app-as-broker design is reasonable for this research direction, but a signature alone does not establish human intent. The proposed production upgrade remains disabled until the following GitHub acceptance checklist is completed:

- [ ] Choose and review the exact Team ID, app identifier, designated requirement, entitlements and protected install/update path. Require a valid Developer ID signature and hardened runtime, reject ad-hoc/replaced code and unsafe runtime entitlements, and validate the resulting release bundle. A Developer ID certificate alone is insufficient.
- [ ] Provision the app's private data-protection Keychain access group, with the appropriate embedded provisioning profile. Explicit enrollment must pin installation/public-key identity inside that protected store, not beside agent-writable JSON. The enrolled key must not be silently replaced on rebuild or missing-state recovery.
- [ ] Implement Secure Enclave P-256 signing with `privateKeyUsage` and `biometryCurrentSet`, a fresh `LAContext` for each action, reuse duration zero and invalidation afterward. Do not add password, watch, software-key or unsigned acceptance fallback. Confirm the effective policy on supported hardware; no-hardware/no-biometry/lockout/cancel/error remains unavailable.
- [ ] Keep the exact frozen action in trusted native UI through confirmation. LocalAuthentication authenticates key use; its prompt is not a trusted display of the whole document and does not prove the person understood or intended every byte. Synthetic clicks alone must not sign, but the simulator's explicit success button is intentionally automatable.
- [ ] Test real signed installation, access-group isolation, substituted/re-signed app, lost/changed enrollment, cancel/lockout, repeated actions and a change during the biometric prompt on supported Macs. Do not claim a fresh physical sensor press per signature until that policy has been tested.
- [ ] Decide the minimal durable receipt and antirollback policy before persisting trust. This prototype has no restart recovery, revocation, durable audit trail or source completeness guarantee. Agent-writable logs can still omit evidence or lie about what happened. A valid human signature binds the reviewed snapshot; it does not authenticate the original host or prove mission truth.

No CLI, IPC, URL handler or file-watched signing endpoint is included. Host authorization remains with the host UI. A trusted signer/request protocol for host permissions is a separate feature.

Apple's primary documentation supports the building blocks, not a claim that this prototype has deployed them:

- [Protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave) describes hardware support, enclave-generated P-256 keys and private-key access controls.
- [TN3137: On Mac keychains](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) distinguishes file-based ACLs from the data-protection Keychain and explains entitlement/provisioning requirements. Merely using “the Keychain” does not select the required isolation model.
- [Understanding the code signature](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/AboutCS/AboutCS.html) explains code identity and validity checks; those checks and a protected installation must precede trusting enrollment.
- [LocalAuthentication context](https://developer.apple.com/documentation/localauthentication/lacontext) documents authentication contexts and reuse controls. The exact-action display and policy binding remain application responsibilities.

The read-only development identity check found zero valid local code-signing identities. That does not determine Apple Developer membership. No certificates, real keys, enrollment, security settings or installed apps were changed for this experiment.
