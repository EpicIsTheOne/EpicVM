# EpicVM self-hosted onboarding plan

Status: foundation implemented in a development preview. See FRESH-HOST-SETUP.md for supported actions and remaining release gates. The full fresh-host distribution is not complete.

## Confirmed scope

Hosters own their server and portal. Support both a portal on the same Windows PC as MultiSeat and a separate Linux server/VPS. Start with Windows x64 multiseat hosting; VM provisioning is optional later and cannot be a prerequisite. Keep existing EpicVM installations and migration/update paths supported.

A finished setup means an independently owned instance, an enrolled Windows host, authorized desktop access, working video and input, restart/resume support, and clear setup status. Merely starting services does not count as verified streaming.

## Existing building blocks and actual gaps

- Native Agent and privileged local Control service already exist, with policies, sessions, diagnostics and local package updates.
- Automatic Windows runtime and RemoteAgent services already exist.
- Setup-EpicVMHost.ps1 validates an enrolled host and prepared private state bundle. It is a migration entry point, not fresh provisioning.
- Install-EpicVMHostRuntime.ps1 imports existing signing, pairing, nonce database and certificate state. A fresh installer must generate these independently.
- The Windows remote-agent setup requires Hyper-V and defaults to E: with machine-specific GPU/template defaults. A multiseat profile must avoid these requirements entirely.
- Server/install.sh targets Linux Docker/Traefik and general VM hosting. New onboarding must not blindly run the whole legacy installer on an existing server.
- Recovery and stream provision code contains techexplore.us links. Instance authority must come from trusted configuration, never an arbitrary user-supplied redirect.
- Public HTTPS ingress and WebRTC media connectivity are separate. TURN/STUN/UDP, firewall, NAT and local DNS behavior require distinct verification.

## Two deployment layouts

### Same Windows PC

Proposed: a native Windows portal service with bundled Python and a supported production Windows WSGI server, plus the existing host runtime/control/adapter services. Verify this choice in the initial architecture spike. Do not assume the existing Linux Gunicorn image works on Windows. No dependency on an interactive Docker Desktop session; no Hyper-V requirement for multiseat. The internal host connection can use a narrowly scoped authenticated loopback adapter instead of joining a tailnet solely to reach itself.

Store binaries under Program Files and protected data under ProgramData. Let the operator choose a data drive without requiring E:. Service startup before operator login is a release gate for portal and desktop hosting, not just the Agent UI.

### Separate server/VPS

A bounded Linux container deployment for the portal and supporting services, with persistent volumes and explicitly configured public authority. The Windows wizard connects to the owner's portal. Use an authenticated private management path such as an owner-controlled Tailscale tailnet, with host-specific access rules. Server instructions must detect existing reverse proxies, occupied ports and storage rather than replace them.

Publish versioned prebuilt artifacts; new hosters should not need SDKs, repository checkouts, .NET builds or local Docker image builds.

## Wizard journey

1. Welcome: choose Create a portal on this PC or Connect to my existing portal. Explain what runs here, that the PC must remain powered on, and which existing software may need a restart.
2. Compatibility scan: Windows version/architecture, GPU and capture support, signed driver requirements, free space, service conflicts, selected drive, virtualization only when required by an optional profile, and existing EpicVM installation. Present blockers with specific remedies before writing system state.
3. Portal setup: create the local server or show a tested Linux server installation guide. Set a secure first administrator account with one-time bootstrap. Confirm the portal URL and instance identity. Never use shared default passwords.
4. Connectivity: configure and test HTTPS ingress for the portal and streamer, private management transport when separate, and the media path. Offer private-only/LAN operation when supported and clearly label its limits. Remote connectivity may require an owner-controlled domain or provider account; do not silently promise a universal router-free route.
5. Link this host: browser-based approval on the owner's portal, short-lived single-use device enrollment with host proof and polling. Display host identity for confirmation. Generate host-specific credentials, persist them privately, and register ownership atomically. No token file uploads or printed secrets.
6. Review installation: show components, dependencies, drivers, firewall rules, disk locations, service startup and any required reboot. Install verified packages under bounded administrative privileges; show progress and exact failing stage.
7. Hosting settings: host display name, maximum seats, pause policy, connection permissions, defaults for new seats, and operator identity. Retain existing unlimited-policy compatibility for upgrades, but propose one seat for a new-host first test and let the operator change it.
8. Connection check: create an explicitly consented disposable test seat, pair automatically with retries, open the test stream and verify authorization, actual video, and input. Stop only the test seat afterward and distinguish cancel/retry from completing the check.
9. Finish: show portal address, Agent access, Invite a friend, and remaining verification such as cold boot. Support later Add another host without reinstalling the portal.

