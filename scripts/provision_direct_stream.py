"""Stage one host-local Moonlight instance from an existing paired EpicVM bundle."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
import shutil


def patch_stream_navigation(static: Path) -> bool:
    """Return EpicVM streams to the portal even when stream teardown fails."""
    path = static / "stream.js"
    text = path.read_text(encoding="utf-8")
    marker = '// EpicVM workspace navigation'
    if marker in text:
        return False
    pattern = r'        // Close stream\r?\n.*?        this\.buttonDiv\.appendChild\(this\.exitStreamButton\);'
    replacement = '''        // EpicVM workspace navigation
        this.exitStreamButton.innerText = "Back to workspace";
        this.exitStreamButton.title = "Leave the stream. Your Windows apps stay running.";
        this.exitStreamButton.addEventListener("click", async () => {
            this.exitStreamButton.disabled = true;
            try {
                const stream = this.app.getStream();
                if (stream) {
                    await Promise.race([stream.stop(), new Promise(resolve => setTimeout(resolve, 3000))]);
                }
            } catch (error) {
                console.debug("Stream teardown failed; returning to workspace", error);
            } finally {
                window.location.assign("https://techexplore.us/EpicVM/portal");
            }
        });
        this.buttonDiv.appendChild(this.exitStreamButton);'''
    text, count = re.subn(pattern, lambda _: replacement, text, flags=re.DOTALL)
    if count != 1:
        raise RuntimeError("Pinned Moonlight exit control layout changed")
    path.write_text(text, encoding="utf-8")
    return True


def patch_stream_recovery(static: Path) -> bool:
    """Install bounded recovery on the pinned host-local viewer."""
    path = static / 'stream.js'
    text = path.read_text(encoding='utf-8')
    marker = '// EpicVM automatic connection recovery v1'
    changed = False
    if marker not in text:
        anchor = '        window["app"] = app;'
        old_stop = '                const stopped = yield oldStream.stop();'
        if text.count(anchor) != 1 or text.count(old_stop) != 1:
            raise RuntimeError('Pinned Moonlight reconnect layout changed')
        text = text.replace(anchor, anchor + '\n        ' + marker + '\n        installStreamRecovery(app);')
        text = 'import { installStreamRecovery } from "./epicvm_recovery.js?v=1";\n' + text
        text = text.replace(old_stop, '''                const stopped = yield Promise.race([
                    Promise.resolve().then(() => oldStream.stop()).catch(() => false),
                    new Promise(resolve => setTimeout(() => resolve(false), 3000))
                ]);
                // Release old transports even when the server disappeared.
                oldStream.ws?.close();
                if (oldStream.transport) {
                    yield Promise.race([
                        Promise.resolve().then(() => oldStream.transport.close()).catch(() => {}),
                        new Promise(resolve => setTimeout(resolve, 1000))
                    ]);
                }''')
        path.write_text(text, encoding='utf-8')
        changed = True
    source = Path(__file__).with_name('stream_recovery.js').read_text(encoding='utf-8')
    network_import = 'import { installStreamNetwork } from "./epicvm_network.js?v=1";'
    text = path.read_text(encoding='utf-8')
    if network_import not in text:
        text = network_import + '\n' + text.replace('        installStreamRecovery(app);', '        installStreamRecovery(app);\n        installStreamNetwork(app);')
        path.write_text(text, encoding='utf-8')
        changed = True
    network = static / 'epicvm_network.js'
    network_source = Path(__file__).with_name('stream_network.js').read_text(encoding='utf-8')
    if not network.exists() or network.read_text(encoding='utf-8') != network_source:
        network.write_text(network_source, encoding='utf-8')
        changed = True
    module = static / 'epicvm_recovery.js'
    if not module.exists() or module.read_text(encoding='utf-8') != source:
        module.write_text(source, encoding='utf-8')
        changed = True
    return changed


def patch_audio_player(static: Path) -> bool:
    """Start playback when Moonlight adds its first live audio track.

    The pinned upstream player assigns an empty MediaStream at construction.
    Chrome does not autoplay it when a track is added later, leaving its audio
    element paused even though Moonlight receives Sunshine audio packets.
    """
    path = static / "stream" / "audio" / "audio_element.js"
    text = path.read_text(encoding="utf-8")
    old_track = "        this.stream.addTrack(track);\n        this.oldTrack = track;"
    new_track = ("        this.stream.addTrack(track);\n"
                 "        this.audioElement.srcObject = null;\n"
                 "        this.audioElement.srcObject = this.stream;\n"
                 "        this.audioElement.play().catch(() => {});\n"
                 "        this.oldTrack = track;")
    old_interaction = "        this.audioElement.muted = false;"
    new_interaction = ("        this.audioElement.muted = false;\n"
                       "        this.audioElement.play().catch(() => {});")
    if new_track in text and new_interaction in text:
        return False
    if text.count(old_track) != 1 or text.count(old_interaction) != 1:
        raise RuntimeError("Pinned Moonlight audio player layout changed")
    path.write_text(text.replace(old_track, new_track).replace(old_interaction, new_interaction),
                    encoding="utf-8")
    return True


def patch_gamepad_input(static: Path) -> bool:
    """Keep Moonlight's protocol slots independent of browser gamepad indices."""
    path = static / "stream" / "input.js"
    text = path.read_text(encoding="utf-8")
    replacements = (
        ("this.sendControllerAdd(this.gamepads.length - 1, SUPPORTED_BUTTONS, capabilities);",
         "this.sendControllerAdd(id, SUPPORTED_BUTTONS, capabilities);"),
        ("const id = (_a = this.gamepads[index]) === null || _a === void 0 ? void 0 : _a.gamepadIndex;",
         "const id = index;"),
        ("if (oldGamepadState == null) {\n                return;\n            }",
         "if (oldGamepadState == null) {\n                continue;\n            }"),
        ("this.gamepadRumbleCurrent[0] = { lowFrequencyMotor: 0, highFrequencyMotor: 0, leftTrigger: 0, rightTrigger: 0 };",
         "this.gamepadRumbleCurrent[gamepad.index] = { lowFrequencyMotor: 0, highFrequencyMotor: 0, leftTrigger: 0, rightTrigger: 0 };"),
        ("capabilities = StreamControllerCapabilities.CAPABILITY_RUMBLE;",
         "capabilities |= StreamControllerCapabilities.CAPABILITY_RUMBLE;"),
        ("capabilities = StreamControllerCapabilities.CAPABILITY_TRIGGER_RUMBLE;",
         "capabilities |= StreamControllerCapabilities.CAPABILITY_TRIGGER_RUMBLE;"),
    )
    changed = False
    for before, after in replacements:
        if after in text:
            continue
        expected = 3 if before == "capabilities = StreamControllerCapabilities.CAPABILITY_RUMBLE;" else 1
        if text.count(before) != expected:
            raise RuntimeError("Pinned Moonlight gamepad input layout changed")
        text = text.replace(before, after)
        changed = True
    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def provision(*, source_data: Path, template_config: Path, package: Path,
              root: Path, route: str, address: str, sunshine_port: int,
              local_port: int, udp_port: int) -> None:
    if not route.startswith(("seat-", "vm-")) or not all(c.isalnum() or c in "-._" for c in route):
        raise ValueError("Invalid route")
    if not (1000 <= sunshine_port <= 65534 and 1024 <= local_port <= 65535
            and 1024 <= udp_port <= 65525):
        raise ValueError("Invalid port")
    data = json.loads(source_data.read_text(encoding="utf-8"))
    if len(data.get("users", {})) != 1 or len(data.get("hosts", {})) != 1:
        raise ValueError("Expected one paired user and host")
    user = next(iter(data["users"].values()))
    host = next(iter(data["hosts"].values()))
    if not host.get("pair_info"):
        raise ValueError("The source console is not paired")
    user["name"] = route
    user["password"] = None
    host["address"] = address
    host["http_port"] = sunshine_port
    for role in data.get("roles", {}).values():
        if role.get("ty") == "Admin":
            raise ValueError("An admin Moonlight role must not be exposed to a stream user")
        role.get("permissions", {})["allow_add_hosts"] = False

    config = json.loads(template_config.read_text(encoding="utf-8"))
    config["data_storage"]["path"] = "server/data.json"
    config["web_server"].update({
        "bind_address": f"127.0.0.1:{local_port}",
        "url_path_prefix": f"/EpicVM/{route}",
        "first_login_create_admin": False,
        "first_login_assign_global_hosts": False,
        "forwarded_header": {"username_header": "X-EpicVM-User",
                             "auto_create_missing_user": False, "ignore_case": False},
    })
    config["webrtc"].update({"port_range": {"min": udp_port, "max": udp_port + 10},
                             "nat_1to1": None, "network_types": ["udp4"],
                             "include_loopback_candidates": False})
    config["moonlight"]["default_http_port"] = sunshine_port
    config["log"]["file_path"] = "server/moonlight.log"

    target = root / route
    if target.exists():
        raise FileExistsError(f"Stream instance already exists: {route}")
    (target / "server").mkdir(parents=True)
    shutil.copytree(package / "static", target / "static")
    patch_audio_player(target / "static")
    patch_gamepad_input(target / "static")
    patch_stream_navigation(target / "static")
    patch_stream_recovery(target / "static")
    shutil.copy2(package / "streamer.exe", target / "streamer.exe")
    settings = target / "static" / "default_settings.js"
    text = settings.read_text(encoding="utf-8")
    if '"videoFrameQueueSize": 3' not in text or '"canvasRenderer": false' not in text:
        raise RuntimeError("Moonlight browser settings changed")
    settings.write_text(text.replace('"videoFrameQueueSize": 3', '"videoFrameQueueSize": 1')
                            .replace('"canvasRenderer": false', '"canvasRenderer": true'), encoding="utf-8")
    (target / "server" / "data.json").write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8")
    (target / "server" / "config.json").write_text(json.dumps(config, separators=(",", ":")), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("source_data", "template_config", "package", "root"):
        parser.add_argument(name, type=Path)
    parser.add_argument("route")
    parser.add_argument("address")
    parser.add_argument("sunshine_port", type=int)
    parser.add_argument("local_port", type=int)
    parser.add_argument("udp_port", type=int)
    args = parser.parse_args()
    provision(**vars(args))
