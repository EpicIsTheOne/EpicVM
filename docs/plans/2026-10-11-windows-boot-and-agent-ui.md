# Windows boot hosting and EpicVM Agent UI

Status: implemented and installed on the existing enrolled host. Cold-boot video
and input verification remains pending. See `../verification/host-agent-20261011.md`.

## Outcome

After Windows boots, friends can sign into the hosted portal and open their own
multiseat desktop without the host operator signing into Windows. After the
operator signs in, an EpicVM Agent desktop app provides local status, settings,
session management and diagnostics. Closing that app leaves hosting running.

This starts at Windows boot, after disk unlock and network availability. It does
not power on a sleeping/offline PC or bypass BitLocker pre-boot authentication.
Friend seat sessions still sign into their own Windows accounts through MultiSeat.
The operator account does not need automatic login.

## Current evidence

Inspected live services and scheduled tasks on 2026-10-11:

| Component | Current startup | Required work |
| --- | --- | --- |
| EpicVMRemoteAgent | Automatic, LocalSystem | Retain; add readiness/recovery and a local management boundary |
| MultiSeatService | Automatic, LocalSystem | Retain; verify seat creation/capture before operator login |
| SunshineService | Automatic, LocalSystem | Retain; distinguish console capture from independent multiseat capture |
| Tailscale | Automatic, LocalSystem | Retry agent binding until its address is available |
| EpicVM Direct Streams | Interactive Epic logon task, 15-second delay | Replace with a machine service |
| Stream supervisor, auth gateway, viewer processes | Spawned from the interactive task | Supervise before login with managed machine runtimes |
| Normal/LAN Caddy | User-profile binaries/state; started by scripts | Configure explicit machine-accessible binaries, state and credentials |

The agent already uses a managed PowerShell runtime at
`C:\ProgramData\EpicVM\agent\pwsh7\pwsh.exe`. Its existing service wrapper can
be reused. The stream starter resolves Store Python through `py -3.13`, reads
`LOCALAPPDATA`, and launches source from the development checkout. The supervisor
hardcodes Epic's Caddy binary, E: project paths, host identity, public origin,
KVM2 SSH details and the Moonlight package location. Inventory, bundle import and
manifest publication use SSH/SCP under the interactive account.

These are runtime/deployment dependencies, not only a missing boot trigger.
Running the current task as SYSTEM would change its profile, certificate storage,
SSH identity and Python resolution without fixing those dependencies.

Source inspected: `scripts/Install-EpicVMDirectStreamsStartup.ps1`,
`Start-EpicVMDirectStreams.ps1`, `Start-EpicVMLocalGateway.ps1`,
`supervise_host_direct_streams.py`, `host_stream_gateway.py`,
`remote_agent/windows/install.ps1`, `ServiceRuntime.ps1`, `EpicVM.Agent.ps1`
and `HostGaming.ps1`.

## Runtime design

1. Keep privileged seat/Hyper-V operations in the existing agent and MultiSeat
   services. Add an `EpicVMHostRuntime` service for gateway/viewer orchestration,
   with its own service identity and only the file/process/network access it
   needs. Do not elevate Caddy or viewer binaries to LocalSystem to simplify setup.
2. Install immutable binaries/runtime under Program Files and private state under
   ProgramData. Use a managed machine Python distribution with pinned dependencies,
   explicit executable paths, working directories and configuration. Avoid Store
   Python, app execution aliases, personal PATH and developer-checkout dependencies.
3. Make host ID, portal origin, public/LAN gateway settings, viewer package, data
   roots and authority URL explicit configuration. Install required module files
   and runtime assets as one versioned unit.
4. Replace personal SSH/SCP with an outbound HTTPS host-sync protocol authenticated
   by a distinct enrolled host credential. Bind requests to that host; return only
   its approved routes/bundles and accept only its manifest. Enforce size/schema/
   route/path limits, atomic files and authenticated TLS. Keep optional server-side
   frame diagnostics off the critical boot path. Do not ship Epic's SSH key or
   require other users to configure KVM2 SSH.
5. Initialize gateway listeners independently of initial synchronization. Retry
   Tailscale, DNS, portal, MultiSeat and GPU/display readiness with bounded backoff.
   Report starting/degraded/ready separately. Reuse cached route and pairing data;
   do not delete seats when a dependency is late or unreachable.
6. Own and monitor child processes precisely, with restart backoff, log rotation,
   service recovery and no duplicate listeners. Preserve persisted revocation
   tracking across restarts. Maintain current fail-closed authorization behavior.
