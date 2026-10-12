import base64
import pytest
from flask import jsonify, request
from test_resource_identity import load_app


@pytest.fixture
def workspace(monkeypatch, tmp_path):
    monkeypatch.setenv('BLOBEDASH_USER', 'rootadmin')
    monkeypatch.setenv('BLOBEDASH_PASS', 'admin-original')
    monkeypatch.delenv('BLOBEDASH_PASS_HASH', raising=False)
    module = load_app(monkeypatch, tmp_path)
    monkeypatch.setattr(module, '_allow_insecure_dashboard', lambda: False)
    resources = [{'resourceKey': 'vm:epic-pc:one', 'resourceType': 'vm', 'hostId': 'epic-pc',
                  'nativeId': 'one', 'name': 'gaming', 'classification': 'managed', 'available': True}]
    monkeypatch.setattr(module, '_resource_inventory', lambda **kw: (resources, []))
    for name, admin in [('alice', False), ('bob', False), ('manager', True), ('rootadmin', False)]:
        module._create_user(name, 'portal-original', is_admin=admin)
    return module


def login(module, name='alice', dashboard=False):
    client = module.app.test_client()
    if dashboard:
        client.set_cookie('Dashboard-Auth', module._sign_v2_token(module._account_dashboard_payload(name)))
    else:
        client.set_cookie('Portal-Auth', module._create_portal_token(name))
    session = client.get('/EpicVM/api/account/session')
    assert session.status_code == 200, session.data
    client.csrf = session.json['csrfToken']
    return client


def post(client, path, **data):
    return client.post('/EpicVM/api/' + path, json=data,
                       headers={'Origin': 'http://localhost', 'X-CSRF-Token': client.csrf})


def ticket(client, key='first', kind='vm'):
    result = post(client, 'account/tickets', kind=kind, title='A test request', body='Useful test details', requestKey=key)
    assert result.status_code in (200, 201), result.data
    return result.json['id']


def test_auth_csrf_and_role_guards(workspace):
    anon = workspace.app.test_client()
    assert anon.get('/EpicVM/api/account/session').status_code == 401
    assert anon.get('/EpicVM/api/management/overview').status_code == 401
    client = login(workspace)
    assert client.get('/EpicVM/api/management/overview').status_code == 403
    assert client.post('/EpicVM/api/account/tickets', json={}).status_code == 403
    assert client.post('/EpicVM/api/account/tickets', json={}, headers={
        'Origin': 'https://evil.example', 'X-CSRF-Token': client.csrf}).status_code == 403
    assert post(client, 'management/users/bob', action='approve').status_code == 403
    assert anon.get('/settings').location == '/EpicVM/settings'


def test_private_tickets_and_idempotency(workspace):
    alice, bob = login(workspace), login(workspace, 'bob')
    first = ticket(alice)
    assert ticket(alice) == first
    assert len(alice.get('/EpicVM/api/account/tickets').json['tickets']) == 1
    assert bob.get('/EpicVM/api/account/tickets').json['tickets'] == []
    assert post(bob, 'management/tickets/' + first, status='resolved', response='Fake reply').status_code == 403
    assert post(alice, 'account/tickets', kind='invalid', title='x', body='hello', requestKey='x').status_code == 400


def test_portal_password_revokes_old_session(workspace):
    client, old = login(workspace), login(workspace)
    assert post(client, 'account/password', currentPassword='portal-original', newPassword='new-password-123').status_code == 200
    assert old.get('/EpicVM/api/account/session').status_code == 401
    assert client.get('/EpicVM/api/account/session').status_code == 200
    user = workspace._get_user_by_username('alice')
    assert workspace._verify_user_password('new-password-123', user['password_hash'])
    assert not workspace._verify_user_password('portal-original', user['password_hash'])


def test_wrong_current_password_does_not_change_password(workspace):
    client = login(workspace)
    assert post(client, 'account/password', currentPassword='wrong', newPassword='new-password-123').status_code == 400
    assert workspace._verify_user_password('portal-original', workspace._get_user_by_username('alice')['password_hash'])


