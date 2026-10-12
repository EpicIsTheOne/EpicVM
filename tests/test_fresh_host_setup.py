import json
import sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from fresh_host_setup import prepare
from portal_service import environment

def configuration(root,layout='same-pc'):
    return prepare(root,layout,'https://portal.owner.example','https://stream.owner.example','my-pc','My PC','http://127.0.0.1:8765' if layout=='same-pc' else 'http://100.72.220.117:8765')

def test_configuration_is_independent_and_resumable(tmp_path):
    first=configuration(tmp_path/'one');second=configuration(tmp_path/'two')
    a=json.loads((tmp_path/'one/setup-private.json').read_text());b=json.loads((tmp_path/'two/setup-private.json').read_text())
    assert a['portalSecret']!=b['portalSecret'] and a['agentToken']!=b['agentToken']
    assert configuration(tmp_path/'one')==first
    assert 'agentToken' not in json.dumps(first)
    with pytest.raises(ValueError):prepare(tmp_path/'one','same-pc','https://other.example','https://stream.owner.example','my-pc','My PC','http://127.0.0.1:8765')
    root=tmp_path/'one';(root/'portal-admin.json').write_text(json.dumps(dict(username='admin',passwordHash='hashed')))
    env=environment(root,tmp_path/'package')
    assert env['EPICVM_HOSTING_PROFILE']=='multiseat' and env['EPICVM_ALLOW_LOOPBACK_HOST']=='1'
    assert env['BLOBEDASH_STATE']==str(root/'portal')
    assert 'techexplore.us' not in str(env)

@pytest.mark.parametrize('url',['http://portal.example','https://portal.example/a','https://evil@portal.example','https://portal.example?redirect=evil'])
def test_invalid_portal_authority_rejected(tmp_path,url):
    with pytest.raises(ValueError):prepare(tmp_path,'same-pc',url,'https://stream.example','pc','PC','http://127.0.0.1:8765')

def test_multiseat_profile_has_no_local_docker_provider(monkeypatch,tmp_path):
    monkeypatch.setenv('EPICVM_HOSTING_PROFILE','multiseat')
    from remote_hosts import ConfiguredVmHostRegistry
    registry=ConfiguredVmHostRegistry(path=tmp_path/'registry.json')
    assert registry.providers=={} and registry.public_records()==[]


def test_navigation_remains_on_configured_portal(tmp_path):
    from provision_direct_stream import patch_stream_navigation
    p=tmp_path/'stream.js';p.write_text('// EpicVM workspace navigation\nwindow.location.assign("https://techexplore.us/EpicVM/portal");')
    assert patch_stream_navigation(tmp_path,'https://portal.owner.example')
    assert 'techexplore.us' not in p.read_text()
    assert not patch_stream_navigation(tmp_path,'https://portal.owner.example')


def test_recovery_and_network_links_keep_instance_authority(tmp_path):
    from provision_direct_stream import patch_stream_recovery
    (tmp_path/'stream.js').write_text('// EpicVM automatic connection recovery v1\nwindow["app"] = app;\n        installStreamRecovery(app);')
    assert patch_stream_recovery(tmp_path,'https://portal.owner.example')
    for name in ('epicvm_recovery.js','epicvm_network.js'):
        source=(tmp_path/name).read_text()
        assert 'techexplore.us' not in source
        assert 'https://portal.owner.example/EpicVM/' in source
    assert not patch_stream_recovery(tmp_path,'https://portal.owner.example')


def test_prepare_recovers_after_private_state_is_saved(tmp_path):
    root=tmp_path/'resume';configuration(root)
    private=(root/'setup-private.json').read_bytes()
    (root/'setup-state.json').unlink()
    assert configuration(root)['stage']=='prepared'
    assert (root/'setup-private.json').read_bytes()==private


def test_first_administrator_hashes_support_both_login_realms(tmp_path):
    from fresh_host_setup import initialize_admin
    from werkzeug.security import check_password_hash
    import base64,hashlib
    configuration(tmp_path/'admin');root=tmp_path/'admin'
    initialize_admin(root,'first_admin','correct-password-only')
    saved=json.loads((root/'portal-admin.json').read_text())
    assert check_password_hash(saved['passwordHash'],'correct-password-only')
    alg,salt,digest=saved['portalPasswordHash'].split('$')
    assert alg=='pbkdf2_sha256'
    assert base64.b64encode(hashlib.pbkdf2_hmac('sha256',b'correct-password-only',salt.encode(),260000)).decode()==digest
    initialize_admin(root,'other_admin','other-password')
    assert json.loads((root/'portal-admin.json').read_text())==saved
