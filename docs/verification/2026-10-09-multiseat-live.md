# MultiSeat live verification, October 9, 2026

Result: **FAIL. Not ready for a friend release.**

Follow-up: Epic subsequently requested removal of the storage threshold. The
20 GiB / 85% check was removed from both Moonlight and Guacamole orchestration
in the workspace and deployed dashboard source. The dashboard was restarted,
and all 42 orchestration tests passed. The disk-gate failure below describes
the earlier verification run; it is no longer a configured staging restriction.
Rollback source backups are retained at
`/opt/blobe-vm/backups/storage-threshold-20261009T211931Z` on KVM2.
Live staging inside the restarted production container passed with 12.45 GiB
free and 87.01% disk usage, using its actual routing and ownership checks in a
temporary bundle directory. This staging-only check did not start a seat or
retest video capture; the earlier test seats had already been stopped.

## Scope and method

Epic authorized production testing. Two temporary identities, `qa1009a` and
`qa1009b`, used the real Windows MultiSeat service, agent, Apollo instances,
Moonlight stream orchestration, host stream supervisor, public HTTPS gateway,
and Chrome browser. Browser contexts were separate for the two users.

The main production dashboard was not replaced. A temporary process inside its
container used a separate account database, the candidate frontend build, and
the deployed backend with the scoped seat-preservation fix. It was accessible
through a localhost SSH tunnel. These results do not establish that the candidate
changes have been deployed to the main dashboard.

The normal 20 GiB free / under 85% disk-use gate blocked initial stream setup.
KVM2 reported approximately 13 GiB available and 88% usage. Only the temporary
test process used a 2 GiB reserve to continue transport testing. The production
threshold was unchanged. Therefore the normal production launch path still fails.

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| First native seat creation | Pass | Seat A reached Ready, session 2, port base 48100. |
| Second native seat creation | Pass | Seat B reached Streaming, session 3, port base 48130. |
| Account stream ownership | Pass | A opening B's stream and B opening A's stream both returned HTTP 403. |
| First seat video | Partial | A rendered a nonblack 1920x1080 Windows first-login privacy screen through WebRTC. Sample nonblack fraction 1.0, mean luma 222.58, luma standard deviation 26.04. |
| Mouse input on first seat | Pass | Clicking the Location switch changed Yes to No in the streamed image. A's canvas-drawn frame count advanced from 1167 to 1209. |
| Concurrent useful desktops | Fail | While A had a visible image, B decoded and drew 1063 frames with zero decoder errors, but its image had nonblack fraction 0, mean luma 0, standard deviation 0. |
| Browser disconnect and resume | Partial | A returned through the same stream route and retained its native seat ID. B continued receiving frames during A's disconnect. After reconnection, A was black while B became nonblack. |
| Independent desktop capture | Unproven | Both seats had null displayDevicePath; the display API reported totalConnected=0, paths=[], sudoVdaFound=true. No two simultaneously usable captured desktops were demonstrated. |
| First-login experience | Fail | The visible test desktop showed Windows privacy setup rather than a finished desktop. |
| Clean test shutdown | Pass | Both account stop requests returned HTTP 200. No QA seats remained active. QA Windows accounts were disabled; their profiles were retained. |

The final sample showed B drawing 2334 frames with zero decoder errors and
nonblack fraction 1.0 / mean luma 223.03, while A's captured canvas was black.
This is a failed concurrent-desktop acceptance test, even though both browser
stream pages loaded and frame counters advanced. A clean image following a
reconnect was not established for A.

## Operational repairs made during testing

- Installed the repository's missing inbound UDP firewall rule for ports
  40900-41199. The installer verified the rule and reported `ok`.
- Started the existing Caddy executable with the existing WindowsStream
  configuration. It had been absent, with no listener on its administration
  endpoint, causing the stream supervisor's route publication to fail.

These repairs were left in place. This run did not verify recovery after a host
reboot or make a new Caddy startup configuration.

## Remaining release blockers

1. The earlier storage restriction was removed at Epic's request after this run.
   It no longer blocks stream staging.
2. Establish per-seat virtual display allocation and capture. Confirm two
   independent nonblack desktops simultaneously, including during reconnect.