LAN acceleration is a separate optional step. Its failure cannot silently break a working normal connection or make overall setup look complete. Validate certificates, client DNS and browser local-network permissions rather than relying on this PC's successful request alone.

## Architecture and state

- A non-admin setup UI drives a narrow privileged setup broker. The broker accepts typed component actions, not arbitrary shell commands or browser-selected paths to executable scripts.
- Persist installation stages, expected artifact versions, component ownership and recovery checkpoints in protected state. Resume after cancellation, network loss, reboot and relaunch.
- Separate preflight, download, prepare, register, install, verify and activate. Keep incomplete hosts disabled for friend connections until activation.
- Generate unique administrator/bootstrap, agent, synchronization, stream signing and encryption material per instance/host. Do not reuse production certificates, cookies, account files or state bundles.
- Bind enrollment approval to the host's proof; typing the displayed code alone cannot redeem its credentials. Expire/revoke abandoned enrollment sessions, throttle attempts, and make retry idempotent.
- Host revocation must cover agent management, runtime synchronization, manifests and new streaming authorization. Enrolled hosts cannot publish routes for another host.
- Authenticate private APIs; enforce CSRF on portal account actions and ownership on routes. Scope tailnet reachability to the intended management services.
- Validate downloaded binaries, immutable release manifests and applicable signatures/hashes. Assess third-party redistribution/license terms before bundling drivers, MultiSeat/Apollo and other dependencies.
- Centralize trusted instance URLs. Remove production hostnames, usernames, hardware IDs and disk assumptions from generated deployments, support links and updater metadata.

## Failure and recovery rules

Show Setup incomplete with the failed stage, actionable reason, Retry, and safe diagnostic export. Preserve credentials only in protected storage and redact exported logs. A retry must not create a second portal, host, account, firewall rule or service.

Rollback removes only changes created by this setup attempt. Never delete preexisting users, Windows profiles, games, certificates or unrelated proxy rules. Revoke newly issued enrollment credentials on abort where appropriate. Existing installations go to a repair/migration/update path with a backup and explicit handoff, not overwrite.

Restart only when required and after explaining impact. Reboot is operator-controlled; save progress first. Ordinary completion and Agent UI operation do not require an administrator session.

## Implementation order and gates

1. Architecture spike: prove a fresh Windows multiseat-only portal/service can run without Hyper-V or E:, establish independent-instance config, and validate service startup before login. In parallel within the work, specify the minimal separate Linux deployment. Investigate package/driver redistribution, media ingress and supported networking choices. Record evidence and resolve blockers before building a polished wizard.
2. Packaging/config foundation: complete credential-free versioned artifacts, configurable data paths, multiseat-only provider mode, Windows portal service, Linux deployment profile and instance-scoped URL generation. Keep the production installation compatible.
3. Enrollment: administrator bootstrap, device approval, host identity/proof, private connectivity, host-scoped registry integration and revocation. Validate wrong-portal and cross-host cases.
4. Durable setup engine: fresh state creation, driver/component installation, checkpoints, cancellation, rollback, reboot/resume and repair detection. Exercise failures before connecting to the production services.
5. Native wizard: expose the setup engine in the Agent with first-run routing, readable progress, settings, remedies and completion state.
6. Readiness/release checks: fresh-machine, independent-instance and real-stream verification; public installation guide and recovery guide. Publish supported limitations rather than claiming combinations not tested.

## Verification matrix

- Fresh Windows x64 PC with C: only and no previous EpicVM; no Hyper-V for multiseat.
- Same-PC portal and separate Linux portal; all generated links stay on the owner's instance.
- Independent accounts/host credentials with multiple hosts and cross-host authorization rejection.
- Existing MultiSeat/Tailscale/driver/proxy installs; older EpicVM upgrades; occupied ports and missing storage.
- Interrupted download, rejected signature, failed installer, denied elevation, disk exhaustion, reboot mid-setup and enrollment expiry.
- Trusted HTTPS and renewal; normal and optional LAN path; real media/input rather than HTTP health alone; NAT/relay limitations recorded.
- Resume while paused/full; failed pairing retry preserves the test/owner seat; no accidental termination of another owner's apps.
- Cold boot at Windows sign-in: portal, host health, actual capture and input verified. VM-only testing may cover setup mechanics but cannot certify physical GPU capture.
- Reinstall/repair/uninstall preserve user data and revoke only intended host access. Restore documented backups and verify old installation still works.

