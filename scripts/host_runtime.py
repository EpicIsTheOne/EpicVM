"""Machine-installed runtime entrypoint. Keeps cached listeners up during sync retries."""
import json
import os
from pathlib import Path
import sys
import time

import supervise_host_direct_streams as supervisor

config = supervisor.RUNTIME_CONFIG
root = Path(config['stateRoot'])
os.environ['APPDATA'] = str(root / 'profile')
os.environ['LOCALAPPDATA'] = str(root / 'profile-local')
os.environ['XDG_DATA_HOME'] = str(root / 'profile')
for path in ('profile', 'profile-local'):
    (root / path).mkdir(exist_ok=True)


def status(state, error=None):
    value = {'state': state, 'hostId': config['hostId'], 'updatedAt': int(time.time()),
             'portal': 'connected' if state == 'ready' else 'unverified',
             'message': error or 'Host synchronization and listeners are ready.'}
    supervisor._write(root / 'runtime-status.json', value)


status('starting', 'Starting machine listeners and checking host dependencies.')
while True:
    # Starting a known viewer does not grant access. Every new request and
    # persisted active session still passes the live revocation authority.
    try:
        supervisor._start_gateway(root)
        supervisor._ensure_caddy(root)
        for route, record in supervisor._read(root / 'routes.json').items():
            if record.get('enabled'):
                supervisor._start_instance(root, route, int(record['localPort']))
        supervisor.sync(root)
        required = [8090, 2019]
        required += [int(item['localPort']) for item in supervisor._read(root/'routes.json').values() if item.get('enabled')]
        if not all(supervisor._listener_pid(port) for port in required):
            raise RuntimeError('A required host listener is unavailable')
        status('ready')
    except Exception as exc:
        # Log only error classes, not requests/configuration/credentials.
        status('degraded', 'Waiting for a host dependency: ' + type(exc).__name__)
        print('Host dependency will retry: ' + type(exc).__name__, flush=True)
    time.sleep(5)
