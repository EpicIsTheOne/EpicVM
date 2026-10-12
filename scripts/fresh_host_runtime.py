"""Create fresh runtime inputs without importing accounts, pairing or certificates."""
import json
import os
from pathlib import Path
import re
import sqlite3
from urllib.parse import urlsplit

from fresh_host_setup import atomic, origin


def write_private(path, data):
    path = Path(path)
    if path.exists():
        if path.read_bytes() != data:
            raise ValueError('Existing private runtime state differs. Repair is required.')
        return
    temporary = path.with_suffix(path.suffix + '.new')
    with temporary.open('xb') as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def site(value):
    value = origin(value)
    parsed = urlsplit(value)
    # Configured DNS authority only; never interpolate Caddy syntax from input.
    if not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?', parsed.hostname):
        raise ValueError('Use a DNS hostname for automatic HTTPS.')
    if parsed.port not in (None, 443):
        raise ValueError('Automatic public HTTPS requires port 443.')
    return parsed.hostname


def prepare_gateway(setup_root, runtime_root):
    setup_root, root = Path(setup_root), Path(runtime_root)
    c=json.loads((setup_root/'setup-state.json').read_text(encoding='utf-8'))['configuration']
    stream_site, portal_site = site(c['publicOrigin']), site(c['portalOrigin'])
    root.mkdir(parents=True,exist_ok=True)
    route_file=str(root/'caddy-routes.caddy').replace('\\','/')
    if not (root/'caddy-routes.caddy').exists():
        (root/'caddy-routes.caddy').write_text('handle_path /EpicVM/auth/* {\n reverse_proxy 127.0.0.1:8090\n}\n',encoding='utf-8')
    same=c['layout']=='same-pc'
    block=f'{stream_site} {{\n import "{route_file}"\n'
    if same and portal_site==stream_site:
        block+=' handle {\n  reverse_proxy 127.0.0.1:5050\n }\n'
    block+='}\n'
    if same and portal_site!=stream_site:
        block+=f'{portal_site} {{\n reverse_proxy 127.0.0.1:5050\n}}\n'
    write_private(root/'Caddyfile',('{\n admin 127.0.0.1:2019\n}\n'+block).encode())
    return dict(ok=True,stage='gateway-prepared',streamVerified=False)


def prepare_runtime(setup_root, runtime_root, package_root, operator_sid):
    setup_root, root, package = map(Path, (setup_root, runtime_root, package_root))
    state = json.loads((setup_root/'setup-state.json').read_text(encoding='utf-8'))
    private = json.loads((setup_root/'setup-private.json').read_text(encoding='utf-8'))
    c = state['configuration']
    if state['stage'] not in ('enrolled', 'runtime-prepared', 'runtime-installed', 'connection-check', 'complete'):
        raise ValueError('Finish portal approval before installing the runtime.')
    if not re.fullmatch(r'S-1-5-21-(?:\d+-){2}\d+-\d+', operator_sid):
        raise ValueError('Choose the local Windows operator account.')
    key = private.get('streamKey', '')
    if not re.fullmatch(r'[a-f0-9]{64}', key):
        raise ValueError('This enrollment is missing host-specific signing authority.')
    site(c['publicOrigin'])
    site(c['portalOrigin'])
    expected = dict(hostId=c['hostId'], portalOrigin=c['portalOrigin'], publicOrigin=c['publicOrigin'],
                    stateRoot=str(root), syncTokenFile=str(root/'sync.token'), pythonExe=str(package/'python/python.exe'),
                    scriptsRoot=str(package/'scripts'), viewerPackage=str(package/'viewer'),
                    caddyExe=str(package/'gateway/caddy.exe'), caddyConfig=str(root/'Caddyfile'))
    if (root/'host-runtime.json').exists():
        if json.loads((root/'host-runtime.json').read_text(encoding='utf-8')) != expected:
            raise ValueError('Runtime already belongs to a different setup. Repair is required.')
    root.mkdir(parents=True, exist_ok=True)
    for directory in ('logs', 'profile/Caddy', 'profile-local'):
        (root/directory).mkdir(parents=True, exist_ok=True)
    write_private(root/'signing.key', bytes.fromhex(key))
    write_private(root/'sync.token', private['syncToken'].encode())
    write_private(root/'operator.sid', operator_sid.encode())
    for file in ('routes.json', 'dashboard-manifest.json'):
        if not (root/file).exists():
            atomic(root/file, {})
    if not (root/'hosting-policy.json').exists():
        atomic(root/'hosting-policy.json', dict(paused=False, maxSeats=1, width=1920, height=1080, fps=60))
    with sqlite3.connect(root/'nonces.sqlite3') as db:
        db.execute('CREATE TABLE IF NOT EXISTS used_grants (jti TEXT PRIMARY KEY, expires INTEGER NOT NULL)')
    template = dict(
        data_storage=dict(type='json', path='server/data.json', session_expiration_check_interval=dict(secs=300,nanos=0)),
        webrtc=dict(ice_servers=[dict(urls=['stun:stun.l.google.com:19302'],username='',credential='')],
                    ice_server_script=None, port_range=dict(min=40900,max=40910),nat_1to1=None,
                    network_types=['udp4'],include_loopback_candidates=False),
        web_server=dict(bind_address='127.0.0.1:41000',url_path_prefix='/EpicVM',session_cookie_secure=True,
                        session_cookie_expiration=dict(secs=86400,nanos=0),first_login_create_admin=False,
                        first_login_assign_global_hosts=False,default_user_id=None,default_role_id=None,
                        forwarded_header=dict(username_header='X-EpicVM-User',auto_create_missing_user=False,ignore_case=False)),
        moonlight=dict(default_http_port=47989,pair_device_name='EpicVM'),streamer_path='./streamer.exe',
        log=dict(level_filter='INFO',file_path=None,dev_venator=False),default_settings=None)
    atomic(root/'template-config.json',template)
    for file in ('host_stream_gateway.py', 'direct_stream_auth.py'):
        source = package/'scripts'/file
        write_private(root/file, source.read_bytes())
    prepare_gateway(setup_root, root)
    atomic(root/'host-runtime.json', expected)
    state.update(stage='runtime-prepared')
    atomic(setup_root/'setup-state.json',state)
    return dict(ok=True, stage='runtime-prepared', hostId=c['hostId'], streamVerified=False)


if __name__ == '__main__':
    import argparse
    p=argparse.ArgumentParser()
    for name in ('setup_root','runtime_root','package_root','operator_sid'):
        p.add_argument(name,nargs='?')
    p.add_argument('--gateway-only',action='store_true')
    a=p.parse_args()
    try:
        print(json.dumps(prepare_gateway(a.setup_root,a.runtime_root) if a.gateway_only else prepare_runtime(a.setup_root,a.runtime_root,a.package_root,a.operator_sid)))
    except Exception as exc:
        print(json.dumps(dict(ok=False,error=str(exc) if isinstance(exc,ValueError) else 'Runtime preparation failed: '+type(exc).__name__)))
        raise SystemExit(1)
