"""Security boundaries for external Windows account assignment and launch."""
import hashlib
import json
import re
import threading
import time
from html import unescape
from types import SimpleNamespace

import pytest

from dashboard.direct_stream_auth import issue_session, verify_grant
from test_account_workspace import workspace, login, post


@pytest.fixture
def external(workspace, monkeypatch, tmp_path):
    calls = []
    mapping = {}
    seat = {'id': 'existing-seat', 'accountName': 'FriendDesktop', 'status': 'Ready', 'portBase': 48100}

    def agent(method, path, payload=None, **kwargs):
        calls.append((method, path, dict(payload or {})))
        if path == '/v1/host-gaming/local-account-assign':
            sid = payload['accountSid']
            mapping[payload['owner']] = {'accountSid': sid, 'accountName': 'FriendDesktop'} if sid else None
            return {'ok': True, 'assignment': mapping[payload['owner']]}
        if path == '/v1/host-gaming/local-accounts':
            return {'accounts': [{'accountSid': 'S-1-5-21-123-1001', 'accountName': 'FriendDesktop'}]}
        if path == '/v1/host-gaming/desktop':
            if payload.get('windowsPassword') != 'test-password-only':
                from remote_agent_client import RemoteAgentError
                raise RemoteAgentError('Windows password rejected', status=403)
            assert payload['accountSid'] == 'S-1-5-21-123-1001'
            return {'ok': True, 'seatId': seat['id'], 'portBase': seat['portBase']}
        return {'ok': True, 'apiVersion': 3, 'ready': True, 'supportsExistingLocalAccounts': True, 'games': [], 'seats': [seat]}

    class Streams:
        def quarantine_staged(self, name): pass
        def build_plan(self, **kwargs): return kwargs
        def stage_plan(self, plan): pass
        def start_staged(self, name): pass
        def pair_staged(self, name, *, pin_submitter): pin_submitter('1234')
        def _runtime_isolated(self, name): return True
        def verify_staged(self, name, **kwargs): pass

    monkeypatch.setattr(workspace, '_console_orchestrator', lambda: Streams())
    monkeypatch.setattr(workspace, '_vm_host', lambda _: SimpleNamespace(client=SimpleNamespace(_request=agent, base_url='http://100.72.220.117:8765/')))
    monkeypatch.setattr(workspace.VM_HOST_REGISTRY, 'public_records', lambda: [{'id': 'epic-pc', 'platform': 'windows'}])
    admin = login(workspace, 'rootadmin', dashboard=True)
    result = post(admin, 'management/host-gaming/local-account-assign', username='alice', accountSid='S-1-5-21-123-1001')
    assert result.status_code == 200, result.data
    alice, bob = login(workspace), login(workspace, 'bob')
    route = 'seat-' + hashlib.sha256(b'portal:alice:epic-pc').hexdigest()[:24]
    key = tmp_path / 'key'
    key.write_bytes(b'a' * 32)
    records = tmp_path / 'streams.json'
    records.write_text(json.dumps({route: {'enabled': True, 'hostId': 'epic-pc', 'hostUrl': 'https://example.com', 'streamPath': f'/EpicVM/{route}/stream.html'}}))
    monkeypatch.setenv('EPICVM_DIRECT_STREAM_KEY_FILE', str(key))
    monkeypatch.setenv('EPICVM_DIRECT_STREAMS_FILE', str(records))
    return SimpleNamespace(core=workspace, admin=admin, alice=alice, bob=bob, calls=calls, route=route, key=key, agent=agent)


def test_assignment_permissions_uniqueness_and_owner_privacy(external):
    e = external
    assert post(e.bob, 'management/host-gaming/local-account-assign', username='bob', accountSid='S-1-5-21-123-1001').status_code == 403
    assert post(e.admin, 'management/host-gaming/local-account-assign', username='bob', accountSid='S-1-5-21-123-1001').status_code == 400
    assert e.alice.get('/EpicVM/api/account/host-gaming').json['seat']['accountName'] == 'FriendDesktop'
    assert e.alice.get('/EpicVM/api/account/host-gaming/desktops').json['desktops'][0]['requiresWindowsPassword'] is True
    body = e.bob.get('/EpicVM/api/account/host-gaming').json
    assert body['seat'] is None and body['requiresWindowsPassword'] is False
    assert 'FriendDesktop' not in json.dumps(body)
    assert post(e.admin, 'management/host-gaming/account-credential/reveal', username='alice').status_code == 400
    assert not any(path.endswith('credential/reveal') for _, path, _ in e.calls)


def test_admin_stream_actions_exclude_existing_account_credentials(external):
    e = external
    assert post(e.alice, 'account/host-gaming/desktop', windowsPassword='test-password-only').status_code == 200
    catalog = e.admin.get('/EpicVM/api/management/host-gaming').json
    stream = next(item for item in catalog['streams'] if item['username'] == 'alice')
    assert stream['accountName'] == 'FriendDesktop'
    assert stream['requiresWindowsPassword'] is True
    assert 'alice' not in catalog['credentialOwners']


