# Local security hardening 1.2.2

Base: 8dc5576bbc2fc9c76d9b190b731f26cf001021c3. Local branch: codex/security-hardening.

## Changes

- Cross-process lock serializes GUI, CLI, and credential-sensitive queries.
- Enrollment has durable state and a fresh staging directory. Ordinary switches are rejected until it is completed or cancelled.
- Shared auth uses an exact rollback checkpoint; stale active markers are cleared before replacement.
- GUI synchronizes authoritative persisted state after operations and when the menu opens.
- OpenAI Developer ID signatures and bundled helper are verified before credentials are provided.
- Active usage is read-only external-token authentication; inactive usage preserves refresh state on RPC errors and detects writeback conflicts.
- Queries have private environment/cwd, explicit credential storage, bounded cleanup and safe errors.
- Background refresh supports off / 1 / 5 / 15 minutes (default 5), wake refresh and query timestamps.
- Official browser login and MFA can enroll an inactive slot without closing the current desktop, via `gpt-switcher login account-b`.
- `gpt-switcher adopt-current account-a` imports the existing login without changing shared auth; it rejects an already occupied slot.
- Browser enrollment refuses occupied or orphaned credential slots; newly configured slots receive available shortcuts without replacing user preferences.
- `gpt-switcher verify-accounts` compares local account IDs privately and reports only slot-level distinct/duplicate/unverifiable results.
- Signature and binary capability scans use bounded autorelease pools to avoid retaining large scan buffers.
- The build embeds a public-source hash manifest. No credential contents are included.

## Validation

56 tests in 6 suites passed on macOS 27 / Apple Silicon; tests use dummy credentials and controlled subprocesses. Local release build and installed bundle signature validation passed. Manual integration checks covered importing an existing login without exiting Codex, official browser enrollment, usage queries, and local account-ID comparison. A user-reported desktop switch succeeded; a complete automated desktop round trip has not been validated.

Installed GUI background physical footprint measured approximately 25–41 MiB in short-run observations, versus 173 MiB before scan optimization. Idle CPU was 0.0% at sampling. These samples exclude the official app, browser and query helpers, and are not a sustained memory bound.

## Known boundaries

Locally stored snapshots remain plaintext protected by filesystem permissions, not encrypted Keychain entries. Local build uses ad-hoc signing, not Apple notarization. Shared local history is intentionally visible across account switches. Manually changing the official app's login outside Switcher can invalidate its labels; use deliberate enrollment and verify the official profile after switching. Closing the desktop may interrupt active tasks. MFA is completed directly with OpenAI; the tool never collects passwords or OTPs.

If browser OAuth succeeds but importing the credential or saving configuration fails, enrollment has no automatic recovery transaction; an orphaned slot is protected from overwrite and requires explicit recovery or re-enrollment.
