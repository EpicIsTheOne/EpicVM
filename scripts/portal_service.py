"""Windows-compatible WSGI runner for an independently configured portal."""
import json
import os
from pathlib import Path
import sys


def environment(state, package):
    state=Path(state);package=Path(package)
    setup=json.loads((state/'setup-state.json').read_text(encoding='utf-8'))
    secrets=json.loads((state/'setup-private.json').read_text(encoding='utf-8'))
    admin=json.loads((state/'portal-admin.json').read_text(encoding='utf-8'))
    data_root=Path(setup['configuration']['dataRoot']) if os.name=='nt' and setup['configuration'].get('dataRoot') else state
    if data_root!=state and not data_root.is_dir():raise ValueError('Selected data drive is unavailable.')
    root=data_root/'portal';root.mkdir(exist_ok=True)
    (root/'moonlight-instances').mkdir(exist_ok=True)
    return dict(BLOBEDASH_STATE=str(root),BLOBEDASH_USER=admin['username'],BLOBEDASH_PASS_HASH=admin['passwordHash'],
        DASH_V2_SECRET=secrets['dashboardSecret'],BLOBEVM_USER_SECRET=secrets['portalSecret'],EPICVM_REMOTE_HOST_KEY=secrets['remoteHostKey'],
        EPICVM_REMOTE_HOSTS_FILE=str(root/'remote-hosts.json'),EPICVM_HOST_RUNTIME_ENROLLMENTS=str(root/'host-runtime-enrollments.json'),
        EPICVM_DIRECT_STREAMS_FILE=str(root/'direct-streams.json'),EPICVM_MOONLIGHT_ROOT=str(root/'moonlight-instances'),
        EPICVM_CONSOLE_BACKEND='native-moonlight',EPICVM_VIEWER_PACKAGE=str(package/'viewer'),
        EPICVM_PUBLIC_ORIGIN=setup['configuration']['portalOrigin'],EPICVM_HOST_RUNTIME_ROOT=str(data_root/'host-runtime'),
        EPICVM_LOCAL_STREAMS_FILE=str(root/'local-streams.json'),
        EPI_MEMORY_DB=str(root/'epi-memory.sqlite3'),
        EPICVM_ALLOW_LOOPBACK_HOST='1' if setup['configuration']['layout']=='same-pc' else '0',EPICVM_HOSTING_PROFILE='multiseat',EPICVM_ENABLE_HOST_SETUP='1',EPICVM_REQUIRE_SETUP_CHECK='1',EPICVM_WEB_DIST=str(package/'epicvm_web/dist'))


def run(state,package):
    os.environ.update(environment(state,package))
    dashboard=Path(package)/'dashboard'
    sys.path.insert(0,str(dashboard))
    import app
    admin=json.loads((Path(state)/'portal-admin.json').read_text(encoding='utf-8'))
    if not app._get_user_by_username(admin['username']):
        app._init_users_db()
        with app._users_conn() as db:
            db.execute("INSERT INTO users(username,password_hash,is_admin,account_status) VALUES(?,?,1,'approved')", (admin['username'],admin['portalPasswordHash']))
    from werkzeug.middleware.proxy_fix import ProxyFix
    # Listener is loopback-only; only the local TLS gateway may proxy into it.
    app.app.wsgi_app = ProxyFix(app.app.wsgi_app, x_proto=1, x_host=1)
    from waitress import serve
    port=int(os.environ.get('EPICVM_PORTAL_PORT','5050'))
    if not 1024<=port<=65535:raise ValueError('Invalid portal listener port.')
    serve(app.app,host=os.environ.get('EPICVM_PORTAL_BIND','127.0.0.1'),port=port,threads=8,clear_untrusted_proxy_headers=False)

if __name__=='__main__':
    if len(sys.argv)!=3:raise SystemExit('Usage: portal_service.py PROTECTED_SETUP_ROOT PACKAGE_ROOT')
    run(sys.argv[1],sys.argv[2])
