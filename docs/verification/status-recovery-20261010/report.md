# Desktop status and sign-in polish

Implemented and deployed October 10, 2026 (deployment timestamp October 11 UTC).

## Changes

- Desktop cards distinguish Ready, Preparing, Unavailable, Needs recovery, and Status unverified. Provider details are replaced with a safe explanation and a Settings help link. Failed or ambiguous seats are excluded from ready counts and cannot be opened or ended through these cards. Games sharing the same host also respect desktop recovery status.
- Each availability source tracks whether its last check succeeded and the last successful timestamp. Retained items remain visible after failures but their actions pause. Refresh requests do not overlap. An End session confirmation also becomes disabled if its target status becomes unverified while the dialog is open.
- Confirmed unauthenticated account responses and current HTTP 401 responses expire the browser session, clear its machine cache, and return the portal to sign-in with an explanation that Windows is still running. HTTP 503, malformed responses, and network errors do not establish sign-out. Initial account-check failures offer Retry instead of pretending the account is signed out.
- Authentication revisions and session versions reject older check results and old HTTP 401 responses after a new login. Login return destinations are limited to app routes.
- Settings sends friends to the standard EpicVM sign-in form and returns them to Settings after login. Administrator login remains a separate entry, preserving dashboard credential realms. Account navigation says Your workspace.

## Verification

Four Node tests passed, covering healthy and failed seat states, unknown states, safe copy, current versus obsolete HTTP 401 responses, and allowed sign-in return routes. Vite production build passed. Scoped git diff --check passed.

The dedicated automation Chrome was controlled through C:\Users\Epic\bin\browser-harness.cmd. The fixture server is tests/status_recovery.fixture.mjs and serves the actual built frontend. Browser assertions passed:

- Recovery errors, Error seats, offline hosts, and fresh successful status checks produce matching labels and disabled/enabled actions.
- Technical error details are absent from user copy. Recovery desktops and games on their host are excluded from ready counts.
- Failed availability retains cards, shows Status unverified and last-check time, disables actions, and restores readiness after a successful check.
- Background account HTTP 503 preserves the portal. Confirmed unauthenticated responses navigate to sign-in and clear cached machines.
- Account-session HTTP 503 shows verification failure without sign-out. HTTP 401 before a launch and during launch-job polling navigates to sign-in. Login returns to the workspace.
- A confirmation opened before status failure cannot end the stale session. Double refresh plus a ten-second poll during a twelve-second fixture delay never exceeds three concurrent availability requests, one per endpoint.
- Initial account-check HTTP 503 shows Retry; retry restores the workspace.
- Friend Settings entry contains no account-type selector, uses the standard sign-in form, retains the Settings return target, and returns there after login.
- Recovery content reflows at 390x844 with no horizontal overflow.

Jev judged the observed recovery page sufficient to establish that the desktop needs recovery and identifies who can help (DONE, confidence 1.0, 173 ms). This semantic check was separate from deterministic assertions.

Earlier screenshots recovery.png and unverified.png were opened and inspected. They were captured before the same-host game correction; recovery.png therefore shows an intermediate game-ready count and is not final-state evidence. Attempts to capture final/mobile and expired-session screenshots timed out. Final states were verified through browser DOM assertions instead.

## Deployment

Live baseline index SHA-256 was checked before swapping. Only the new hashed JS asset and scoped frontend sources were copied. Existing index metadata and the management-multiseat.js entry were preserved. The index asset reference was replaced atomically, and previous assets retained. No container restart or Docker build.

Asset: index-DzIjrG_q.js, SHA-256 348bff7dc46979fe0d683ad91df29f0e595a716803b68f5f52713f7c6bce097c.

Backup: /opt/blobe-vm/backups/status-recovery-20261011T021212Z. It contains the previous dist and scoped source originals; added-sources.json records sources absent from the deployment baseline. Rollback the live UI by atomically restoring backup/dist/index.html, whose old referenced assets remain available.

Live landing, sign-in, Settings, and the new asset returned HTTP 200. Downloaded JS matched the candidate SHA-256. Live browser verified the Settings entry, ordinary sign-in link, separate administrator link, and Your workspace navigation. blobedash remained healthy.

## Limits

Authenticated failure paths were simulated against the real frontend build. No production Windows seat, game launch, account, profile, or controller test was changed or exercised. No full accessibility or long reliability soak was performed. No commits or pushes.
