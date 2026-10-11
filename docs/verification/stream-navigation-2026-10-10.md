# Stream navigation fixes, 2026-10-10

- Replaced EpicVM Exit with Back to workspace. Disconnect is attempted, then navigation occurs even if teardown fails or stalls. Maximum teardown wait: three seconds. Windows session termination is not requested.
- Preparing handoff retains automatic checks and adds a workspace link, retry guidance, mobile viewport, and explanation that apps remain running.
- Provisioning and supervisor patches persist the control for existing and future EpicVM streams. Personal WindowsStream template remains unchanged.

Verification: 17 pytest checks passed across navigation, authorization, and supervisor suites. Node executed navigation for successful, false, thrown, rejected, and stalled stop responses. All five enabled host-local servers serve patched stream.js matching disk byte-for-byte; JavaScript syntax checks passed. Deployed dashboard module produces the updated preparing response in an isolated Flask test client. Dashboard restarted and is running/healthy; public landing returned HTTP 200. Supervisor restarted hidden with updated code.

Backups: /opt/blobe-vm/backups/navigation-20261010-171818/direct_stream.py and C:/Users/Epic/AppData/Local/EpicVM/direct-streams/source-backups/navigation-20261010-131739 per-route originals.

Limits: no live Windows stream or physical-input session was exercised. Automated checks verified navigation behavior, live-served files, and deployed preparing response without changing accounts or seat state.