7. Give Caddy explicit machine storage so HTTPS certificates can load and renew
   before login. Preserve existing public gateway routes for other projects;
   support an externally managed gateway rather than taking ownership blindly.
   The separate LAN gateway remains bound to the configured LAN address with its
   existing firewall scope. Detect address changes and display an actionable state.

Service privilege, firewall and ACL installation require elevation once. Runtime
hosting and routine UI status do not require repeated UAC prompts.

## Agent UI

Use a native C# WPF app on a supported .NET LTS, packaged with its runtime. The UI
runs in the operator's interactive session and communicates with the service over
a Windows named pipe. It does not hold remote bearer tokens, signing keys or DNS
credentials and does not expose an additional browser management server.

Authorize pipe peers using Windows identity and explicit ACLs. Read-only status
can be granted to the enrolled operator. Privileged writes require administrator
authorization through a small typed control interface. Reject arbitrary shell
commands, arbitrary file writes and generic service-control requests. Validate
changes server-side, audit them, and write settings atomically with rollback.

Initial pages:

- **Overview:** hosting ready/starting/paused/degraded, startup mode, host identity,
  portal connectivity and health of MultiSeat, normal/LAN gateways and revocation
  checks. Show the failing component and a precise next step.
- **Sessions:** owner, desktop/game, seat/stream state and connected clients where
  measurable. Separate reconnect/repair of streaming from ending a Windows seat.
  Ending a seat must identify whose apps will close and require confirmation.
- **Hosting:** start at boot, pause accepting new sessions, normal/LAN availability,
  and supported seat limits/default resolution/FPS. Implement policy enforcement
  in the agent as well as the portal so these controls cannot be bypassed through
  an alternate launch endpoint. Pause retains existing seats by default.
- **Games:** manage the existing host game catalog, choose valid executable paths,
  show missing files and preserve account-owned profiles. Reuse current catalog
  operations rather than creating a second catalog.
- **Diagnostics:** bounded redacted logs, service/version details, health checks,
  and safe component-specific recovery. Export a sanitized support bundle without
  passwords, keys, tokens, cookies, private viewer pairing data or account files.

A tray icon offers Open Agent, Pause new sessions and status. Tray autostart and
hosting autostart are independent. Quit closes the UI; Stop hosting is a separate
explicit operation. Controls that disconnect streams show the affected resources.
Portal reachability and local runtime readiness must be separate indicators,
especially because LAN access currently depends on portal authorization checks.

Installer/uninstaller owns services, tray startup, binaries, enrollment and ACLs.
Uninstall preserves account/profile/config data by default. Automatic updates and
general remote desktop/VM management are outside the first UI release.

## Implementation sequence

1. Add configurable machine runtime paths, packaging, host-sync protocol and
   independently recoverable startup. Keep existing interactive mode as rollback
   until the replacement passes live checks.
2. Stage machine state by copying the current private stream store, TLS storage,
   pairing data and configurations into protected locations. Verify hashes and
   ACLs. Register the runtime service and perform a controlled listener handoff;
   disable the old logon task only after the service is healthy. Preserve backups.
3. Test before login and after sign-out. If capture needs an interactive operator
   session, diagnose the MultiSeat/Apollo dependency rather than enabling host
   auto-login. Existing automatic service startup does not prove capture works.
4. Implement the typed local management interface and real hosting policies.
5. Build the Agent UI and tray against that interface, then ship an installer
   that works on a clean Windows machine without Epic-specific paths or SSH setup.

## Acceptance and verification

- Cold boot, remain at the Windows sign-in screen, and verify host health from
  another machine. Open a disposable friend's multiseat desktop; verify decoded
  video plus keyboard/mouse. Confirm Epic has no logged-in Windows session.
- Verify both normal and LAN connection, HTTPS certificate loading, new seat
  pairing and reconnect. Sign out the operator and confirm hosting survives.
- Delay network/Tailscale/portal readiness, change the LAN address, crash individual
  child processes and restart the runtime. Check recovery, absence of duplicates
  and preservation of seats/profiles and stream revocation.
- Verify the service account can read only required secrets and runtime binaries
  cannot be edited by ordinary users. Test unauthorized pipe clients, invalid
  settings, concurrent mutations, pause/limit enforcement and redacted exports.
- Close the UI, relaunch it, switch Windows users, and reboot with UI startup
  disabled. Hosting behavior must remain independent.
- Run focused PowerShell/runtime/transport/host-gaming regressions and clean-machine
  installer tests, including rollback and data-preserving uninstall.

The real pre-login video/input test requires a planned reboot and a second device
or remote browser. Until it passes, describe this as boot-ready infrastructure,
not verified pre-login multiseat hosting.
