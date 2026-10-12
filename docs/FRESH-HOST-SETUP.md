# Fresh host setup preview

EpicVM now includes a guided Windows setup flow, host-specific runtime generation, boot services, automatic public HTTPS configuration and a separate Linux portal with private native pairing. This remains a preview release. Clean-machine installation, unattended cold boot, external-network streaming, certificate renewal and trusted release signing have not all been verified together.

## Before starting

Use Windows x64 with a supported GPU and a local Windows operator account. Multiseat does not require Hyper-V or an E: drive. Fresh setup offers a dedicated data folder on a fixed NTFS drive with at least 1 GB free, such as D:\EpicVM. It stores runtime, hosting catalog and same-PC portal data there. A protected locator and setup credentials stay under C:\ProgramData\EpicVM; installed binaries stay under C:\Program Files\EpicVM. Windows profiles stay in their current location. Existing installations retain their paths; this wizard does not migrate them. An unavailable selected drive stops hosting with an actionable error instead of creating new state on C:. Drivers can require a reboot. Save your work first; setup never reboots automatically.

For internet hosting, choose DNS hostnames you own for the portal and Windows stream gateway. They can be the same hostname when the portal runs on the host PC. Automatic HTTPS uses Caddy's public certificate issuance and renewal, requiring public TCP 80/443 to reach the relevant gateway. A certificate and an HTTP health response do not prove the media connection works. CGNAT or a network that blocks UDP may need another ingress or relay arrangement; this preview does not automate a universal relay.

New hosters need the complete versioned package, including Python with Flask/Werkzeug/cryptography/Waitress/psutil, PowerShell 7, NSSM, Caddy, the Windows viewer, Agent/Control and the verified component bundle. SDKs, a repository checkout and token-file transfers are unnecessary on the target PC. Until a signed installer is published, the preview installer requires the fresh-release.json SHA256 from the trusted release channel. A checksum obtained only from the downloaded package does not authenticate it.

## Same Windows PC

1. Install the complete verified package under Program Files using scripts/Install-EpicVMFreshPackage.ps1 and the separately published manifest checksum. Existing packages are refused; use their repair/update path.
2. Open EpicVM Host Setup from Start. Choose Portal on this PC and check the package.
3. Enter the portal and streaming HTTPS origins, host ID/name and first administrator password. Use http://127.0.0.1:8765 as the private agent address. Choose the EpicVM data folder before saving. Setup saves unique credentials in protected storage.
4. Install hosting components. Healthy installed components are retained. If a reboot is requested, reboot yourself and use Resume saved setup.
5. Install the portal, then configure the HTTPS gateway. Point the selected DNS hostnames at this host's public ingress. Forward TCP 80/443 if your network needs forwarding. Existing port or proxy conflicts stop setup instead of replacing other applications.
6. Check connectivity, request host approval and sign into your portal. Match the displayed code before approving. Return to the wizard to check approval.
7. Install boot services, optionally configure the local connection, then check connectivity again. Setup generates the host signing key, sync credential, empty route/nonce stores and a one-seat default policy. It does not import anyone else's accounts, pairing or certificates.
8. In Management's Host setup approvals, start the desktop check. This opens your administrator's own desktop, creating its managed Windows account if necessary; existing apps are retained. Check preparation until the stream link is ready. Verify changing video plus keyboard/mouse input, record the check and activate the host. Ending that desktop later is an explicit action in your workspace.
9. Check activation in the wizard. Assign desktop access in Management. Save work, reboot and verify a connection while Windows stays at its sign-in screen. Also test from the network your guests will actually use.

## Separate Linux server

Use server/setup-selfhost.sh as root on a Linux server with Docker and Compose already installed. Supply verified digest-pinned portal and Caddy images, your portal/stream hostnames, the Windows host's Tailscale IPv4 address and the first administrator name. The script prompts locally for the password, creates /opt/epicvm-selfhost and refuses an existing installation or occupied public ports. It never builds on the VPS. The release builder uses scripts/Build-EpicVMHostPackage.ps1 for Windows and server/Dockerfile.selfhost for Linux.

The container runs as uid/gid 999, retains protected state in /opt/epicvm-selfhost/state, and starts a private native pairing viewer inside the portal container. It does not mount the Docker socket or publish pairing listeners. Video/media runs on the Windows host after the paired bundle is synchronized.

Join the server and Windows host to your own private tailnet. Set ACLs so only the intended server reaches the Windows agent on TCP 8765 and the Apollo/Sunshine ports allocated to its seats. A tailnet address alone does not verify reachability from a container. Test the connection before activation. The Windows stream hostname points to the Windows gateway; the portal hostname points to the Linux gateway.

