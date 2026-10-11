# Production first-time friend flow

Disposable account: qa_friend_1791653028. Created through the real public signup form in the dedicated automation Chrome. Random password never printed; temporary credential file removed after testing.

Observed results:

1. Signup succeeded and showed the pending-access screen.
2. Administrator setup approved the account and assigned epic-pc without VM provisioning. This was performed through existing backend helpers/database access, not through an administrator browser UI.
3. Pending approval invalidates the old login session. The already-open page stayed pending; signing in again succeeded and reached the workspace. Polling currently ignores anonymous results, leaving stale pending content.
4. Assigned desktop appeared expanded and ready. VM/library checks exceeded their 15-second frontend deadlines, producing availability warnings. Server logs later showed successful responses for those checks.
5. Open desktop hit the two-minute browser request deadline. A Windows seat and host-game stream record eventually existed, and Resume desktop appeared.
6. One explicit Resume desktop attempt also hit the two-minute deadline. Browser never reached the actual stream. Reconnect, rendered Windows content, and Back to workspace remain unverified in this run.
7. Host-stream supervisor logs include SSH timeouts syncing remote stream instances. The QA route was not present in the local published routes when inspected. These are diagnostic observations; the precise launch bottleneck is not established.

Cleanup: QA account disabled, desktop grant removed, host-agent stop acknowledged status stopped / ok true. Saved Windows profile retained. Staged stream quarantine and record cleanup performed separately. Existing users and seats were not selected for stop.

Evidence: friend-flow-launch-timeout.png, inspected after capture; production browser DOM and server log responses. No claim of successful end-to-end streaming or measured input latency.

Next priorities: diagnose the launch/handoff bottleneck; give stale approval sessions explicit sign-in recovery; avoid irrelevant VM timeout noise in desktop-only workspaces.
