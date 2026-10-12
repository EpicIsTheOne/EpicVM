# Fresh setup LAN and storage completion, 2026-10-12

Implemented and installed the remaining automatic LAN provisioning and custom data-folder selection. This extends the earlier onboarding preview; it does not certify the pending clean-machine release gates.

## Delivered behavior

- The Windows wizard offers a fixed-NTFS data-folder chooser before preparation. An immutable protected locator on C: directs Control, Runtime, the hosting catalog and the same-PC portal to that folder. Setup credentials and binaries retain their protected standard locations. Existing installations and Windows profiles are not migrated. Missing storage fails explicitly.
- A separate optional wizard stage detects the home-network IPv4 address or accepts an assigned address. Stock Caddy provisions domain-free HTTPS on port 8443, a private local CA and an automatic LocalSystem gateway service. Firewall access is limited to the gateway program, selected host address and LocalSubnet. The gateway never installs trust silently.
- An HTTP service on port 8444 provides only public certificate material and instructions. The signed-in portal and Agent display the SHA256 fingerprint. Clients must independently compare it and trust the certificate once. Normal hosting is independent of local setup failure.
- A host-scoped authenticated endpoint accepts only bounded private-IP URLs, the expected local ports and a SHA256 fingerprint. Extra private fields are never persisted. Other hosts and existing domain-backed gateways are preserved; revoked synchronization credentials cannot update metadata.
- Runtime publication verifies the gateway against its own CA. A missing or changed address disables the advertised local option. Explicit local setup can repair the assigned IP while retaining its CA; reserve the address in DHCP for stability.

## Verification

- 75 Python regressions passed across setup, runtime, host enrollment/synchronization, LAN authorization, revocation, hosting and existing local accounts. The expanded LAN suite passed 21 checks, including two subsequent recovery checks. Total unique Python checks in this pass: 77.
- All 91 native Agent checks passed: 21 interaction, 29 convenience, 24 recovery, 10 release and 7 setup checks. Agent/Control builds and Vite production build passed. All 10 update transaction/integrity checks passed.
- A real stock-Caddy process served locally trusted HTTPS on isolated ports. Public DER certificate and fingerprint matched; private-key requests returned 404; CORS/PNA health headers matched the configured portal; restart retained the CA. No system certificate trust was installed.
- A separate protected gateway fixture ran as an automatic LocalSystem Windows service. Its HTTPS verified against the generated CA before and after service restart. The test service and protected fixture were removed.
- A real isolated NTFS data root retained runtime signing/sync credentials and portal SQLite data across reinitialization. Different ownership and nonempty folders were rejected; missing storage produced the intended error. The production locator was never created or changed. Test storage was removed.
- The Linux image built through PC Build Service with phase=succeeded and exit_code=0, job `2eb7e6bc34bb4aec`, image `b9c6ffd88f48855242f62807156262f3bfbc9e40132664caf3ccebf44d98e188`. Its packaged portal startup, Linux storage independence, local-metadata authorization and bundled trust instructions passed in an isolated container. The container was removed.
- Windows preview `0.1.0-preview.5` includes 2,628 verified file hashes and an exact archive inventory with no host-private state. Archive SHA256: `a00048a4056c82bf1433a0273b52dd955727818548e2b046c81463463f471a65`. Manifest SHA256: `fb9b9e3b2d596f62d391609088c4a0e9c0b37474c96cca0edc9a134731cd7f51`.
- Installed Agent/Control, setup modules, runtime and adapter paths were updated with protected rollback copies under `C:\ProgramData\EpicVM\updates\lan-storage-20261012`. Final runtime verification found a supervisor/older stream-patcher mismatch; the matching packaged patcher and recovery assets were installed, and runtime returned to ready.
- All four original hosting services remain Running/Auto. Existing private baseline hashes and storage location are preserved. Normal and existing domain-backed LAN gateways returned HTTP 200. The fixture gateway service is absent. No existing gateway certificates, DNS tokens, users or profiles were replaced.

## Remaining checks

Clean Windows installation/cold boot remains explicitly deferred by Epic. A different client device's certificate installation and actual domain-free LAN video/input have not been tested in this pass. Full fresh separate-server/external-network streaming, public certificate renewal, signed publishing and complete redistribution/source obligations retain their earlier release gates. The archive is a preview and was not pushed or published. Vibration remains not fully tested and deferred.

Evidence: `lan-storage-live/verification.json`, `lan-storage-custom-drive.json`, `lan-storage-service.json`, `lan-storage-agent-tests.txt`, `lan-storage-package.json`, `lan-storage-live-preservation.json`, and `lan-storage-final-live.json`.
