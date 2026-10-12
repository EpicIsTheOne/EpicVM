"""Administrator-approved host enrollment bound to a device-held secret."""
import hashlib
import hmac
import json
import os
import secrets
import time
from flask import g, jsonify, request
from cryptography.fernet import Fernet
import base64


def register_host_enrollment(app, core, guard, data):
    def conn():
        return core['_users_conn']()

    def init():
        core['_init_users_db']()
        with conn() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS host_setup_requests (
                id TEXT PRIMARY KEY, code TEXT UNIQUE NOT NULL, proof_hash TEXT NOT NULL,
                host_id TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL,
                created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, source_hash TEXT NOT NULL,
                approver TEXT, error TEXT)''')
            db.execute('''CREATE TABLE IF NOT EXISTS host_setup_checks (
                host_id TEXT PRIMARY KEY, actor TEXT NOT NULL, route TEXT NOT NULL,
                video INTEGER NOT NULL, input INTEGER NOT NULL, checked_at INTEGER NOT NULL)''')

    def cipher():
        return Fernet(base64.urlsafe_b64encode(hashlib.sha256(core['_dashboard_secret']().encode()).digest()))

    def record(row):
        payload = json.loads(cipher().decrypt(row['payload'].encode()))
        with conn() as db:
            check=db.execute('SELECT checked_at FROM host_setup_checks WHERE host_id=? AND video=1 AND input=1',(row['host_id'],)).fetchone()
        try:
            from .direct_stream import local_stream_info
        except ImportError:
            from direct_stream import local_stream_info
        return dict(localConnection=local_stream_info(row['host_id']),id=row['id'], code=row['code'], hostId=row['host_id'], displayName=payload['display_name'],
                    agentUrl=payload['agent_url'], publicOrigin=payload['publicOrigin'],
                    state='expired' if row['expires_at'] < time.time() and row['state'] not in ('enrolled', 'active', 'revoked') else row['state'],
                    expiresAt=row['expires_at'], error=row['error'], connectionChecked=bool(check and check['checked_at']>=time.time()-3600))

    @app.before_request
    def enrollment_enabled():
        if request.path.startswith(('/EpicVM/api/host-setup/', '/EpicVM/api/management/host-setup')) and os.environ.get('EPICVM_ENABLE_HOST_SETUP') != '1':
            return jsonify(ok=False, error='Fresh host enrollment is not enabled on this instance.'), 404

    @app.post('/EpicVM/api/host-setup/start')
    def start():
        if not core['_request_is_https']():
            return jsonify(ok=False, error='Host enrollment requires HTTPS.'), 400
        if not core['_dashboard_secret']() or not core['_admin_credentials']()[0]:
            return jsonify(ok=False, error='Initialize the portal administrator first.'), 503
        if not request.is_json or (request.content_length or 0) > 8192:
            return jsonify(ok=False, error='A bounded JSON request is required.'), 400
        try:
            from remote_hosts import _normalize_record
        except ImportError:
            from .remote_hosts import _normalize_record
        try:
            payload = request.get_json()
            normalized = _normalize_record(dict(id=payload['hostId'], display_name=payload['displayName'],
                agent_url=payload['agentUrl'], token=payload['agentToken'], provider='multiseat', enabled=False))
            from urllib.parse import urlsplit
            origin = urlsplit(payload['publicOrigin'])
            if origin.scheme != 'https' or not origin.hostname or origin.path not in ('', '/') or origin.query or origin.fragment or origin.username or origin.password:
                raise ValueError('Use an HTTPS streaming origin without a path or credentials.')
            if normalized['id'] == 'local' or len(normalized['token']) < 32:
                raise ValueError('Invalid host identity or credential.')
            sync = payload['syncToken']
            if not isinstance(sync, str) or not 32 <= len(sync) <= 128 or any(c.isspace() for c in sync):
                raise ValueError('Invalid sync credential.')
            normalized.update(publicOrigin=payload['publicOrigin'].rstrip('/'), syncHash=hashlib.sha256(sync.encode()).hexdigest(), streamKey=secrets.token_hex(32))
        except (KeyError, TypeError, ValueError):
            return jsonify(ok=False, error='Invalid host identity, private agent address, streaming origin or credentials.'), 400
        init()
        now = int(time.time())
        source = hashlib.sha256((request.remote_addr or '').encode()).hexdigest()
        with conn() as db:
            db.execute('BEGIN IMMEDIATE')
            if db.execute('SELECT count(*) FROM host_setup_requests WHERE source_hash=? AND created_at>?', (source, now-3600)).fetchone()[0] >= 10:
                return jsonify(ok=False, error='Too many setup attempts. Try later.'), 429
            if db.execute("SELECT 1 FROM host_setup_requests WHERE host_id=? AND (expires_at>? OR state IN ('enrolled','active','revoked')) AND state NOT IN ('denied')", (normalized['id'], now)).fetchone():
                return jsonify(ok=False, error='This host already has an enrollment request.'), 409
            try:
                from remote_hosts import _read_all_remote_host_configs
            except ImportError:
                from .remote_hosts import _read_all_remote_host_configs
            if any(r['id'] == normalized['id'] for r in _read_all_remote_host_configs()):
                return jsonify(ok=False, error='Host ID already belongs to this instance.'), 409
            ident, proof, code = secrets.token_hex(16), secrets.token_urlsafe(32), secrets.token_hex(4).upper()
            encrypted = cipher().encrypt(json.dumps(normalized).encode()).decode()
            db.execute('INSERT INTO host_setup_requests VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                (ident, code, hashlib.sha256(proof.encode()).hexdigest(), normalized['id'], encrypted,
                 'pending', now, now+900, source, None, None))
        return jsonify(ok=True, id=ident, deviceToken=proof, code=code, expiresAt=now+900), 201

    @app.get('/EpicVM/api/host-setup/health')
    def setup_health():
        return jsonify(ok=True,profile=os.environ.get('EPICVM_HOSTING_PROFILE',''),
                       instanceId=hashlib.sha256(core['_dashboard_secret']().encode()).hexdigest()[:24])

    @app.get('/EpicVM/api/management/host-setup')
    @guard(admin=True)
    def pending():
        init()
        with conn() as db:
            rows = db.execute("SELECT * FROM host_setup_requests WHERE (state IN ('pending','approved') AND expires_at>?) OR state IN ('enrolled','active') ORDER BY created_at DESC", (int(time.time()),)).fetchall()
        return jsonify(ok=True, requests=[record(row) for row in rows])

    @app.post('/EpicVM/api/management/host-setup/<ident>')
    @guard(admin=True)
    def approve(ident):
        init()
        action = data().get('action')
        if action not in ('approve', 'deny'):
            raise ValueError('Choose approve or deny.')
        with conn() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT * FROM host_setup_requests WHERE id=?', (ident,)).fetchone()
            if not row or row['expires_at'] < time.time() or row['state'] != 'pending':
                return jsonify(ok=False, error='This setup request is no longer pending.'), 409
            db.execute('UPDATE host_setup_requests SET state=?,approver=? WHERE id=?',
                       ('approved' if action=='approve' else 'denied', g.account_actor['realm']+':'+g.account_actor['username'], ident))
        return jsonify(ok=True)

    @app.post('/EpicVM/api/host-setup/<ident>/claim')
    def claim(ident):
        if not core['_request_is_https']():
            return jsonify(ok=False, error='HTTPS required.'), 400
        init()
        proof = request.headers.get('Authorization', '').removeprefix('Bearer ')
        with conn() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT * FROM host_setup_requests WHERE id=?', (ident,)).fetchone()
            if not row or not hmac.compare_digest(row['proof_hash'], hashlib.sha256(proof.encode()).hexdigest()):
                return jsonify(ok=False, error='Unknown device.'), 401
            if row['expires_at'] < time.time() and row['state'] not in ('enrolled', 'active', 'revoked'):
                return jsonify(ok=False, state='expired'), 410
            if row['state'] in ('pending','denied','revoked'):
                return jsonify(ok=True, state=row['state'])
            if row['state'] == 'active':
                payload = json.loads(cipher().decrypt(row['payload'].encode()))
                return jsonify(ok=True, state='enrolled', hostId=row['host_id'], activated=True, streamKey=payload.get('streamKey'))
            if row['state'] == 'enrolled':
                payload = json.loads(cipher().decrypt(row['payload'].encode()))
                return jsonify(ok=True, state='enrolled', hostId=row['host_id'], activated=False, streamKey=payload.get('streamKey'))
            payload = json.loads(cipher().decrypt(row['payload'].encode()))
            # Registry writes are retryable. State becomes enrolled only when both
            # registry and host-scoped sync authority have been persisted.
            try:
                from remote_hosts import upsert_remote_host_config
            except ImportError:
                from .remote_hosts import upsert_remote_host_config
            upsert_remote_host_config({k:v for k,v in payload.items() if k not in ('publicOrigin','syncHash','streamKey')})
            db.execute("UPDATE host_setup_requests SET state='enrolled',error=NULL WHERE id=?", (ident,))
        core['VM_HOST_REGISTRY'].refresh(force=True)
        return jsonify(ok=True, state='enrolled', hostId=row['host_id'], activated=False, streamKey=payload.get('streamKey'))

    @app.post('/EpicVM/api/management/host-setup/<ident>/activation')
    @guard(admin=True)
    def activation(ident):
        init()
        payload_request = data()
        action = payload_request.get('action')
        if action == 'activate' and payload_request.get('streamVerified') is not True:
            raise ValueError('Verify real video and input before activating this host.')
        if action not in ('activate', 'revoke'):
            raise ValueError('Choose activate or revoke.')
        with conn() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT * FROM host_setup_requests WHERE id=?', (ident,)).fetchone()
            if not row or row['state'] not in ('enrolled', 'active'):
                return jsonify(ok=False, error='This host is not enrolled.'), 409
            payload = json.loads(cipher().decrypt(row['payload'].encode()))
            if action == 'activate':
                if os.environ.get('EPICVM_REQUIRE_SETUP_CHECK') == '1':
                    check=db.execute('SELECT * FROM host_setup_checks WHERE host_id=?',(row['host_id'],)).fetchone()
                    if not check or not check['video'] or not check['input'] or check['checked_at'] < time.time()-3600:
                        return jsonify(ok=False,error='Complete the desktop video and input check before activation.'),409
                try:
                    from .remote_agent_client import RemoteAgentClient
                except ImportError:
                    from remote_agent_client import RemoteAgentClient
                # Only an admin-approved, validated private management address is probed.
                try:
                    client = RemoteAgentClient(payload['agent_url'], payload['token'], timeout=5)
                    view = client._request('GET', '/v1/host-gaming')
                    if not view.get('ready'):
                        raise ValueError()
                except Exception:
                    return jsonify(ok=False, error='The enrolled host is not ready. Complete its component setup first.'), 409
            try:
                from remote_hosts import upsert_remote_host_config
            except ImportError:
                from .remote_hosts import upsert_remote_host_config
            record = {k:v for k,v in payload.items() if k not in ('publicOrigin','syncHash','streamKey')}
            record['enabled'] = action == 'activate'
            upsert_remote_host_config(record)
            db.execute('UPDATE host_setup_requests SET state=? WHERE id=?', ('active' if action=='activate' else 'revoked', ident))
        core['VM_HOST_REGISTRY'].refresh(force=True)
        return jsonify(ok=True)

    # Only finalized, enabled enrollment requests grant synchronization authority.
    def sync_records():
        if os.environ.get('EPICVM_ENABLE_HOST_SETUP') != '1':
            return {}
        init()
        with conn() as db:
            rows = db.execute("SELECT * FROM host_setup_requests WHERE state IN ('enrolled','active')").fetchall()
        try:
            from remote_hosts import _read_all_remote_host_configs
        except ImportError:
            from .remote_hosts import _read_all_remote_host_configs
        registry = {r['id']:r for r in _read_all_remote_host_configs()}
        result = {}
        for row in rows:
            payload = json.loads(cipher().decrypt(row['payload'].encode()))
            current = registry.get(row['host_id'])
            if not current or current['token'] != payload['token'] or (row['state']=='active' and not current['enabled']):
                continue
            result[row['host_id']] = dict(enabled=True, tokenHash=payload['syncHash'], publicOrigin=payload['publicOrigin'], vmRoutes=[])
        return result
    core['_setup_sync_records'] = sync_records

    def stream_key(host_id):
        if os.environ.get('EPICVM_ENABLE_HOST_SETUP') != '1':
            return None
        init()
        with conn() as db:
            row = db.execute('SELECT * FROM host_setup_requests WHERE host_id=? ORDER BY created_at DESC LIMIT 1', (host_id,)).fetchone()
        if not row:
            return None  # Legacy hosts retain their existing signing authority.
        if row['state'] not in ('enrolled', 'active') or host_id not in sync_records():
            raise ValueError('Host enrollment is unavailable or revoked.')
        payload = json.loads(cipher().decrypt(row['payload'].encode()))
        key = payload.get('streamKey')
        if not isinstance(key, str) or len(key) != 64:
            raise ValueError('Host signing authority requires repair.')
        return bytes.fromhex(key)
    core['_setup_stream_key'] = stream_key

    def setup_host_active(host_id):
        if os.environ.get('EPICVM_ENABLE_HOST_SETUP')!='1':return True
        init()
        with conn() as db:
            row=db.execute('SELECT state FROM host_setup_requests WHERE host_id=? ORDER BY created_at DESC LIMIT 1',(host_id,)).fetchone()
        return row is None or row['state']=='active'
    core['_setup_host_active']=setup_host_active

    def setup_host_client(host_id):
        actor=getattr(g,'account_actor',None)
        if not actor or not actor.get('isAdmin') or os.environ.get('EPICVM_ENABLE_HOST_SETUP')!='1':
            return None
        init()
        with conn() as db:
            row=db.execute("SELECT * FROM host_setup_requests WHERE host_id=? AND state='enrolled'",(host_id,)).fetchone()
        if not row:
            return None
        payload=json.loads(cipher().decrypt(row['payload'].encode()))
        try:
            from .remote_agent_client import RemoteAgentClient
        except ImportError:
            from remote_agent_client import RemoteAgentClient
        return RemoteAgentClient(payload['agent_url'],payload['token'],timeout=5)
    core['_setup_host_client']=setup_host_client

    @app.post('/EpicVM/api/management/host-setup/<ident>/connection-check')
    @guard(admin=True)
    def connection_check(ident):
        init()
        submitted=data()
        actor=g.account_actor
        with conn() as db:
            row=db.execute("SELECT * FROM host_setup_requests WHERE id=? AND state IN ('enrolled','active')",(ident,)).fetchone()
            if not row:
                return jsonify(ok=False,error='Finish device enrollment first.'),409
            route=submitted.get('route','')
            seat=core['_host_game_stream_record'](route)
            if not seat or seat['host_id']!=row['host_id'] or seat['realm']!=actor['realm'] or seat['username']!=actor['username']:
                return jsonify(ok=False,error='Check your own test desktop on this host.'),403
            from pathlib import Path
            try:
                manifest=json.loads(Path(os.environ['EPICVM_DIRECT_STREAMS_FILE']).read_text())
                published=manifest[route]
                if published.get('hostId')!=row['host_id'] or published.get('enabled') is not True:
                    raise ValueError()
            except (OSError,KeyError,ValueError,TypeError):
                return jsonify(ok=False,error='Wait for the runtime to publish the paired desktop, then retry.'),409
            if submitted.get('videoVisible') is not True or submitted.get('inputWorked') is not True:
                return jsonify(ok=False,error='Confirm changing video and keyboard/mouse input in the test desktop.'),400
            db.execute('INSERT OR REPLACE INTO host_setup_checks VALUES(?,?,?,?,?,?)',
                       (row['host_id'],actor['realm']+':'+actor['username'],route,1,1,int(time.time())))
        return jsonify(ok=True,message='Operator-confirmed video and input recorded. External-network and cold-boot checks remain separate.')
