import hashlib
import json
from flask import Flask
from dashboard.host_runtime_api import register_host_runtime


def setup(tmp_path, monkeypatch):
    root = tmp_path / 'bundles'
    root.mkdir()
    streams = tmp_path / 'streams.json'
    streams.write_text(json.dumps({'vm-other': {'enabled': True, 'hostId': 'other'}}))
    enrollment = tmp_path / 'enrollments.json'
    enrollment.write_text(json.dumps({'pc': {'enabled': True, 'tokenHash': hashlib.sha256(b'private-test-token').hexdigest(),
                                           'publicOrigin': 'https://host.example', 'vmRoutes': ['vm-mine']}}))
    monkeypatch.setenv('EPICVM_HOST_RUNTIME_ENROLLMENTS', str(enrollment))
    monkeypatch.setenv('EPICVM_MOONLIGHT_ROOT', str(root))
    monkeypatch.setenv('EPICVM_DIRECT_STREAMS_FILE', str(streams))
    app = Flask(__name__)
    seat = 'seat-'+'a'*24
    register_host_runtime(app, {'_host_game_stream_record': lambda route: {'host_id': 'pc' if route == seat else 'other'}})
    return app.test_client(), root, streams, seat


def test_sync_auth_and_bundle_host_scope(tmp_path, monkeypatch):
    client, root, _, seat = setup(tmp_path, monkeypatch)
    for route in ['mine', 'other', seat]:
        directory = root / route / 'server'
        directory.mkdir(parents=True)
        (directory/'data.json').write_text(json.dumps({'hosts': {'1': {'pair_info': {'private': 'fixture'}}}, 'users': {'one': {}}}))
    assert client.get('/EpicVM/api/host-runtime/sync').status_code == 401
    response = client.get('/EpicVM/api/host-runtime/sync', headers={'Authorization': 'Bearer private-test-token'})
    assert response.status_code == 200
    assert set(response.json['sources']) == {'vm-mine', seat}


def test_manifest_cannot_change_host_origin_or_other_resources(tmp_path, monkeypatch):
    client, _, streams, seat = setup(tmp_path, monkeypatch)
    headers = {'Authorization': 'Bearer private-test-token'}
    record = {'hostId': 'pc', 'enabled': True, 'hostUrl': 'https://evil.example', 'streamPath': f'/EpicVM/{seat}/stream.html?hostId=1'}
    assert client.post('/EpicVM/api/host-runtime/manifest', json={seat:record}, headers=headers).status_code == 200
    value = json.loads(streams.read_text())
    assert value[seat]['hostUrl'] == 'https://host.example'
    assert value['vm-other']['enabled']
    for invalid in ['vm-other','vm-../../file']:
        assert client.post('/EpicVM/api/host-runtime/manifest', json={invalid:record}, headers=headers).status_code == 403
    assert client.post('/EpicVM/api/host-runtime/manifest', json={}, headers=headers).status_code == 200
    assert not json.loads(streams.read_text())[seat]['enabled']
    assert json.loads(streams.read_text())['vm-other']['enabled']