## Remaining decisions to resolve in the spike

Supported Windows editions and GPUs/drivers, redistribution/signing strategy, domain and certificate ownership, internet ingress/relay options, Linux server minimum resources, and exact Windows portal server packaging. These are technical/product decisions to verify, not reasons to ask operators for keys or manually configured state bundles during normal setup.


## Implementation checkpoint (2026-10-12)

Foundation and development preview are implemented. Verification is recorded in docs/verification/host-onboarding-20261012/verification.md. Trusted component packaging and installation are now implemented and installed on Epic's existing PC; its preservation checks passed. See docs/verification/component-installer-20261012/verification.md. The next dependency is full fresh runtime integration. The installed setup UI remains a development preview. Required clean-machine, cold-boot and real-video gates remain open.

## Remaining delivery plan (2026-10-12)

Deliver both confirmed layouts. Prove the same-PC Windows path first, then reuse its contracts for the separate Linux server path. Do not label either layout supported until its own end-to-end checks pass. This is a plan for future implementation, not authorization to modify the live host during this planning pass.

### Pass 1: Fresh runtime and service integration

Extend Setup-EpicVMFreshHost.ps1 and fresh_host_setup.py with typed runtime-install and readiness stages. Refactor Install-EpicVMHostRuntime.ps1 so fresh installs generate their own state rather than importing Epic's existing bundle. Install the multiseat-only RemoteAgent without Hyper-V, VM templates or a required E: drive. Connect enrollment output to protected agent configuration, host-scoped stream signing authority, nonce storage, runtime synchronization and gateway configuration. Install Control, Runtime and RemoteAgent with automatic startup under appropriate service identities.

Define the portal/host credential contract before writing credentials: what the portal issues, what the host generates, how keys are exchanged, and how revocation blocks new management and stream requests. Keep retries idempotent and ownership-scoped. Existing installations must enter repair/update and retain their current private state.

Completion gate: an independent instance can enroll a host, start all required services and report authenticated readiness using newly generated state. Wrong-host signatures and revoked credentials fail. Interrupted installation resumes without duplicate services or replacement credentials. Existing-host configuration preservation checks pass. Service health alone does not activate the host.

### Pass 2: Complete the real desktop connection

Connect native Moonlight pairing, bundle ownership and runtime route publication into one recoverable operation. Use an operator-approved disposable desktop account/seat with a tracked cleanup record. Distinguish pairing failure, unavailable host, gateway failure and media failure. Pairing retries preserve the intended seat; cancellation only cleans up resources created by the check.

Verify an authenticated browser receives changing frames and can send keyboard/mouse input to that desktop. Check session authorization, reconnect and isolation from another seat. Automated evidence may validate frames and input markers; human confirmation remains necessary for subjective usability. Record each check separately rather than trusting an unrestricted administrator acknowledgement.

Completion gate: fresh-state pairing, video, keyboard/mouse and reconnect work through the independent instance. Unauthorized clients fail. Test resources are cleaned up. Activation requires the relevant readiness evidence. Gamepad remains described as not fully tested; vibration is outside this onboarding pass.

### Pass 3: HTTPS and supported network routes

Resolve portal, gateway and media listeners together so they do not collide. Automate a clearly supported owner-domain HTTPS path with certificate renewal and restrictive firewall rules. Detect existing proxies and ports before making changes. Establish the authenticated private management path for separate-server hosting. Keep certificate/API credentials in protected storage and out of diagnostics.

Test portal HTTPS, stream authorization and actual media separately. Determine whether each supported topology needs direct UDP, a supported relay, or router configuration; document the observed limits. Do not assume a working reverse proxy carries all streaming traffic. Optional LAN acceleration gets its own DNS, certificate and browser-access check and cannot disable a working normal connection.

