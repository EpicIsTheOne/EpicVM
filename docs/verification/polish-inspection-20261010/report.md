# EpicVM polish inspection

Inspected the current repository and live site on 2026-10-10. No product code or production state changed.

## Captured steps

1. Open the workspace while signed out. It redirects to Sign In correctly. The desktop form is clear and renders completely. Screenshot: [01-current.png](01-current.png).
2. Inspect Sign In at 390 by 844. The form fits without horizontal overflow (document width and viewport width both 390). Screenshot: [02-signin-mobile.png](02-signin-mobile.png).
3. Open Settings while signed out at the same mobile viewport. It renders a second login form with an account-type selector exposing Dashboard administrator to ordinary visitors. It fits, but uses a different sign-in experience and calls the workspace My machines. Screenshot: [03-settings-mobile.png](03-settings-mobile.png).

All three saved screenshots were opened and inspected. Jev independently identified the observed Settings page as blocked pending sign-in (confidence 0.86); no credentials or form submissions were attempted.

## Recommended pass: clear status and sign-in recovery

### 1. Explain desktop recovery states

Source-confirmed: dashboard/shared_games.py returns desktop.errorMessage for unavailable hosts and duplicate seats needing administrator recovery. The duplicate-seat branch can retain available=true. AvailableGames in SharedGames.jsx renders desktop.available as Ready and ignores desktop.errorMessage and seat.errorMessage. An affected friend sees a Ready card with no recovery explanation before a launch fails.

Render safe user-facing reasons, distinguish a failed seat from a healthy existing session, and direct administrator-only recovery to Epic. Verify each state with deterministic fixtures before a disposable live account check.

### 2. Recover from expired sign-in and stale availability

Source-confirmed: App.jsx background account polling only updates user when next is truthy. A successful account check returning an unauthenticated response therefore leaves the old portal visible. SharedGames.jsx retains previous successful data when availability requests reject. Cards can continue showing Ready alongside a generic Some availability checks failed message. Launch commands explain expired sign-in, but their recovery controls are Check status and Try opening again, without a Sign in action.

Handle confirmed authentication expiry centrally, preserve the return destination, distinguish network failure from sign-out, and mark retained availability as unverified with a last successful check time. Overlapping refreshes should not let older responses overwrite newer state.

### 3. Simplify the friend-facing account entry

Live-confirmed: Sign In and Settings have separate login presentations. Settings exposes an account-type choice including Dashboard administrator. Prefer one ordinary friend sign-in flow with a separate administrator entry; use Your workspace consistently in navigation.

## Accessibility and limits

Sign In inputs have associated wrapping labels and errors use role=alert. The surrounding evm-input has focus-within border and shadow styles. Mobile screenshots establish layout fit, not accessibility compliance; keyboard traversal and assistive technology were not tested.

The automation profile is signed out after previous QA cleanup. Authenticated desktop cards, runtime session expiry, and launch behavior were not exercised in this inspection. Desktop-status and stale-session findings are source-confirmed, not reproduced production failures. Controller work remains deferred. No new account, desktop, deployment, or outage was created.

![Desktop sign-in](01-current.png)

![Mobile sign-in](02-signin-mobile.png)

![Mobile settings entry](03-settings-mobile.png)
