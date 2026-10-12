"""Relaunch the Agent with its original user token after an elevated updater exits."""
import json
import pathlib
import subprocess
import sys
import time
import psutil

result, agent = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
updater_pid = int(sys.argv[3])
caller_pid = int(sys.argv[4])
deadline = time.monotonic() + 900
while time.monotonic() < deadline:
    if psutil.pid_exists(caller_pid):
        time.sleep(0.2)
        continue
    try:
        data = json.loads(result.read_text(encoding="utf-8-sig"))
        if data.get("status") in {"succeeded", "failed"}:
            subprocess.Popen([str(agent)])
            result.unlink(missing_ok=True)
            break
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    if not psutil.pid_exists(updater_pid):
        subprocess.Popen([str(agent)])
        break
    time.sleep(1)
