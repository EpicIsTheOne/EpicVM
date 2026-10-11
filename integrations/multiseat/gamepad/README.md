# EpicVM controller allocation extension (experimental)

This opt-in extension targets MultiSeat v0.6.7, native x64 Apollo, ViGEmBus,
and HidHide 1.4.181.0. It preserves the existing credential reveal extension.
It is disabled on the live host after QA. Post-reboot native XInput reads verified distinct
buttons, both sticks, and triggers in two seats with no cross-seat virtual-pad
visibility. Physical browser discovery was intermittent and end-to-end rumble
did not pass. See the October 10 verification report before enabling it.

Apollo starts suspended. The service injects a DLL, verifies that Apollo's
DeviceIoControl import is hooked, registers the actual process identity and
session, and resumes its primary thread. Injection failure terminates Apollo.
Only Xbox 360 device allocation uses the broker. Input reports and vibration
continue through the original function.

The broker authenticates the pipe caller using Windows' client PID and a held
process handle. The DLL checks the pipe server against the Windows service PID.
Before creation, the broker writes the XUSB session rule and known HID child
rules. After creation it discovers additional HID children and adds their rules.
Reservations remain through controller unplug/replug and are released after
Apollo exits and its device disappears. An atomic journal records exact owned
rules. Foreign rules remain unchanged; conflicting rules and application bypasses
are refused. HidHide's admin CLI is the sole permitted whitelist entry.

Known physical controller paths are journaled and confined to the active console
session. Their rules remain while unplugged so reconnect cannot reopen those
paths to other sessions. Newly discovered physical paths are polled every ten
seconds; hotplug isolation for previously unknown devices is not certified.

XUSB creation is confined before the device exists. A new HID path has a window
between creation and the post-creation rule update. Windows.Gaming.Input and
DirectInput isolation therefore need separate testing and are not certified by
the XInput checks. Windows supports four XInput controllers across the host.
PlayStation controllers are presented to games as Xbox controllers in this mode;
motion, touchpad, adaptive triggers, and native PlayStation emulation are outside
this extension's current scope.

## Build and test

Apply `managed-credential-reveal.patch` to a matching checkout first, then:

```powershell
py -3.13 integrations/multiseat/gamepad/prepare_source.py C:\path\to\MultiSeat
dotnet test C:\path\to\MultiSeat\src\MultiSeat.Tests\MultiSeat.Tests.csproj -c Release --filter 'FullyQualifiedName~ControllerGatePolicyTests|FullyQualifiedName~ProcessInjectorTests|FullyQualifiedName~HidHideSessionJailTests'
./integrations/multiseat/gamepad/Build-ControllerGate.ps1 -OutputDirectory E:\builds\controller-gate
dotnet publish C:\path\to\MultiSeat\src\MultiSeat.Service\MultiSeat.Service.csproj -c Release -r win-x64 --self-contained false -o E:\builds\controller-gate\service
```

The native script currently uses the host's installed VS 2022 Build Tools and
Windows SDK paths. Adjust these explicit paths for another build host.
`native/xinput_probe.cpp` is an independent verification reader. It writes
buttons, both sticks, triggers, packet count, and XInput index to the current
user's LOCALAPPDATA for five minutes.

## Deployment boundary

Back up the installed service DLL and appsettings.json. Require no active
non-test seats. Keep the installed data, accounts, profiles, TLS identities,
pairings, and existing config. Update only the service DLL and gate DLL.
Add `MultiSeat:EpicVMControllerGateDll` as an absolute DLL path and leave
`MultiSeat:EpicVMControllerGate` false until the live checks pass. Set the latter
true to test; newly started Apollo instances then use `gamepad = x360`.
The older `EnableHidHideCloaking` and `EnablePadRulePreWrite` paths should remain
false while the broker owns isolation.

Rollback restores the backed-up service DLL and appsettings while no seats run.
Remove only the rules recorded in controller-gate.json and its .console journal after their devices have
gone. Keep unrelated driver devices and user rules. Do not use `--cancel` after
a HidHide CLI mutation: it discards those changes. Verify active state through
the driver API rather than inferring it from the command line.
