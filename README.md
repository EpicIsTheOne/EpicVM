# EpicVM

EpicVM hosts Windows desktops, games and apps through a web portal. Its multiseat mode gives friends separate Windows sessions on one host PC, with normal or local-network streaming and a native Windows Agent for host management. EpicVM also retains its Docker VM and Hyper-V workflows. It grew from DesktopOnCodespaces and preserves the upstream attribution and GPLv3 license.

> **License and attribution:** EpicVM is distributed under the GNU General Public License, version 3 (GPLv3). Keep the upstream DesktopOnCodespaces attribution and the repository `LICENSE` when copying or redistributing this modified work.

The independent EpicVM repository is hosted at <https://github.com/EpicIsTheOne/EpicVM>.

## Acknowledgements

Thank you to [Blobby-Boi](https://github.com/Blobby-Boi/), the original owner and creator of the project EpicVM grew from. EpicVM has since been substantially expanded while preserving the project's open-source licensing and upstream attribution.

## Windows multiseat hosting (preview)

The current focus is a self-hosted portal with independent Windows desktop sessions. A host can run its portal on the same Windows PC or on a separate Linux server. Multiseat hosting does not require Hyper-V.

- The Windows Agent manages hosting, sessions, games, connection permissions, updates and diagnostics. Hosting services start with Windows, independently of the Agent UI and operator login.
- The portal provides assigned desktops, account/request status, notifications and reconnectable sessions. Administrators can assign existing local Windows accounts; connecting to those accounts requires their Windows password.
- Optional LAN acceleration uses a fully local HTTPS address, with a one-time certificate trust step on each client. The portal and Agent show the certificate fingerprint. Existing domain-backed LAN gateways remain supported.
- Fresh setup offers a dedicated data folder on a fixed NTFS drive, host approval and a recorded video/input check before activation for friends. Existing accounts, profiles and installations are preserved.

Start with [Fresh host setup](docs/FRESH-HOST-SETUP.md). It explains the complete preview package, same-PC and separate-server installation, networking, certificate trust and recovery. Building from source is documented in [Windows Host Agent](docs/WINDOWS-HOST-AGENT.md); component provenance and release obligations are in [Third-party host components](docs/THIRD-PARTY-HOST-COMPONENTS.md).

This is a preview, not a finished public installer. Clean-machine/cold-boot validation, a complete separate-server/external-network stream, certificate renewal and trusted signing/publishing remain release gates. Gamepad support is not fully tested; vibration is unverified. See the [latest LAN/storage verification](docs/verification/lan-storage-20261012.md) for tested behavior and limits.

## VM quick start

### Codespaces

Open a blank codespace at <https://github.com/codespaces/> and run:

```bash
curl -fsSL https://raw.githubusercontent.com/EpicIsTheOne/EpicVM/main/install-epicvm.sh | sudo bash
```

### Linux host / VPS

The canonical public bootstrap entrypoint is `install-epicvm.sh`:

```bash
curl -fsSL https://raw.githubusercontent.com/EpicIsTheOne/EpicVM/main/install-epicvm.sh | sudo bash
```

The installer deploys the EpicVM VM stack, optional Traefik routing, and the EpicVM Dashboard. Verify the installation with:

```bash
epicvm doctor
epicvm list
```

For a local checkout, use the server installer documented by the repository and then use the `epicvm` CLI. Set `BLOBEVM_NO_TRAEFIK=1` for direct high-port mode, or set `BLOBEVM_INITIAL_VM_NAME=alpha` to choose the starter VM name.

## Manage VMs

```bash
epicvm create alpha
epicvm start alpha
epicvm status alpha
epicvm url alpha
epicvm stop alpha
epicvm delete alpha
epicvm apps
epicvm update-vm alpha
```

See [docs/CLI.md](docs/CLI.md) for the complete command reference and [docs/DASHBOARD_V2.md](docs/DASHBOARD_V2.md) for the EpicVM Dashboard documentation.

## EpicVM Dashboard

The dashboard is a VM management UI served at `/dashboard` (and, for the modern UI, `/Dashboard`). It lists VM state, opens VM URLs, supports lifecycle actions, shows resource information, and exposes EpicVM optimizer controls. It does not replace the VM CLI: use `epicvm doctor` for diagnostics and `epicvm` for automation.

## RemoteVM Windows hosts

EpicVM can place a VM on a Windows host running Hyper-V through the RemoteVM agent. The server stores host records in a root-owned JSON file (override with `EPICVM_REMOTE_HOSTS_FILE`) and the dashboard exposes only redacted host metadata.

On the Windows host, use the one-shot downloader from an elevated PowerShell 7 prompt:

```powershell
Invoke-WebRequest `
  -Uri 'https://raw.githubusercontent.com/EpicIsTheOne/EpicVM/main/remote_agent/windows/download-setup.ps1' `
  -OutFile "$env:TEMP\EpicVM-RemoteVM-download.ps1"
pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\EpicVM-RemoteVM-download.ps1"
```

It downloads the required agent files and automatically launches the guided
`setup.ps1` flow. If the files are already checked out locally, run
`remote_agent/windows/setup.ps1` directly. The installer creates the
`EpicVMRemoteAgent` service, stores the enrollment credential in a protected token
file without printing it, binds it to the specific Tailscale address, performs a
local health check, and limits the Windows Firewall rule to Tailscale's
`100.64.0.0/10` range. Transfer the protected token file securely, then run
`sudo epicvm-remote-host setup` on the server. See [remote_agent/windows/README.md](remote_agent/windows/README.md)
for the API and ownership-safety rules.

After the Windows installer completes, open `/Dashboard/` and use **Connect a
RemoteVM host**. Enter the host ID, display name, Tailscale agent URL, and select
the protected token file. The authenticated dashboard upload stores the token
server-side; it is not returned to the browser. The CLI wizard remains available
as a fallback with `sudo epicvm-remote-host setup`.

Only Tailscale `100.64.0.0/10` addresses and `*.ts.net` names are accepted by default. The development-only `EPICVM_ALLOW_NON_TAILSCALE_HOSTS=1` override should not be used on a public server.

## Compatibility ABI

EpicVM is a public rebrand, not a destructive migration. Existing deployments retain their legacy ABI so they can be upgraded in place:

- `blobe-vm-manager` remains a compatibility alias for the canonical `epicvm` CLI.
- `install-blobevm.sh` remains a compatibility installer alias; new documentation uses `install-epicvm.sh`.
- `/opt/blobe-vm` remains the legacy installation/state root.
- Existing `blobevm_<name>` Docker container names remain valid.
- Existing `BLOBEVM_*` environment variables remain valid, including `BLOBEVM_NO_TRAEFIK`, `BLOBEVM_INITIAL_VM_NAME`, and `BLOBEVM_DIRECT_PORT_START`.
- Existing service IDs `blobedash` and `blobe-optimizer` remain valid.
- Existing routes such as `/dashboard`, `/Dashboard`, `/vm/<name>/`, and their established dashboard API paths remain legacy ABI retained for existing deployments.

Use the EpicVM names for new scripts and documentation, but do not rename these compatibility identifiers on a live installation unless a separate migration explicitly requires it.

## Scope

EpicVM covers Windows multiseat desktop hosting, browser streaming, host management and self-hosted onboarding, alongside its existing VM lifecycle, routing and application-maintenance workflows.
