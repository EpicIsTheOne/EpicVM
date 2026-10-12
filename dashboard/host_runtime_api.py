"""Host-scoped outbound synchronization; no browser session privileges."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import threading
from urllib.parse import urlsplit

from flask import jsonify, request
try:
    from .direct_stream import configured_streams, validate_local_gateway
    from .direct_stream_auth import ROUTE_RE
except ImportError:
    from direct_stream import configured_streams, validate_local_gateway
    from direct_stream_auth import ROUTE_RE

_manifest_lock = threading.Lock()


def register_host_runtime(app, core):
    def enrollment():
        header = request.headers.get('Authorization', '')
        if not header.startswith('Bearer ') or len(header) > 512:
            return None
        try:
            try:
                records = json.loads(Path(os.environ.get('EPICVM_HOST_RUNTIME_ENROLLMENTS', '/opt/blobe-vm/private/host-runtime-enrollments.json')).read_text())
            except FileNotFoundError:
                records = {}
            if core.get('_setup_sync_records'):
                records = {**core['_setup_sync_records'](), **records}
            digest = hashlib.sha256(header[7:].encode()).hexdigest()
            for host_id, record in records.items():
                if record.get('enabled') is True and hmac.compare_digest(digest, record.get('tokenHash', '')):
                    return host_id, record
        except (OSError, ValueError, TypeError):
            pass
        return None

    def owned(route, host_id, record):
        if not ROUTE_RE.fullmatch(route):
            return False
        if route.startswith('seat-'):
            seat = core['_host_game_stream_record'](route)
            return bool(seat and seat['host_id'] == host_id)
        return route in record.get('vmRoutes', [])

    @app.post('/EpicVM/api/host-runtime/local-gateway')
    def local_gateway():
        identity=enrollment()
        if not identity:
            return jsonify(ok=False,error='Unauthorized'),401
        if request.content_length is None or request.content_length>4096:
            return jsonify(ok=False,error='Invalid local metadata'),413
        try:
            clean=validate_local_gateway(request.get_json(silent=True))
        except (ValueError,TypeError,AttributeError):
            return jsonify(ok=False,error='Invalid local metadata'),400
        target=Path(os.environ.get('EPICVM_LOCAL_STREAMS_FILE','/opt/blobe-vm/private/local-streams.json'))
        with _manifest_lock:
            try: merged=json.loads(target.read_text(encoding='utf-8'))
            except FileNotFoundError: merged={}
            if not isinstance(merged,dict):
                return jsonify(ok=False,error='Local configuration requires repair'),409
            previous=merged.get(identity[0],{})
            if previous and previous.get('mode')!='local-ca':
                return jsonify(ok=False,error='Existing local gateway retained'),409
            merged[identity[0]]=clean
            target.parent.mkdir(parents=True,exist_ok=True)
            temporary=target.with_suffix('.new')
            temporary.write_text(json.dumps(merged),encoding='utf-8');temporary.chmod(0o600);temporary.replace(target)
        return jsonify(ok=True)

    @app.get('/EpicVM/api/host-runtime/sync')
    def runtime_sync():
        identity = enrollment()
        if not identity:
            return jsonify(ok=False, error='Unauthorized'), 401
        host_id, record = identity
        root = Path(os.environ.get('EPICVM_MOONLIGHT_ROOT', '/opt/epicvm/moonlight-instances'))
        sources = {}
        for directory in root.iterdir():
            route = directory.name if directory.name.startswith('seat-') else 'vm-' + directory.name
            if directory.is_symlink() or not owned(route, host_id, record):
                continue
            path = directory / 'server/data.json'
            if path.is_symlink() or not path.is_file() or path.stat().st_size > 2 * 1024 * 1024:
                continue
            data = json.loads(path.read_text())
            if len(data.get('hosts', {})) == 1 and len(data.get('users', {})) == 1:
                host = next(iter(data['hosts'].values()))
                if host.get('pair_info'):
                    sources[route] = data
        if len(json.dumps(sources).encode()) > 16 * 1024 * 1024:
            return jsonify(ok=False, error='Host inventory too large'), 413
        return jsonify(ok=True, hostId=host_id, sources=sources)

    @app.post('/EpicVM/api/host-runtime/manifest')
    def runtime_manifest():
        identity = enrollment()
        if not identity:
            return jsonify(ok=False, error='Unauthorized'), 401
        if request.content_length is None or request.content_length > 256 * 1024:
            return jsonify(ok=False, error='Manifest too large'), 413
        host_id, record = identity
        manifest = request.get_json(silent=True)
        if not isinstance(manifest, dict) or len(manifest) > 128:
            return jsonify(ok=False, error='Invalid manifest'), 400
        clean = {}
        try:
            origin = record['publicOrigin']
            parsed = urlsplit(origin)
            if parsed.scheme != 'https' or not parsed.hostname or parsed.path or parsed.query or parsed.username or parsed.fragment:
                raise ValueError()
            for route, value in manifest.items():
                if not owned(route, host_id, record) or value.get('hostId') != host_id:
                    raise ValueError()
                path = value['streamPath']
                if not path.startswith(f'/EpicVM/{route}/stream.html?') or len(path) > 512 or any(c in path for c in '\r\n'):
                    raise ValueError()
                clean[route] = {'enabled': value.get('enabled') is True, 'hostId': host_id,
                                'hostUrl': origin, 'streamPath': path}
        except (KeyError, TypeError, ValueError):
            return jsonify(ok=False, error='Manifest outside enrolled host scope'), 403
        target = Path(os.environ.get('EPICVM_DIRECT_STREAMS_FILE', '/opt/blobe-vm/private/direct-streams.json'))
        with _manifest_lock:
            merged = configured_streams()
            # Existing routes belonging to other hosts cannot be replaced.
            if any(route in merged and merged[route].get('hostId') != host_id for route in clean):
                return jsonify(ok=False, error='Route belongs to another host'), 403
            for route, value in merged.items():
                if value.get('hostId') == host_id and route not in clean:
                    value['enabled'] = False
            merged.update(clean)
            temporary = target.with_suffix('.new')
            temporary.write_text(json.dumps(merged), encoding='utf-8')
            temporary.chmod(0o600)
            temporary.replace(target)
        return jsonify(ok=True)