def test_recovery_rejects_unassigned_seat_before_stream_changes(external, monkeypatch):
    e = external
    assert post(e.alice, 'account/host-gaming/desktop', windowsPassword='test-password-only').status_code == 200

    def agent(method, path, payload=None, **kwargs):
        response = e.agent(method, path, payload, **kwargs)
        if path == '/v1/host-gaming' and method == 'GET':
            response['seats'][0]['epicvmOwned'] = False
        return response

    monkeypatch.setattr(e.core, '_vm_host', lambda _: SimpleNamespace(client=SimpleNamespace(_request=agent, base_url='http://100.72.220.117:8765/')))
    assert post(e.admin, 'management/host-gaming/recover', seatId='existing-seat').status_code == 400
    with e.core._users_conn() as conn:
        assert conn.execute("SELECT 1 FROM host_game_streams WHERE username='alice'").fetchone()
    assert not any(path.endswith('/recover') for _, path, _ in e.calls)


def test_password_required_on_every_resume_and_cached_links_are_blocked(external, monkeypatch):
    e = external
    assert post(e.alice, 'account/host-gaming/desktop').status_code == 400
    assert post(e.alice, 'account/host-gaming/desktop', windowsPassword='wrong').status_code == 400
    launched = post(e.alice, 'account/host-gaming/desktop', windowsPassword='test-password-only')
    assert launched.status_code == 200, launched.data
    url = launched.json['launchUrl']
    assert '?unlock=' in url
    assert e.alice.get('/EpicVM/stream-launch/' + e.route).status_code == 403
    assert e.bob.get(url).status_code == 403
    # A rejected access check must not burn the owner's one-use unlock.
    response = e.alice.get(url)
    assert response.status_code == 200
    assert e.alice.get(url).status_code == 403
    assert post(e.alice, 'account/host-gaming/desktop').status_code == 400
    monkeypatch.setattr(e.core, '_admin_vm_sso_authenticated', lambda: True)
    assert e.admin.get('/EpicVM/stream-launch/' + e.route).status_code == 403


def test_assignment_revision_revokes_prechange_streams(external):
    e = external
    url = post(e.alice, 'account/host-gaming/desktop', windowsPassword='test-password-only').json['launchUrl']
    page = e.alice.get(url)
    grant = unescape(re.search(r'name="grant" value="([^"]+)"', page.text)[1])
    token = issue_session(e.key.read_bytes(), verify_grant(e.key.read_bytes(), grant))
    body = {'route': e.route, 'token': token}
    assert e.alice.post('/EpicVM/api/stream/validate', json=body).status_code == 204
    with e.core._users_conn() as conn:
        conn.execute("UPDATE host_local_account_assignments SET account_sid=NULL, generation='changed' WHERE username='alice'")
    assert e.alice.post('/EpicVM/api/stream/validate', json=body).status_code == 401


def test_expired_unlock_and_local_fallback(external, monkeypatch, tmp_path):
    e = external
    url = post(e.alice, 'account/host-gaming/desktop', windowsPassword='test-password-only').json['launchUrl']
    with e.core._users_conn() as conn:
        conn.execute('UPDATE host_account_unlocks SET expires=0')
    assert e.alice.get(url).status_code == 403
    settings = tmp_path / 'local.json'
    settings.write_text(json.dumps({'epic-pc': {'enabled': True, 'origin': 'https://lan.example.com:8443'}}))
    monkeypatch.setenv('EPICVM_LOCAL_STREAMS_FILE', str(settings))
    url = post(e.alice, 'account/host-gaming/desktop', windowsPassword='test-password-only').json['launchUrl']
    page = e.alice.get(url + '&connection=local')
    assert page.status_code == 200
    grants = re.findall(r'name="grant" value="([^"]+)"', page.text)
    assert len(grants) == 2
    local, normal = [verify_grant(e.key.read_bytes(), unescape(value)) for value in grants]
    assert 'connection=local' in local['path']
    assert 'connection=local' not in normal['path']
    assert local['revision'] == normal['revision']
    assert e.alice.get(url).status_code == 403


def test_password_never_enters_persisted_launch_job(external, monkeypatch):
    e = external
    entered, release = threading.Event(), threading.Event()
    def agent(method, path, payload=None, **kwargs):
        if path == '/v1/host-gaming/desktop':
            entered.set()
            assert release.wait(5)
        return e.agent(method, path, payload, **kwargs)
    monkeypatch.setattr(e.core, '_vm_host', lambda _: SimpleNamespace(client=SimpleNamespace(_request=agent, base_url='http://100.72.220.117:8765/')))
    try:
        result = post(e.alice, 'account/host-gaming/desktop', windowsPassword='test-password-only', **{'async': True})
        assert result.status_code == 202
        assert entered.wait(2)
        assert post(e.alice, 'account/host-gaming/desktop', windowsPassword='test-password-only', **{'async': True}).status_code == 409
        assert post(e.admin, 'management/host-gaming/local-account-assign', username='alice', accountSid='').status_code == 409
        with e.core._users_conn() as conn:
            row = dict(conn.execute('SELECT * FROM host_launch_jobs WHERE id=?', (result.json['jobId'],)).fetchone())
        assert 'test-password-only' not in json.dumps(row)
        assert 'windowsPassword' not in row['payload']
    finally:
        release.set()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        job = e.alice.get('/EpicVM/api/account/host-gaming/launch-jobs/' + result.json['jobId']).json
        if job['state'] != 'running': break
        time.sleep(.05)
    assert job['state'] == 'ready'
    with e.core._users_conn() as conn:
        row = dict(conn.execute('SELECT * FROM host_launch_jobs WHERE id=?', (result.json['jobId'],)).fetchone())
    assert 'test-password-only' not in json.dumps(row)
