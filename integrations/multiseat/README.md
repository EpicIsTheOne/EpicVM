# EpicVM's MultiSeat credential extension

EpicVM uses MultiSeat's official seat and app launch API. Its admin-only password reveal needs the small source patch in `managed-credential-reveal.patch`, applied to a matching MultiSeat v0.6.7 checkout before building. The patch adds `POST /api/accounts/{username}/credential/reveal` for accounts created by MultiSeat. It does not add credentials to account lists or logs.

The deployed host's MultiSeat API is authenticated and bound to `127.0.0.1:9550`. EpicVM's Windows agent calls it locally. The public EpicVM dashboard exposes the result only through a CSRF-protected admin route with `Cache-Control: no-store` and records the admin, target account, host, and time without storing the password.

Build the patched service with `dotnet publish src/MultiSeat.Service/MultiSeat.Service.csproj -c Release -r win-x64 --self-contained false`. Keep MultiSeat's installed configuration and data. Update only the service binary while no seats are active, restart `MultiSeatService`, and verify its authenticated API before deploying the EpicVM agent. The deployment on September 23, 2026 backed up the prior DLL at `C:\ProgramData\EpicVM\multiseat-service-before-credential-reveal-20260923.dll`.

## Controller prerequisites and current limitations

A Running `ViGEmBus` service does not prove the Nefarius PnP bus exists. Apollo
can still report `E0000001` and fail to create controllers. Run
`scripts/Repair-EpicVMViGEmBus.ps1` elevated to restore a missing bus using the
installed driver package. It identifies the Nefarius hardware ID, preserves
Oculus's separate bus, refuses duplicate devices, and verifies PnP health.

MultiSeat v0.6.7 checks HidHide confinement when it provisions a seat, before
Apollo creates the client's controller. It does not revisit controller creation.
Static account-to-device path mappings are insufficient when pad paths change
on reconnect. Do not claim controller isolation merely because cloaking is on.
The October 9 verification demonstrated session confinement for specific live
pads, but did not establish automatic confinement or working button/stick
forwarding. See `docs/verification/2026-10-09-multiseat-live.md`.

An experimental allocation-time extension and its build instructions are in
`gamepad/README.md`. Native input and virtual-controller isolation passed after
reboot; physical browser forwarding and vibration checks remain in progress.
October 10 results and remaining verification are recorded in
`docs/verification/2026-10-10-gamepad-live.md`.
