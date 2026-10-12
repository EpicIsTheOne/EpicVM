"""Typed privileged stream repair; never ends a Windows seat."""
import json
from pathlib import Path
import sys
import psutil
from direct_stream_auth import ROUTE_RE

config = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig'))
route = sys.argv[2]
if not ROUTE_RE.fullmatch(route):
    raise SystemExit('Invalid resource')
root = Path(config['stateRoot'])
if route not in json.loads((root/'routes.json').read_text()):
    raise SystemExit('Unknown resource')
target = (root/route).resolve()
for process in psutil.process_iter(['name']):
    try:
        if process.info['name'].lower() == 'web-server.exe' and Path(process.cwd()).resolve() == target:
            process.terminate()
            process.wait(timeout=5)
    except psutil.NoSuchProcess:
        pass
print('Stream transport closed; runtime will recover it. Windows apps stay running.')