3. Complete first-login setup for newly created seat accounts.
4. Repeat video, keyboard/mouse input, browser disconnect, concurrent capture,
   and recovery checks with the final deployed changes. Audio and gamepad input
   were not verified in this run.

## Evidence

Sanitized API/frame samples and screenshots are saved under
`recovery-evidence/multiseat-live-20261009/`. No passwords, tokens, signing keys,
cookies, or raw pairing databases are included.

Your existing account was not changed. The main dashboard, Windows agent, and
MultiSeat service remained healthy after cleanup.

## Follow-up repair and verification, October 9

Epic accepted the Windows privacy setup flow. Its temporary machine policy
change was restored; no first-login bypass is shipped. Test-only profile
settings affected the two disposable accounts.

Apollo streams each seat's RDP session surface in this configuration. An empty
`displayDevicePath` does not by itself prove capture failed. The installed
display diagnostic also failed to write its console-session result, while
running the helper directly succeeded. No MultiSeat binary or driver was
replaced during this follow-up.

Two concrete reconnect defects were repaired:

- Apollo gives replacement paired clients only list/view permissions. EpicVM
  now completes the pairing handshake, then identifies the single new client
  against the previous UUID list and grants list/view/launch and input rights.
  The pending UUID snapshot is stored privately with a two-minute expiry so
  it survives the agent's separate mutation workers. Client commands remain
  disabled. An ambiguous client list fails closed.
- The direct-stream supervisor now recreates a disabled route even when its
  previous config directory was quarantined. Previously its missing config
  aborted every sync cycle.

The earlier seat-preservation and Resume desktop changes are now deployed to
the main dashboard. Existing production cleanup/error handling was retained.

| Live check | Result |
| --- | --- |
| Simultaneous desktops | Both rendered distinct 1920x1080 desktops, with different wallpapers and separate A/B test windows. Canvas sample mean RGB values were approximately 145 and 147 after reconnect. |
| Keyboard isolation | A displayed `alpha`, B displayed `bravo`; screenshots confirmed the text stayed in the intended seat. |
| Audio isolation | Simultaneous 440/880 Hz test tones measured approximately 445.3/878.9 Hz through each browser's received WebRTC audio track. |
| Disconnect and resume | A retained seat ID `95552de2-04d9-4c52-b4e5-6636f4c19069` and its typed text. B remained visible; drawn frames advanced from 3921 to 3956 during the disconnect check and later reached 5247. Both remained nonblack after A resumed. |
| Owner enforcement | Cross-account stream requests returned 403 in both directions. |
| Pairing completion | A replacement B client completed pairing and permission setup through the candidate dashboard and deployed agent. |
| Production deployment | Main backend and built frontend deployed; served HTML references `index-f2iE0rOO.js` and that asset returns 200. Container remains healthy with its previous image. |
| Cleanup | No QA seats or sessions remained. Both test Windows accounts disabled; profiles retained. Isolated browser contexts and SSH tunnel closed; test credentials removed. Both Windows services remain Running. |

Validation: 55 targeted Python tests and 9 HostGaming Pester tests passed.
Jev selected the observed stream statistics control, followed by a deterministic
check of the resulting live counters. No gaming-performance, gamepad, or
host-reboot certification is claimed. Static-desktop frame rates do not establish
gameplay performance. The initial first-login capture race was observed but was
not independently fixed in MultiSeat; final acceptance checks used initialized
test profiles.

Dashboard rollback snapshot:
`/opt/blobe-vm/backups/multiseat-reconnect-20261009`.
Agent rollback copies are beside the installed scripts in
`C:\ProgramData\EpicVM\agent`. Follow-up evidence files have the `followup-`
prefix in the existing evidence directory.

## Post-reboot verification

After Epic rebooted, MultiSeat and the remote agent started automatically.
The direct-stream supervisor and Caddy were absent. Manually starting the
existing starter worked; the precise reason the Startup shortcut failed is
unconfirmed. A logon task now replaces that shortcut, and the supervisor
validates and starts a missing Caddy gateway. It preserves an existing Caddy
process and reports an unavailable admin listener for inspection.

The installed logon task ran successfully with `LastTaskResult=0`. Automatic
execution after a subsequent reboot remains untested.

