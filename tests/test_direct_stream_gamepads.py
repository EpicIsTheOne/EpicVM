import shutil
import subprocess
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from provision_direct_stream import patch_gamepad_input


def test_pinned_gamepad_lifecycle_with_sparse_browser_indices(tmp_path):
    package = Path(r"E:\Projects\WindowsStream\moonlight-web\package\static")
    if not package.exists() or not shutil.which("node"):
        pytest.skip("Pinned host Moonlight package and Node are required")
    for relative in ("stream/input.js", "stream/buffer.js", "stream/gamepad.js",
                     "stream/keyboard.js", "stream/mouse.js", "api_bindings.js"):
        target = tmp_path / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(package / relative, target)
    assert patch_gamepad_input(tmp_path)
    assert not patch_gamepad_input(tmp_path)
    subprocess.run(["node", "--experimental-vm-modules",
                    str(Path(__file__).with_name("gamepad_input.browser.mjs")), str(tmp_path)],
                   check=True, capture_output=True, text=True, timeout=15)


def test_unrecognized_package_is_not_partially_patched(tmp_path):
    path = tmp_path / "stream/input.js"
    path.parent.mkdir()
    path.write_text("different upstream layout", encoding="utf-8")
    with pytest.raises(RuntimeError, match="layout changed"):
        patch_gamepad_input(tmp_path)
    assert path.read_text(encoding="utf-8") == "different upstream layout"
