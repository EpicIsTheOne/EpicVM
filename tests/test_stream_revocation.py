import json
import re
import sqlite3
from html import unescape

import pytest
from dashboard.direct_stream_auth import issue_grant, issue_session, verify_grant
from scripts.host_stream_gateway import Gateway
from test_resource_identity import load_app


@pytest.fixture
def stream(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    module._create_user('alice', 'original-password')
    module._update_user('alice', account_status='approved')
    route = 'seat-' + 'a' * 24
    key = tmp_path / 'key'
    key.write_bytes(b'a' * 32)
    records = tmp_path / 'streams.json'
    records.write_text(json.dumps({route: {'enabled': True, 'hostId': 'pc', 'hostUrl': 'https://example.com',
                                          'streamPath': f'/EpicVM/{route}/stream.html'}}))
    monkeypatch.setenv('EPICVM_DIRECT_STREAM_KEY_FILE', str(key))
    monkeypatch.setenv('EPICVM_DIRECT_STREAMS_FILE', str(records))
    monkeypatch.setattr(module, '_admin_vm_sso_authenticated', lambda: False)
    owner = {'host_id': 'pc', 'realm': 'portal', 'username': 'alice'}
    monkeypatch.setattr(module, '_host_game_stream_record', lambda _: owner)
    client = module.app.test_client()
    client.set_cookie('Portal-Auth', module._create_portal_token('alice'))
    response = client.get(f'/EpicVM/stream-launch/{route}')
    assert response.status_code == 200
    grant = unescape(re.search(r'name="grant" value="([^"]+)"', response.text)[1])
    token = issue_session(key.read_bytes(), verify_grant(key.read_bytes(), grant))
    def validate(value=token):
        return client.post('/EpicVM/api/stream/validate', json={'route': route, 'token': value}).status_code
    return module, owner, validate, route, token, key


@pytest.mark.parametrize('change', ['password', 'disable', 'reject', 'owner', 'delete'])
def test_existing_stream_is_revoked(stream, change):
    module, owner, validate, *_ = stream
    assert validate() == 204
    if change == 'password':
        module._update_user('alice', password='new-password')
    elif change == 'disable':
        module._update_user('alice', disabled=True)
    elif change == 'reject':
        module._update_user('alice', account_status='rejected')
    elif change == 'owner':
        owner['username'] = 'bob'
    else:
        module._delete_user('alice')
    assert validate() == 401


def test_unsigned_and_legacy_sessions_are_denied(stream):
    _, _, validate, route, _, key = stream
    grant = verify_grant(key.read_bytes(), issue_grant(key.read_bytes(), route=route, user='portal:alice', path=f'/EpicVM/{route}/'))
    assert validate(issue_session(key.read_bytes(), grant)) == 401
    assert validate('garbage') == 401


def test_admin_password_change_revokes_admin_stream(stream, monkeypatch):
    module, _, validate, route, _, key = stream
    monkeypatch.setenv('BLOBEDASH_USER', 'admin')
    monkeypatch.setenv('BLOBEDASH_PASS', 'original-admin')
    monkeypatch.setattr(module, '_current_portal_user', lambda: None)
    monkeypatch.setattr(module, '_admin_vm_sso_authenticated', lambda: True)
    client = module.app.test_client()
    response = client.get(f'/EpicVM/stream-launch/{route}')
    grant = unescape(re.search(r'name="grant" value="([^"]+)"', response.text)[1])
    token = issue_session(key.read_bytes(), verify_grant(key.read_bytes(), grant))
    assert validate(token) == 204
    monkeypatch.setenv('BLOBEDASH_PASS', 'changed-admin')
    assert validate(token) == 401


def test_vm_assignment_is_rechecked(stream, monkeypatch):
    module, _, _, _, _, key = stream
    records = {'vm-test': {'enabled': True, 'hostId': 'pc', 'hostUrl': 'https://example.com', 'streamPath': '/EpicVM/vm-test/'}}
    import dashboard.direct_stream as direct
    # The app imports its modules without package qualification in this fixture.
    import sys
    direct = sys.modules.get('direct_stream', direct)
    monkeypatch.setattr(direct, 'configured_streams', lambda: records)
    allowed = [True]
    monkeypatch.setattr(module, '_user_can_access_vm', lambda *a, **kw: allowed[0])
    client = module.app.test_client()
    client.set_cookie('Portal-Auth', module._create_portal_token('alice'))
    response = client.get('/EpicVM/stream-launch/vm-test')
    grant = unescape(re.search(r'name="grant" value="([^"]+)"', response.text)[1])
    token = issue_session(key.read_bytes(), verify_grant(key.read_bytes(), grant))
    body = {'route': 'vm-test', 'token': token}
    assert client.post('/EpicVM/api/stream/validate', json=body).status_code == 204
    allowed[0] = False
    assert client.post('/EpicVM/api/stream/validate', json=body).status_code == 401


def test_monitor_closes_only_revoked_resource_and_retains_failed_teardown(tmp_path):
    key = tmp_path / 'key'
    key.write_bytes(b'a' * 32)
    routes = tmp_path / 'routes.json'
    routes.write_text(json.dumps({name: {'enabled': True} for name in ('vm-one', 'vm-two')}))
    closed = []
    gateway = Gateway(('127.0.0.1', 0), key_path=key, routes_path=routes, nonces_path=tmp_path / 'nonces', disconnect=closed.append)
    try:
        for route in ('vm-one', 'vm-two'):
            grant = verify_grant(key.read_bytes(), issue_grant(key.read_bytes(), route=route, user='portal:alice', path=f'/EpicVM/{route}/'))
            gateway.remember(route, issue_session(key.read_bytes(), grant))
        gateway.validate = lambda route, _, **kw: route != 'vm-one'
        gateway.check_sessions()
        assert closed == ['vm-one']
        assert set(gateway.sessions.values()) == {'vm-two'}
        with sqlite3.connect(gateway.nonces_path) as db:
            assert dict(db.execute('SELECT token, route FROM stream_sessions')) == gateway.sessions
        gateway.validate = lambda *args, **kw: False
        def fail(_):
            raise OSError('temporary failure')
        gateway.disconnect = fail
        with pytest.raises(OSError):
            gateway.check_sessions()
        assert set(gateway.sessions.values()) == {'vm-two'}
    finally:
        gateway.server_close()


def test_validation_outage_clears_short_lease_and_tracking_survives_restart(tmp_path, monkeypatch):
    import scripts.host_stream_gateway as host
    key = tmp_path / 'key'
    key.write_bytes(b'a' * 32)
    routes = tmp_path / 'routes.json'
    routes.write_text('{"vm-one": {"enabled": true}}')
    kwargs = dict(key_path=key, routes_path=routes, nonces_path=tmp_path / 'nonces')
    gateway = Gateway(('127.0.0.1', 0), **kwargs)
    try:
        grant = verify_grant(key.read_bytes(), issue_grant(key.read_bytes(), route='vm-one', user='portal:alice', path='/EpicVM/vm-one/'))
        token = issue_session(key.read_bytes(), grant)
        gateway.remember('vm-one', token)
        gateway.authority = 'https://authority.example/validate'
        gateway.validated[('vm-one', token)] = host.time.monotonic() + 2
        assert gateway.validate('vm-one', token)
        def unavailable(*a, **kw):
            raise OSError('network unavailable')
        monkeypatch.setattr(host.request, 'urlopen', unavailable)
        assert not gateway.validate('vm-one', token, fresh=True)
        assert not gateway.validate('vm-one', token)
    finally:
        gateway.server_close()
    restarted = Gateway(('127.0.0.1', 0), **kwargs)
    try:
        assert restarted.sessions == {token: 'vm-one'}
    finally:
        restarted.server_close()
