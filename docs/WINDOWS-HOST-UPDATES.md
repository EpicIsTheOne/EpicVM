# Windows host releases

The Agent's **About & updates** page shows its version, Control version, installed host release, and last update result. Version 0.1.0 establishes version tracking for previously unversioned installations.

## Install an update

Download a release ZIP from a source you trust, then choose **Choose update package**. The package has SHA-256 integrity checks, but no publisher signature. It must not contain host keys, passwords, Windows profiles, settings, or account mappings.

The Agent requests administrator approval, closes, and reopens under your original Windows account when the update finishes. UI updates keep hosting running. Core updates restart Control. Streaming-code updates are refused while any MultiSeat desktop exists; explicitly end those desktops first. The updater never ends desktops itself.

Updates back up changed files, verify installed hashes and the Agent-to-Control connection, and restore the previous files if verification fails. **Roll back last update** restores a completed release when installed hashes still match it. Windows accounts, profiles, private runtime state, certificates, and credentials are outside the update destinations.

For the first update on a legacy installation, quit the Agent and run the trusted release's updater as administrator:

```powershell
./scripts/Update-EpicVMHost.ps1 -PackagePath C:/Downloads/EpicVM-Host-0.1.0.zip
```

Backups and the latest result are stored in `C:/ProgramData/EpicVM/updates/host-releases`. The running Control service exposes the result to the enrolled operator.

## Prepare another enrolled host

Install and enroll the Remote Agent and MultiSeat first. Prepare a host-specific state bundle containing signing.key, sync.token, routes.json, nonces.sqlite3, Caddyfile, and profile/Caddy. Treat this bundle as private. A release package provides Python, Caddy, and the viewer; those external runtimes must be supplied when preparing the full installation package.

Create a small JSON configuration:

```json
{
  "operatorName": "LocalOperator",
  "hostId": "gaming-pc",
  "portalOrigin": "https://portal.example.com",
  "publicOrigin": "https://host.example.com",
  "stateBundle": "C:/Private/EpicVM-host-state"
}
```

Run the preflight, then setup as administrator:

```powershell
./scripts/Setup-EpicVMHost.ps1 -ConfigurationFile ./host-setup.json -CheckOnly
./scripts/Setup-EpicVMHost.ps1 -ConfigurationFile ./host-setup.json
```

Setup derives component paths from the package and bundle. It checks enrolled-host prerequisites before installation. The existing installer retains its controlled listener handoff requirement; follow its completion message before starting the boot runtime. This wrapper does not provision certificates, DNS, or a new MultiSeat installation.

## Build a release

Build the full package with `Build-EpicVMHostPackage.ps1`, supplying the prepared Python runtime. For a setup distribution, also supply `-GatewayExecutable` and `-ViewerRuntime` using credential-free vendor distributions. Produce the portable update ZIP with `New-EpicVMHostUpdatePackage.ps1 -PackageRoot <built-package> -OutputPath <new-zip> -Version 0.1.0`. Add `-IncludeRuntime` only when releasing runtime script changes. Python, Caddy and viewer binaries are intentionally excluded from this first updater version.