On Windows choose Connect to my separate server. Use the server's portal HTTPS origin, your Windows stream HTTPS origin and http://WINDOWS_TAILSCALE_IP:8765 as the private agent address. Follow the same approval, runtime, desktop-check and activation sequence.

If a reverse proxy already exists, adapt the compose deployment so only that proxy reaches the portal's internal port 5050. Do not start a second gateway on occupied ports. Proxy all paths needed by the portal, including /EpicVM/, /portal/ and /Dashboard/. Keep 5050 off the public network, preserve the original Host and send the correct X-Forwarded-Proto. Direct access must not allow arbitrary clients to spoof these headers. Exact custom-proxy combinations require their own verification.

## LAN acceleration

After boot-service installation, choose Set up local connection or Skip. Setup detects a private IPv4 address on the active home-network interface; if several addresses are available, enter the intended address. It creates HTTPS at https://HOST-IP:8443 using a dedicated local certificate authority. No domain, provider token or router DNS change is needed. The optional gateway uses its own automatic Windows service and firewall rules restricted to LocalSubnet, its program and host address. Failure leaves normal hosting independent.

Each client must trust the host certificate once. In the signed-in portal, expand First local connection for the certificate setup page and SHA256 fingerprint. On the host network, download the public certificate from http://HOST-IP:8444/. Compare the downloaded certificate fingerprint with the signed-in portal or Agent value before trusting it. The HTTP page supplies public material only and cannot authenticate its own fingerprint. It never asks for passwords. Windows uses Current User / Trusted Root Certification Authorities; macOS uses Keychain Access; iOS also requires enabling Certificate Trust Settings; Android requires device CA settings and browser support. Managed clients can restrict certificate installation. Only trust a host you know; remove its CA when you stop using it.

The Agent shows the local link, setup URL and fingerprint after configuration. The portal advertises the local option only after the runtime verifies HTTPS with its own CA. Client trust and browser local-network permission are still separate checks. Reserve the host IP in DHCP for a stable link. If its IP changes, rerun the local setup step with the new assigned address; the CA is retained, so clients need not trust a new certificate. An unavailable or changed address removes the advertised local option without degrading normal readiness. Existing domain-backed LAN installations are preserved. Do not mark a different client as tested based only on the host PC's health check.

## Retry, recovery and removal

Resume saved setup after closing the window or rebooting. Prepared credentials and host signing authority are retained. Expired device requests can be requested again; denied/revoked enrollment requires administrator review. A changed portal identity, conflicting host ID or changed signing key stops setup for repair. Setup credential requests reject redirects.

Service registration has protected ownership checkpoints. Retry can start a setup-owned service; it cannot replace an unrelated preexisting service. A failed individual registration removes only that newly registered service. Successful earlier stages and private state remain for retry; this is staged recovery, not automatic removal of every previous stage. Components retain shared drivers on failure.

Before changing an existing installation, back up its protected configuration and service settings. Keep backup files private. Stop relevant services before taking an offline copy of the setup state, portal database, host runtime, agent configuration and certificates; restore them under the original protected ACLs and verify authenticated readiness afterward. Do not copy this backup into another owner's instance.

To remove a fresh setup's services, first revoke the host in its portal and end active desktops. Run scripts/Uninstall-EpicVMFreshServices.ps1 -ConfirmHostRevoked as administrator. It only removes services with setup ownership records and retains accounts, profiles, drivers, certificates and private state. Installed files can be removed later after recovery needs are resolved. Full repair/uninstall/restore behavior still requires clean-machine validation.

## Verified and outstanding

The current PC has verified native pairing, authenticated host discovery and decoded Windows video through an isolated test viewer. This is evidence for the native path on an already-configured physical host, not a clean-PC installation certificate. The Linux package has verified independent administrator login, retained state after restart and private native viewer startup. Automated authorization, signing isolation, runtime-state retry and existing multiseat regressions are covered separately.

A public release still requires clean Windows installation and reboot/resume testing; an end-to-end separate-server stream; external-network media and certificate-renewal verification; a complete Windows/GPU support matrix; third-party redistribution notices/source obligations; and trusted signing/publishing. New-EpicVMFreshRelease.ps1 can create labeled previews or require a valid trusted certificate to sign a candidate; signing alone does not satisfy the remaining release checks. Gamepad support is not fully tested; vibration remains unverified.