def test_dashboard_password_separate_realm_and_revocation(workspace, monkeypatch):
    monkeypatch.setenv('DASHBOARD_USER', 'rootadmin')
    monkeypatch.setenv('DASHBOARD_PASSWORD', 'admin-original')
    # Use the actual configured names regardless of deployment environment aliases.
    name = workspace._admin_credentials()[0]
    assert name == 'rootadmin'
    client, old = login(workspace, name, True), login(workspace, name, True)
    assert post(client, 'account/password', currentPassword='admin-original', newPassword='admin-new-123').status_code == 200
    assert old.get('/EpicVM/api/account/session').status_code == 401
    assert client.get('/EpicVM/api/account/session').status_code == 200
    assert workspace._valid_dashboard_admin(name, 'admin-new-123')
    assert not workspace._valid_dashboard_admin(name, 'admin-original')
    assert workspace._verify_user_password('portal-original', workspace._get_user_by_username(name)['password_hash'])


def test_legacy_dashboard_requires_identified_login(workspace):
    import time
    client = workspace.app.test_client()
    client.set_cookie('Dashboard-Auth', workspace._sign_v2_token(f'{int(time.time()) + 100}:legacy'))
    assert client.get('/EpicVM/api/account/session').json['user']['reauthenticate'] is True
    assert client.get('/EpicVM/api/management/overview').status_code == 401


def test_pending_self_service_but_not_management(workspace):
    workspace._update_user('manager', account_status='pending')
    client = login(workspace, 'manager')
    assert client.get('/EpicVM/api/account/session').json['user']['isAdmin'] is False
    assert client.get('/EpicVM/api/management/overview').status_code == 403
    ticket(client)


def test_admin_approval_fulfillment_and_reset(workspace):
    workspace._update_user('alice', account_status='pending')
    alice, admin = login(workspace), login(workspace, 'manager')
    request_id = ticket(alice)
    path = 'management/tickets/' + request_id
    assert post(admin, path, status='fulfilled', response='Assigned', resourceKey='vm:epic-pc:one').status_code == 400
    assert post(admin, 'management/users/alice', action='approve').status_code == 200
    assert post(admin, path, status='fulfilled', response='Assigned', resourceKey='vm:epic-pc:one').status_code == 200
    assert post(admin, path, status='fulfilled', response='Again', resourceKey='vm:epic-pc:one').status_code == 409
    with workspace._users_conn() as conn:
        assert conn.execute('SELECT resource_key FROM user_resource_access').fetchone()[0] == 'vm:epic-pc:one'
    alice = login(workspace)
    assert post(admin, 'management/users/alice', action='password', newPassword='reset-new-password').status_code == 200
    assert alice.get('/EpicVM/api/account/session').status_code == 401
    assert post(admin, 'management/users/manager', action='disable').status_code == 400


def test_reports_reply_and_overview(workspace):
    client, admin = login(workspace), login(workspace, 'manager')
    request_id = ticket(client, kind='bug')
    assert post(admin, 'management/tickets/' + request_id, status='resolved', response='Fixed and verified').status_code == 200
    assert client.get('/EpicVM/api/account/tickets').json['tickets'][0]['response'] == 'Fixed and verified'
    result = admin.get('/EpicVM/api/management/overview')
    assert result.status_code == 200, result.data
    assert len(result.json['users']) == 4
    assert len(result.json['tickets']) == 1


