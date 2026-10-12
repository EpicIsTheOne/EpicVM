"""Real Flask account/report flow with a disposable database and fake host."""
import os
import sys
import tempfile
import shutil
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
state = tempfile.mkdtemp(prefix='epicvm-support-browser-')
os.environ.update(BLOBEDASH_STATE=state, BLOBEDASH_USER='rootadmin', BLOBEDASH_PASS='admin-original',
                  DASH_V2_SECRET='support-fixture', BLOBEVM_USER_SECRET='support-fixture-portal')
os.environ.pop('BLOBEDASH_PASS_HASH', None)
sys.path.insert(0, str(ROOT / 'dashboard'))
import app
from flask import send_file

app._resource_inventory = lambda **kw: ([], [])
class Registry:
    def refresh(self): pass
    def public_records(self):
        return [{'id': 'epic-pc', 'display_name': 'Test host', 'host_name': 'Test host',
                 'platform': 'windows', 'online': True, 'capabilities': {}}]
app.VM_HOST_REGISTRY = Registry()
def pending(): return app.jsonify(ok=True, jobs=[])
pending.__wrapped__ = pending
app.api_provisioning_jobs_pending = pending
fixture_mode = {'mode': 'paused'}
def call(method, path, payload=None, **kw):
    if path == '/v1/game-library': return {'ok': True, 'games': [], 'assignments': {}}
    if method == 'POST': raise ValueError('Fixture connection failure')
    return {'ok': True, 'apiVersion': 3, 'ready': True, 'hostOnline': True, 'games': [], 'hosting': {'paused': fixture_mode['mode'] in ('paused','resume'), 'full': fixture_mode['mode'] in ('full','resume'), 'seatCount': 1 if fixture_mode['mode'] in ('full','resume') else 0, 'maxSeats': 1}, 'seats': [{'id':'fixture-seat','accountName':'evseat_1dde4819bb7c7','status':'Ready'}] if fixture_mode['mode']=='resume' else []}
app._vm_host = lambda _: SimpleNamespace(client=SimpleNamespace(_request=call, base_url='http://100.72.220.117:8765/'), host_name='Test host')
app._create_user('support-fixture', 'fixture-password', is_admin=True)
app._create_user('friend-fixture', 'fixture-password', is_admin=False)
shutil.copytree(ROOT / 'epicvm_web' / 'dist', Path(state) / 'epicvm_web' / 'dist')

@app.app.get('/__recovery.js')
def recovery_module(): return send_file(ROOT / 'scripts/stream_recovery.js')

@app.app.get('/__recovery')
def recovery_page():
    return '''<html><body><h1>Isolated stream recovery</h1><script type="module">
    import { installStreamRecovery } from '/__recovery.js';
    const exit=document.createElement('button');document.body.append(exit);
    const app={getStream:()=>null,reloadStream:async()=>{},sidebar:{exitStreamButton:exit}};
    const recovery=installStreamRecovery(app);recovery.tick(false,true);
    </script></body></html>'''

with app._users_conn() as conn:
    conn.execute("CREATE TABLE IF NOT EXISTS host_desktop_grants (realm TEXT,username TEXT,host_id TEXT,PRIMARY KEY(realm,username,host_id))")
    conn.execute("INSERT INTO host_desktop_grants VALUES('portal','friend-fixture','epic-pc')")

@app.app.get('/__mode/<mode>')
def fixture_mode_route(mode):
    assert mode in ('paused','full','resume','ready')
    fixture_mode['mode'] = mode
    return app.jsonify(ok=True)

@app.app.get('/__fixture/<name>')
def fixture_login(name):
    assert name in ('friend-fixture', 'support-fixture')
    response=app.redirect('/EpicVM/portal')
    response.set_cookie('Portal-Auth', app._create_portal_token(name))
    return response

app.app.run(host='127.0.0.1', port=5223, threaded=True, use_reloader=False)
