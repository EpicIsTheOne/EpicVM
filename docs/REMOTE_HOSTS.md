# RemoteVM host enrollment

EpicVM keeps RemoteVM host records on the server. The browser never supplies an
agent URL or bearer token. Host records are read from `/opt/blobe-vm/remote-hosts.json`
(or `EPICVM_REMOTE_HOSTS_FILE`) and must be mode `0600`.

## Windows host

1. Put the Windows machine and EpicVM server in the intended Tailscale tailnet.
2. Run PowerShell 7 as Administrator on the Windows host:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
```

If the files are not already checked out, use the one-shot downloader from an
elevated PowerShell 7 prompt:

```powershell
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/EpicIsTheOne/EpicVM/main/remote_agent/windows/download-setup.ps1' -OutFile "$env:TEMP\EpicVM-RemoteVM-download.ps1"
pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\EpicVM-RemoteVM-download.ps1"
```

The guided setup checks PowerShell 7, Hyper-V, and Tailscale, discovers the
Tailscale address, asks for the optional Hyper-V switch, and runs the secure
installer. For unattended setup, use `-TailscaleAddress`, `-SwitchName`, and
`-NonInteractive`.

3. After the service is healthy, open `/Dashboard/` and use the **Connect a
RemoteVM host** card. Enter the host ID, display name, and Tailscale agent URL,
then select the protected token file. The authenticated upload writes the token
directly to the server registry and never returns it to the browser. `sudo
`epicvm-remote-host setup` remains available for CLI-only enrollment.

## Server enrollment

The CLI generates a strong token only into a protected file; it never prints the
secret. Use `token-generate --output` followed by `add --token-file` (or a
protected token file/stdin/environment source):

```bash
server/epicvm-remote-host token-generate --output /run/epicvm/agent.token
server/epicvm-remote-host add epic-pc "Epic PC" http://100.72.220.117:8765 --token-file /run/epicvm/agent.token
server/epicvm-remote-host list
server/epicvm-remote-host probe epic-pc
server/epicvm-remote-host disable epic-pc
server/epicvm-remote-host enable epic-pc
server/epicvm-remote-host remove epic-pc
```

The output of `list`, `show`, and `probe` never contains the token. Non-Tailscale
URLs (`100.64.0.0/10` or `*.ts.net`) are rejected unless the explicit
`EPICVM_ALLOW_NON_TAILSCALE_HOSTS=1` development override is set.

## Dashboard behavior

The Local VM option is always available. RemoteVM creation is enabled only for
an online registered host whose capabilities report `create_vm: true`. The
server checks host availability and capability again at submission time. VM
inventory retains the last known remote ownership metadata and labels those
cards offline if a host disconnects; lifecycle mutations are blocked until the
host is reachable again.

## Agent contract

The agent exposes JSON endpoints:

- `GET /v1/health`
- `GET /v1/capabilities`
- `GET /v1/vms`
- `POST /v1/vms`
- `POST /v1/vms/{name}/start`
- `POST /v1/vms/{name}/stop`
- `POST /v1/vms/{name}/restart`
- `DELETE /v1/vms/{name}`

Every request is bearer-authenticated. Mutation requests support an
`Idempotency-Key` and return an `X-Request-Id` header. The older
`/actions/{action}` mutation path remains as a compatibility alias.