def test_connection_report_preview_fields_are_private_and_owner_scoped(workspace):
    alice, bob, admin = login(workspace), login(workspace, 'bob'), login(workspace, 'manager')
    context = {'host': 'epic-pc', 'connection': 'local', 'source': 'launch', 'stage': 'pairing',
               'time': '2026-10-12T03:00:00.000Z', 'password': 'NEVER-STORE',
               'grant': 'NEVER-STORE', 'url': 'https://private/?token=NEVER-STORE'}
    result = post(alice, 'account/tickets', kind='bug', title='Connection failed', body='The desktop did not open.',
                  requestKey='context-test', context=context)
    assert result.status_code == 201
    report = alice.get('/EpicVM/api/account/tickets').json['tickets'][0]
    assert report['context'] == {key: context[key] for key in ('host', 'connection', 'source', 'stage', 'time')}
    assert bob.get('/EpicVM/api/account/tickets').json['tickets'] == []
    assert admin.get('/EpicVM/api/management/overview').json['tickets'][0]['context'] == report['context']
    with workspace._users_conn() as conn:
        assert 'NEVER-STORE' not in conn.execute('SELECT context FROM account_tickets').fetchone()[0]
    assert post(alice, 'account/tickets', kind='bug', title='No preview', body='Details omitted.',
                requestKey='no-context', context=None).status_code == 201
    assert alice.get('/EpicVM/api/account/tickets').json['tickets'][0]['context'] in ({}, report['context'])


def test_desktop_access_request_is_reviewed_without_creating_a_vm(workspace, monkeypatch):
    alice, admin = login(workspace), login(workspace, 'manager')
    monkeypatch.setattr(workspace, '_resource_inventory', lambda **kw: (_ for _ in ()).throw(AssertionError('VM creation or assignment')))
    result = post(alice, 'account/tickets', kind='desktop', title='Desktop access', body='I would like to use the host desktop.', requestKey='desktop-request')
    assert result.status_code == 201
    path = 'management/tickets/' + result.json['id']
    assert post(admin, path, status='fulfilled', response='Wrong VM workflow').status_code == 400
    assert post(admin, path, status='in_review', response='Checking access').status_code == 200
    assert post(admin, path, status='resolved', response='Your desktop access is ready').status_code == 400
    with workspace._users_conn() as conn:
        conn.execute('INSERT INTO host_desktop_grants VALUES (?,?,?)', ('portal', 'alice', 'epic-pc'))
    assert post(admin, path, status='resolved', response='Your desktop access is ready').status_code == 200
    assert alice.get('/EpicVM/api/account/tickets').json['tickets'][0]['kind'] == 'desktop'


def test_desktop_ready_requires_the_requesters_enabled_approved_account(workspace):
    alice, admin = login(workspace), login(workspace, 'manager')
    result = post(alice, 'account/tickets', kind='desktop', title='Access', body='Please assign a desktop', requestKey='ready-check')
    path = 'management/tickets/' + result.json['id']
    with workspace._users_conn() as conn:
        conn.execute('INSERT INTO host_desktop_grants VALUES (?,?,?)', ('portal', 'bob', 'epic-pc'))
    assert post(admin, path, status='resolved', response='Ready').status_code == 400
    with workspace._users_conn() as conn:
        conn.execute('INSERT INTO host_desktop_grants VALUES (?,?,?)', ('portal', 'alice', 'epic-pc'))
    workspace._update_user('alice', disabled=True)
    assert post(admin, path, status='resolved', response='Ready').status_code == 400
    workspace._update_user('alice', disabled=False, account_status='pending')
    assert post(admin, path, status='resolved', response='Ready').status_code == 400
    workspace._update_user('alice', account_status='approved')
    assert post(admin, path, status='resolved', response='Ready').status_code == 200
    report = login(workspace).get('/EpicVM/api/account/tickets').json['tickets'][0]
    assert report['desktopAssigned'] is True
    with workspace._users_conn() as conn:
        conn.execute("DELETE FROM host_desktop_grants WHERE username='alice'")
    assert login(workspace).get('/EpicVM/api/account/tickets').json['tickets'][0]['desktopAssigned'] is False


def test_only_one_open_desktop_request_per_owner(workspace):
    alice, bob = login(workspace), login(workspace, 'bob')
    first = post(alice, 'account/tickets', kind='desktop', title='Access', body='Please assign a desktop', requestKey='one')
    repeated = post(alice, 'account/tickets', kind='desktop', title='Again', body='Please assign a desktop', requestKey='two')
    assert repeated.json['id'] == first.json['id']
    assert len(alice.get('/EpicVM/api/account/tickets').json['tickets']) == 1
    assert post(bob, 'account/tickets', kind='desktop', title='My access', body='Please assign a desktop', requestKey='one').json['id'] != first.json['id']


