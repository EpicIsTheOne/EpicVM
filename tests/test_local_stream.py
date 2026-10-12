import json
from flask import Flask
from dashboard.direct_stream import local_stream_origin, register_direct_stream


def test_local_origin_requires_enabled_https_origin(tmp_path, monkeypatch):
    settings = tmp_path / 'local.json'
    monkeypatch.setenv('EPICVM_LOCAL_STREAMS_FILE', str(settings))
    for value in ['http://192.168.1.2', 'https://user:pass@example.com', 'https://example.com/path', 'https://example.com?q=1', 'https://example.com#fragment']:
        settings.write_text(json.dumps({'pc': {'enabled': True, 'origin': value}}))
        assert local_stream_origin('pc') is None
    settings.write_text(json.dumps({'pc': {'enabled': True, 'origin': 'https://lan.example.com:8443'}}))
    assert local_stream_origin('pc') == 'https://lan.example.com:8443'
    settings.write_text(json.dumps({'pc': {'enabled': False, 'origin': 'https://lan.example.com'}}))
    assert local_stream_origin('pc') is None


def test_local_launch_preserves_owner_checks_and_normal_fallback(tmp_path, monkeypatch):
    route = 'seat-' + 'a' * 24
    streams = tmp_path / 'streams.json'
    local = tmp_path / 'local.json'
    key = tmp_path / 'key'
    key.write_bytes(b'a' * 32)
    streams.write_text(json.dumps({route: {'enabled': True, 'hostId': 'pc', 'hostUrl': 'https://public.example.com', 'streamPath': f'/EpicVM/{route}/stream.html?hostId=1'}}))
    local.write_text(json.dumps({'pc': {'enabled': True, 'origin': 'https://lan.example.com:8443'}}))
    monkeypatch.setenv('EPICVM_DIRECT_STREAMS_FILE', str(streams))
    monkeypatch.setenv('EPICVM_LOCAL_STREAMS_FILE', str(local))
    monkeypatch.setenv('EPICVM_DIRECT_STREAM_KEY_FILE', str(key))
    actor = {'id': 1, 'username': 'alice', 'sessionVersion': 1}
    app = Flask(__name__)
    register_direct_stream(app, {'_current_portal_user': lambda: actor, '_admin_vm_sso_authenticated': lambda: False,
                                '_host_game_stream_record': lambda _: {'host_id': 'pc', 'realm': 'portal', 'username': 'alice'}})
    client = app.test_client()
    response = client.get(f'/EpicVM/stream-launch/{route}?connection=local&origin=https://evil.example.com')
    assert response.status_code == 200
    assert b'https://lan.example.com:8443/EpicVM/auth/redeem' in response.data
    assert b'Use normal connection' in response.data
    assert b'Report a problem' in response.data
    assert b'report=bug' in response.data
    assert b'abort(),5000' in response.data
    assert b'evil.example.com' not in response.data
    assert 'connect-src https://lan.example.com:8443' in response.headers['Content-Security-Policy']
    actor['username'] = 'bob'
    assert client.get(f'/EpicVM/stream-launch/{route}?connection=local').status_code == 403
    actor['username'] = 'alice'
    local.write_text('{}')
    assert client.get(f'/EpicVM/stream-launch/{route}?connection=local').status_code == 503
    normal = client.get(f'/EpicVM/stream-launch/{route}')
    assert normal.status_code == 200 and b'https://public.example.com/EpicVM/auth/redeem' in normal.data