Two fresh seats launched using deployed dashboard code and the deployed
agent, without manually restarting Apollo. Both streamed the normal privacy
setup and reached distinct 1920x1080 desktops after accepting it. No privacy
bypass was added. Seat A was `02a045b3-726e-49b8-bd74-5c4a5be74abf`; seat B
was `5aa59886-8b0e-4506-93cd-c323d3c4d8f7`.

Disconnecting and resuming A returned HTTP 200 and retained its seat ID and
visible typed text. B's drawn-frame counter advanced from 3374 to 3555 during
the first disconnect, then to 4590 during the later reconnect check. Final
canvas samples were nonblack at 99.96% and 100%, with mean RGB values 104.39
and 108.20. Input stayed in the intended A/B test windows. Rapid synthetic
typing immediately after mouse focus omitted the first character in both
samples (`lpha` and `ravo`); this run does not certify every keystroke timing.
Both cross-account stream requests returned 403.

The 12 supervisor regression tests passed. Jev selected the observed Stats
control, then live counters were checked independently. Reboot evidence uses
the `reboot-` prefix in the existing evidence directory.

ViGEmBus and HidHide drivers are Running. MultiSeat currently has
`EnableHidHideCloaking=false`, and its event log warns that Apollo pads are
visible across host sessions. Gamepad isolation and simultaneous gameplay
are not verified. No driver or MultiSeat binary changes were made.

Cleanup confirmed no QA Windows sessions remained; both QA accounts are
disabled. Test routes were quarantined, browser contexts and the isolated
dashboard were closed, and the SSH tunnel stopped. Server/container test
credentials were deleted. Automatic approval review rejected deletion of
`%TEMP%\epicvm-live-qa-1009\credentials.json` with only “blocked by policy”;
that local temporary file remains. The isolated server is stopped. Both
Windows services are Running and the production container is healthy.

## Controller follow-up

The ViGEmBus service was Running but no Nefarius bus device existed. The
Oculus bus is a different device and was preserved. Restoring the root device
and binding the installed ViGEm INF produced a healthy
`ROOT\SYSTEM\0004` Nefarius bus. A timed-out inspection/repair call later left
an unbound `ROOT\SYSTEM\0005` node; that exact orphan was removed after its
hardware ID and empty name were checked. The repair script's repeat run then
found one healthy bus and made no changes. PowerShell syntax validation passed.

Before repair, Apollo logged `Couldn't setup connection to ViGEm for gamepad
support [E0000001]`. After repair, browser-simulated controller arrivals created
two Xbox pads. Apollo was also restarted in the two QA seats to rule out its
initial missing-bus state. No personal-session Apollo was restarted.

Native XInput probes initially saw both controllers in sessions 4 and 5.
Test-only HidHide rules for both the XUSB and HID nodes confined the observed
pad 01 to session 4 and pad 02 to session 5. Fresh probes then saw only XInput
index 0 in session 4 and index 1 in session 5. This proves confinement for
those observed devices; it does not prove automatic ownership or reconnect
isolation. Device paths changed across reconnects, including HID interface
paths within reused XUSB container paths. The installed MultiSeat invokes
`CloakForSession` only at provisioning, before Apollo's controller arrival.

Browser-simulated button/stick reports were attempted through open controller
WebRTC channels. Native probes continued to report neutral buttons/sticks.
This forwarding test failed, even after restarting both QA Apollo instances.
Physical-controller input, rumble, and gameplay responsiveness remain untested.

The EpicVM native game catalog was empty. Direct API launches of the installed
Undertale executable returned success and briefly produced processes in both
seats, but the processes did not remain running and no playable game was
captured. Simultaneous gameplay is therefore not certified.

All four test-only HidHide rules were removed and cloaking restored to off.
The CLI write/restore calls exceeded their remote timeouts, so their final
state was checked separately with `--cloak-state --dev-list --cancel`. Both QA
seats and Windows sessions were removed, QA accounts disabled, browser contexts
closed, isolated server stopped, and SSH tunnel closed. The healthy Nefarius bus
repair remains installed. The existing local temporary credential-file deletion
restriction still applies; server/container credentials were removed again.

Remaining implementation work: diagnose the browser-to-Apollo controller-state
path and establish deterministic controller ownership before device creation.
Enabling the two HidHide configuration flags alone does not resolve either gap.
