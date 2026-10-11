# Gamepad implementation and verification, October 10, 2026

## Current status

The allocation extension is disabled on the live host after QA. After reboot and
enabling the exact Nefarius PnP bus, fresh native XInput reads confirmed working
virtual buttons, sticks, and triggers. The earlier neutral-input issue no longer
reproduced in the initial two-seat tests. Its precise driver root cause remains
unconfirmed. The separate Oculus bus was preserved.

Gamepad support is not certified ready for friends. Physical controller discovery
in Chrome is intermittent, end-to-end rumble did not pass, and the public pairing
path still requires verification. Epic is away from the PC, so further hands-on
testing is unavailable in this turn.

## Verified behavior

- Two QA seats independently received distinct button, both-stick, and trigger
  values. Seat A: buttons 8192, LT 153, RT 76, LX 16383, LY -8191, RX -13106,
  RY -26213. Seat B: buttons 4096, LT 153, RT 76, LX -24575, LY -8191,
  RX -13106, RY -26213.
- After physical-controller confinement, fresh readers in sessions 4 and 5 each
  listed only their own virtual controller. The local console retained its
  physical controller. Index numbers changed; checks used values and ownership.
- Releasing A's synthetic input returned all native values to zero.
- Adding a second controller to A and removing its first controller left the
  second working: buttons 32768 and LX -9830. B retained its distinct values.
- Reconnecting A's first controller reused protocol slot 0 and native input
  worked alongside slot 1: buttons 16384 and LX 22936. B remained isolated.
- Browser stream reload and service restart reconnected the loopback paired
  streams. Additional physical-controller reconnect validation remains required.
- Chrome read Epic's real A button and full left-stick travel after a fresh
  automation-browser restart. Earlier attempts after driver-policy changes
  returned no browser controllers despite a confirmed click and successful fresh
  native console enumeration. Restart restored browser enumeration, but the
  exact Chromium caching mechanism is unconfirmed.
- Later physical checks again returned no browser controllers, including after
  a service update that avoids rewriting unchanged device rules or active state.
  The maintenance rewrite was a candidate explanation, not a confirmed cause.
- The instrumented browser controller reached a fresh native reader in session 8:
  buttons 8192 and LX 16383. Native XInputSetState returned success (0) for a short
  vibration pulse. The browser received no rumble message and its instrumented
  actuator recorded no nonzero effect. This does not establish working rumble.
  Epic reported no felt vibration in the physical checks.
- An unregistered local process sent a well-formed allocation request to the
  broker. It returned denial (2) and left the ownership journal unchanged.

## Implementation and checks

The pinned browser patch fixes protocol-slot reuse, removal using sparse browser
indices, and updates continuing past empty slots. It also initializes rumble
state at the browser controller's index and preserves both advertised rumble
capabilities. Regression tests cover independent vibration with sparse indices,
unplug/replug, surviving inputs, analog state, and cleanup.

Browser/provisioning/supervisor tests: 14 passed.
Windows ownership/injector/session-jail tests: 32 passed, one existing skip.
Service publishes successfully, with the existing SessionLauncher CS1998 warning.
Native allocation DLL builds with warnings treated as errors.

Apollo starts suspended; the injector verifies its import hook before resuming.
The authenticated broker preconfines XUSB creation, journals exact owned rules,
preserves unrelated rules, and rejects foreign ownership. Input reports and
vibration IOCTLs pass through unchanged. Reservations last for the Apollo process
lifetime and are cleaned after the process and PnP device disappear.

Physical controller paths are confined to the console and retained while absent.
A previous implementation removed absent physical-device rules; a hotplug test
then exposed physical input to existing remote readers. Retaining known paths
fixes that rule-removal window, but requires another live unplug/replug check.

## Remaining boundaries

New physical device paths are discovered every ten seconds, so their initial
hotplug isolation is not certified. New virtual HID child paths also have a
creation-to-rule interval; Windows.Gaming.Input and DirectInput isolation are
not certified by these XInput checks. Windows has four XInput slots across the
host. Native PlayStation features are outside this Xbox-emulation extension.

The public dashboard's isolated pairing confirmation previously stalled.
Host-local already paired streams support these controller tests; this does not
certify the public pairing flow. Real native physical forwarding, rumble,
known-device hotplug with retained rules, Apollo restart cleanup, and broker
failure remain on the verification list.

## Recovery and operational state

Backup: C:\ProgramData\EpicVM\controller-gate-before-20261010.
Builds: E:\Projects\builds\epicvm-controller-gate.
Only service/gate binaries and scoped controller settings were changed.
Accounts, profiles, installed data, TLS identities, and pairings are retained.
Temporary agent exception diagnostics were previously restored.

QA seats were deleted through the authenticated API, their profiles retained,
accounts disabled, browser contexts closed, and the two exact loopback QA servers
stopped. Only journaled controller rules were removed after confirming virtual
devices were absent; the resulting blacklist was empty and cloaking was disabled.
Both ownership journals were cleared. MultiSeatService and EpicVMRemoteAgent are
running and the authenticated seat API reports no seats. The allocation switch
is false; older cloaking/prewrite options remain false. The updated binaries and
five host stream patches remain installed for the next verification pass.
