# EpicVM Windows Host Agent

The native Agent UI manages the machine hosting runtime. The UI and its tray icon
run after operator login. Hosting runs independently before login using automatic
Windows services. Closing the UI leaves hosting running; Stop hosting disconnects
streams while preserving Windows seats and apps.

## Installed components

- `EpicVMRemoteAgent`: existing privileged host/MultiSeat adapter.
- `EpicVMHostRuntime`: manages viewer processes, HTTPS gateways and host-scoped
  outbound synchronization. Fresh setup currently uses LocalSystem. Older
  installations may use `NT SERVICE\EpicVMHostRuntime`; updates retain the
  configured service identity.
- `EpicVMHostControl`: typed local named-pipe management service. Only the enrolled
  Windows operator, Administrators and SYSTEM can connect. Changes require an
  administrator token. The desktop UI reads no remote credentials.
- `C:\Program Files\EpicVM`: managed Python, .NET 10 apps, runtime scripts and
  viewer/gateway binaries. Ordinary users have read/execute access.
- `C:\ProgramData\EpicVM\host-runtime`: private runtime configuration, pairing,
  signing/sync credentials, certificate storage, revocation tracking and logs.
  SYSTEM and Administrators have full access. Where a dedicated runtime identity
  is configured, it receives the required access to its runtime state.
- Fresh setup can choose another fixed NTFS data folder. Its `host-runtime`,
  `host-gaming` and same-PC `portal` data live there; a protected
  `C:\ProgramData\EpicVM\storage.json` locator remains on C:. Existing installs
  retain their paths, and Windows profiles are not moved.
- Optional `EpicVMLocalGateway` supplies domain-free LAN HTTPS and a public
  certificate setup page. Each client must compare the fingerprint shown in the
  signed-in portal or Agent before trusting the host CA. See
  [Fresh host setup](FRESH-HOST-SETUP.md) for client and recovery instructions.

Open **EpicVM Agent** from the Start menu. Hosting settings include start at boot,
tray startup, pause new desktops, normal/LAN connection permissions, maximum seats
(0 preserves the existing unlimited policy), and defaults for new desktop
resolution/FPS. Pause and limits are checked at native seat creation. Existing
desktops can reconnect while paused. Connection permissions are enforced by the
host gateway; disabling a path disconnects its resource's viewer transports.

Sessions shows managed Windows accounts and their actual seat status. Repair
stream closes only the selected viewer process. End desktop closes that seat's
apps and requires confirmation. Games uses the existing machine game catalog;
removing a catalog entry leaves installed files on disk. Diagnostics exports a
bounded status/operation snapshot without raw secrets or pairing/account files.

## Build and existing-host migration

Requires a .NET 10 SDK for building; published applications include the runtime.
Prepare official embeddable Python 3.13 with SQLite/SSL and pinned `psutil==7.2.2`.
Its `python313._pth` must contain `python313.zip`, `.`, `../scripts`,
`Lib/site-packages`, and `import site`. Do not use Store aliases for the service.

Run `scripts/Build-EpicVMHostPackage.ps1` with the prepared Python directory and a
new output directory. The package includes no host credentials. This installer
supports fresh hosting through the separate guided flow documented in
[Fresh host setup](FRESH-HOST-SETUP.md). Use that flow for new hosters.
The migration script below is for an already-enrolled Windows host with an
existing private stream store and EpicVMRemoteAgent/NSSM installation.

Run the packaged `scripts/Install-EpicVMHostRuntime.ps1` elevated. Supply explicit
host identity, portal/public HTTPS origins, operator name, source private stream
store, viewer package, Caddy binary/config/certificate storage and the dedicated
sync token file. It refuses an already-installed runtime, preserves the source,
copies certificate/pairing data and takes a consistent SQLite backup. Gateway
paths are migrated without replacing unrelated public proxy routes.

The portal requires the source module `dashboard/host_runtime_api.py`, registration
in `app.py`, and a private host-runtime-enrollments JSON file. Each host enrollment
contains `enabled`, SHA-256 `tokenHash`, `publicOrigin`, and explicitly allowed
`vmRoutes`. Seat routes are checked against the actual server seat ownership
record. HTTPS synchronization returns only that host's paired bundles, and
manifest writes cannot replace another host's routes or choose a different origin.
Keep credentials out of command arguments, source control and support exports.

The installer stages the runtime service and starts the control service. During
a maintenance handoff, stop the old stream supervisor and its gateway/viewer
processes, start EpicVMHostRuntime, verify health, then disable the old interactive
logon task. Preserve unrelated services, Windows seats and source data. Firewall
rules are installed for the machine viewer's UDP range and public HTTPS gateway; LAN remains
restricted to the host LAN interface and subnet. Service-managed gateway binaries
must be allowed through the existing firewall even when their paths change.

## Verification and recovery

Status distinguishes runtime service state, synchronization readiness and stale
health. Ready requires configured listeners and successful portal synchronization.
This does not certify video capture: test real video/input after reboot while the
operator remains signed out. Portal authorization failures remain fail-closed,
including LAN streaming. A sleeping/offline PC and BitLocker pre-boot unlock are
outside Windows service startup.

NSSM/SCM restart failed runtime processes with backoff; the supervisor recovers
individual viewer and gateway listeners. Old state/logon task exports remain
available for rollback. `Uninstall-EpicVMHostRuntime.ps1` removes services and the
Start-menu shortcut while preserving state, accounts, profiles and binaries.
Restore the old gateway configuration and logon task for rollback, then verify
normal/LAN access. Do not run the two hosting paths simultaneously.

Pending product work: a fully guided fresh-host enrollment wizard, signed automatic
updates, per-client rather than per-resource disconnect, and clean-machine plus
cold-boot capture verification. These are not implied by a healthy service.