def test_report_context_rejects_oversize_and_discards_invalid_fields(workspace):
    alice = login(workspace)
    for context in ['invalid', {'host': 'x' * 3000}]:
        assert post(alice, 'account/tickets', kind='bug', title='Bug', body='Detailed report', requestKey='bad', context=context).status_code == 400
    assert post(alice, 'account/tickets', kind='bug', title='Bug', body='Detailed report', requestKey='invalid-fields',
                context={'host': 'https://private/token', 'connection': 'secret', 'stage': '<script>', 'time': '2026-99-99T00:00:00Z'}).status_code == 201
    assert alice.get('/EpicVM/api/account/tickets').json['tickets'][0]['context'] == {}


def test_management_provisioning_is_admin_only_and_forces_automatic(workspace, monkeypatch):
    member, admin = login(workspace), login(workspace, 'manager')
    assert member.get('/EpicVM/api/management/provisioning').status_code == 403
    assert post(member, 'management/provisioning', host_id='epic-pc', name='new-vm', profile='gaming').status_code == 403

    calls = []
    def create_impl():
        calls.append(request.get_json())
        return jsonify(ok=True, host_id='epic-pc', job={'id': 'job-1', 'name': 'new-vm', 'state': 'queued'}), 202
    create_impl.__wrapped__ = create_impl
    monkeypatch.setattr(workspace, 'api_provisioning_job_create', create_impl)

    result = post(admin, 'management/provisioning', host_id='epic-pc', name='New-VM', profile='gaming', mode='claim')
    assert result.status_code == 202, result.data
    assert calls == [{'host_id': 'epic-pc', 'name': 'new-vm', 'profile': 'gaming', 'mode': 'automatic'}]


def test_management_provisioning_status_uses_guarded_existing_contract(workspace, monkeypatch):
    admin = login(workspace, 'manager')
    def status_impl(job_id):
        return jsonify(ok=True, host_id=request.args['host_id'], job={'id': job_id, 'state': 'ready'})
    status_impl.__wrapped__ = status_impl
    monkeypatch.setattr(workspace, 'api_provisioning_job_status', status_impl)
    result = admin.get('/EpicVM/api/management/provisioning/job-1?host_id=epic-pc')
    assert result.status_code == 200
    assert result.json['job'] == {'id': 'job-1', 'state': 'ready'}


def test_management_normal_vm_creation_is_admin_only_and_forces_local(workspace, monkeypatch):
    member, admin = login(workspace), login(workspace, 'manager')
    assert post(member, 'management/vms', name='normal-one', host_id='epic-pc').status_code == 403
    calls = []
    def create_impl():
        calls.append(request.get_json())
        return jsonify(ok=True, host_id='local', placement='local')
    create_impl.__wrapped__ = create_impl
    monkeypatch.setattr(workspace, 'api_create', create_impl)
    result = post(admin, 'management/vms', name='Normal-One', host_id='epic-pc', placement='remote')
    assert result.status_code == 200
    assert calls == [{'name': 'normal-one', 'host_id': 'local', 'placement': 'local'}]


def test_management_machine_actions_are_bounded_and_reuse_existing_handlers(workspace, monkeypatch):
    admin = login(workspace, 'manager')
    calls = []
    def action_impl(name):
        calls.append((name, request.get_json()))
        return jsonify(ok=True)
    action_impl.__wrapped__ = action_impl
    monkeypatch.setattr(workspace, 'api_start', action_impl)
    monkeypatch.setattr(workspace, 'api_stop', action_impl)
    monkeypatch.setattr(workspace, 'api_restart', action_impl)
    assert post(admin, 'management/machines/gaming', action='start', host_id='epic-pc').status_code == 200
    assert post(admin, 'management/machines/gaming', action='delete', host_id='epic-pc').status_code == 400
    assert post(admin, 'management/machines/missing', action='stop', host_id='epic-pc').status_code == 404
    assert calls == [('gaming', {'host_id': 'epic-pc'})]