Completion gate: normal streaming works from outside the host network for the claimed topology; renewal can be exercised; normal connectivity survives LAN setup failure. A different LAN client verifies the optional local path. Router or provider steps that cannot be automated receive specific instructions and a subsequent connection check.

### Pass 4: Complete the separate Linux server distribution

Extend server/compose.selfhost.yaml beyond the portal-only scaffold with the actual required pairing, stream routing and supporting services established in passes 1 through 3. Provide verified versioned prebuilt images, persistent state, first-admin initialization, health checks and a bounded installer. Support an existing reverse proxy without replacing unrelated configuration. Document measured minimum resources.

Completion gate: a fresh separate server and independently enrolled Windows host deliver video/input and reconnect. Restarting containers retains accounts, pairing and enrollment. Backups restore a working independent instance. Cross-host routes and management credentials remain isolated.

### Pass 5: Turn setup into a guided wizard

Replace the current action-button preview in host_app/Agent/Setup.cs with a state-driven journey: layout, compatibility, portal, connectivity, components/runtime, approval, hosting settings, connection check and finish. Order stages according to actual dependencies. Show readable progress, required actions, retry/cancel and precise remedies. Do not mark skipped or failed checks as complete.

Persist the current step and pending reboot so relaunch resumes reliably. Show what is already installed and distinguish repair from a fresh installation. Finish with the owner's portal URL, Agent access and the next action for assigning a desktop or inviting someone. Cold-boot confirmation must stay visibly pending until verified.

Completion gate: both layouts can be completed without a source checkout, SDK, manual token transfer or editing configuration files. Cancellation, denied elevation, expired approval and reboot return to an actionable step. UI review checks readable status and recovery, not just appearance.

### Pass 6: Clean-machine release validation and packaging

Build a versioned installer/package with bundled runtimes, verified dependencies, license notices, integrity metadata and an established signing strategy. Signing and redistribution are release prerequisites to resolve, not assumptions about available certificates or permissions. Publish concise installation, networking, recovery and uninstall guidance for the layouts that pass.

Exercise fresh Windows with C: only, no EpicVM and no Hyper-V; validate both server layouts. Test download/installer failure, occupied ports, reboot/resume, repair and uninstall. Use a VM for installation mechanics, plus suitable physical Windows/GPU hardware for capture and streaming proof. A copied production configuration is not a fresh-instance test.

Completion gate: a new operator follows the published guide with the release artifact, creates an independent instance and connects to a desktop. Portal and hosting start at the Windows sign-in screen and accept an actual connection before the operator logs in. Data survives repair/update and backups restore. Publish the tested Windows/GPU/network support matrix and any remaining limitations.

### Existing-host protection during implementation

Before any live change, capture protected rollback copies and safe baseline facts: service identities/start modes, configuration digests, host registration and normal/LAN health. Use isolated test directories, ports and disposable resources wherever possible. Never copy Epic's secrets into an independent release fixture. Do not reboot automatically.

At the end of every pass that touches Epic's installation, restore or retain his original portal/host configuration and verify hosting services, authenticated readiness and both existing gateways. A release or test failure must leave a usable existing installation without requiring Epic to reconfigure it. Keep evidence reports per pass and state explicitly which fresh-machine or hands-on checks remain unperformed.

### Latest implementation checkpoint

Fresh runtime generation and enrollment-to-service wiring, host-specific signing keys and revocation, automatic public HTTPS configuration, private native pairing on both portal platforms, administrator testing before activation, guided Windows steps, versioned preview package integrity and recovery/removal tooling are implemented. Native pairing, decoded Windows video, mouse interaction and a keyboard text marker were verified using a disposable seat on the existing physical host. The separate Linux package passed independent administrator login and restart persistence. Installed Agent/setup files were updated while retaining Epic's existing live configuration and running services.

Evidence and remaining limitations are recorded in docs/verification/lan-storage-20261012.md. Epic explicitly deferred the clean-machine check; no test VM was created. This checkpoint does not close the complete release gates: clean installation/cold boot, end-to-end separate-server media, external-network media/renewal/restore, trusted signing/publishing and full source/notice obligations remain pending. The wizard now provisions optional domain-free LAN HTTPS with explicit one-time client CA trust and supports fresh-only fixed-NTFS data-folder selection. The original installation and domain-backed LAN remain preserved. Clean-machine and different-client validation remain pending. Do not describe the preview as a finished public installer.