def test_management_retry_uses_protected_defaults_without_returning_them(workspace, monkeypatch):
    admin = login(workspace, 'manager')
    seen = []
    monkeypatch.setattr(workspace, '_default_guest_credentials', lambda: ('protected-user', 'protected-password'))
    def retry_impl(job_id):
        seen.append((job_id, request.get_json()))
        return jsonify(ok=True, host_id='epic-pc', job={'id': job_id, 'state': 'streaming_setup'})
    retry_impl.__wrapped__ = retry_impl
    monkeypatch.setattr(workspace, 'api_provisioning_job_retry_console', retry_impl)
    result = post(admin, 'management/provisioning/job-1/retry-console', host_id='epic-pc')
    assert result.status_code == 200
    assert seen == [('job-1', {'host_id': 'epic-pc', 'username': 'protected-user', 'password': 'protected-password'})]
    assert 'protected' not in result.get_data(as_text=True)


def test_notification_read_state_is_private_and_shared_between_sessions(workspace):
    alice, second, bob, manager = login(workspace), login(workspace), login(workspace, 'bob'), login(workspace, 'manager')
    assert workspace.app.test_client().get('/EpicVM/api/account/notifications').status_code == 401
    tid = ticket(alice, kind='bug')
    incoming = manager.get('/EpicVM/api/account/notifications').json
    admin_item = next(i for i in incoming['notifications'] if i['target'].endswith(tid))
    assert admin_item['category'] == 'reports' and not admin_item['read']
    assert post(alice, 'account/notifications/read', ids=[admin_item['id']]).status_code == 404
    assert post(manager, 'management/tickets/' + tid, status='in_review', response='Looking into this.').status_code == 200
    item = next(i for i in alice.get('/EpicVM/api/account/notifications').json['notifications'] if i['category'] == 'reply')
    assert not item['read']
    assert bob.get('/EpicVM/api/account/notifications').json['notifications'] != alice.get('/EpicVM/api/account/notifications').json['notifications']
    assert post(bob, 'account/notifications/read', ids=[item['id']]).status_code == 404
    assert alice.post('/EpicVM/api/account/notifications/read', json={'ids': [item['id']]}).status_code == 403
    assert post(alice, 'account/notifications/read', ids=[item['id']]).status_code == 200
    assert next(i for i in second.get('/EpicVM/api/account/notifications').json['notifications'] if i['id'] == item['id'])['read']
    assert post(manager, 'management/tickets/' + tid, status='resolved', response='Fixed now.').status_code == 200
    updated = next(i for i in second.get('/EpicVM/api/account/notifications').json['notifications'] if i['category'] == 'reply')
    assert updated['id'] != item['id'] and not updated['read']
    assert post(alice, 'account/notifications/read', ids=[item['id']]).status_code == 404


def test_notifications_show_approval_assignments_and_pending_accounts(workspace):
    alice, manager = login(workspace), login(workspace, 'manager')
    workspace._update_user('bob', account_status='pending')
    assert any(i['category'] == 'accounts' and 'bob' in i['title'] for i in manager.get('/EpicVM/api/account/notifications').json['notifications'])
    with workspace._users_conn() as conn:
        conn.execute("INSERT INTO host_desktop_grants VALUES ('portal','alice','epic-pc')")
    items = alice.get('/EpicVM/api/account/notifications').json['notifications']
    assert any(i['title'] == 'Your EpicVM account is approved' for i in items)
    assert any(i['category'] == 'assignment' for i in items)
    ids = [i['id'] for i in items]
    assert post(alice, 'account/notifications/read', ids=ids).status_code == 200
    assert alice.get('/EpicVM/api/account/notifications').json['unreadCount'] == 0
    assert post(alice, 'account/notifications/read', ids=ids).status_code == 200
    assert post(alice, 'account/notifications/read', ids=[]).status_code == 400
    assert post(alice, 'account/notifications/read', ids=['x'] * 101).status_code == 400
