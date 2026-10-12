import pytest
from test_account_workspace import workspace, login, post

@pytest.fixture
def enrollment(workspace, monkeypatch, tmp_path):
    monkeypatch.setenv('EPICVM_ENABLE_HOST_SETUP','1')
    monkeypatch.setenv('EPICVM_REMOTE_HOSTS_FILE', str(tmp_path/'remote-hosts.json'))
    monkeypatch.setattr(workspace, '_request_is_https', lambda: True)
    return workspace

def start(module, host='fresh-pc'):
    client=module.app.test_client()
    r=client.post('/EpicVM/api/host-setup/start',json=dict(hostId=host,displayName='Fresh PC',
        agentUrl='http://100.72.220.117:8765',agentToken='a'*40,syncToken='s'*40,publicOrigin='https://stream.owner.example'))
    assert r.status_code==201, r.json
    return client,r.json

def claim(client, item, proof=None):
    return client.post('/EpicVM/api/host-setup/'+item['id']+'/claim',headers={'Authorization':'Bearer '+(proof or item['deviceToken'])})

def test_enrollment_requires_admin_approval_and_device_proof(enrollment):
    client,item=start(enrollment)
    admin=login(enrollment,'manager')
    assert claim(client,item,'wrong').status_code==401
    assert claim(client,item).json['state']=='pending'
    assert post(login(enrollment),'management/host-setup/'+item['id'],action='approve').status_code==403
    pending=admin.get('/EpicVM/api/management/host-setup').json['requests'][0]
    assert pending['code']==item['code']
    assert 'agentToken' not in str(pending) and 'syncToken' not in str(pending)
    assert post(admin,'management/host-setup/'+item['id'],action='approve').status_code==200
    assert claim(client,item).json['state']=='enrolled'
    assert claim(client,item).json['state']=='enrolled'
    from remote_hosts import _read_all_remote_host_configs
    assert _read_all_remote_host_configs()[0]['enabled'] is False
    assert enrollment._setup_sync_records()['fresh-pc']['publicOrigin']=='https://stream.owner.example'
    assert post(admin,'management/host-setup/'+item['id']+'/activation',action='revoke').status_code==200
    assert enrollment._setup_sync_records()=={}
    assert claim(client,item).json['state']=='revoked'

def test_expired_denied_and_private_address_rules(enrollment,monkeypatch):
    client,item=start(enrollment)
    assert post(login(enrollment,'manager'),'management/host-setup/'+item['id'],action='deny').status_code==200
    assert claim(client,item).json['state']=='denied'
    client,item=start(enrollment,'second-pc')
    with enrollment._users_conn() as db: db.execute('UPDATE host_setup_requests SET expires_at=0 WHERE id=?',(item['id'],))
    assert claim(client,item).status_code==410
    r=client.post('/EpicVM/api/host-setup/start',json=dict(hostId='evil',displayName='Bad',agentUrl='http://169.254.169.254',agentToken='a'*40,syncToken='s'*40,publicOrigin='https://stream.example'))
    assert r.status_code==400
    monkeypatch.setattr(enrollment,'_request_is_https',lambda:False)
    assert client.post('/EpicVM/api/host-setup/start',json={}).status_code==400


def test_activation_requires_stream_confirmation_and_ready_agent(enrollment,monkeypatch):
    client,item=start(enrollment)
    admin=login(enrollment,'manager')
    assert post(admin,'management/host-setup/'+item['id'],action='approve').status_code==200
    assert claim(client,item).status_code==200
    path='management/host-setup/'+item['id']+'/activation'
    assert post(admin,path,action='activate').status_code==400
    from remote_agent_client import RemoteAgentClient
    monkeypatch.setattr(RemoteAgentClient,'_request',lambda *a,**kw:{'ready':False})
    assert post(admin,path,action='activate',streamVerified=True).status_code==409
    monkeypatch.setattr(RemoteAgentClient,'_request',lambda *a,**kw:{'ready':True})
    assert post(admin,path,action='activate',streamVerified=True).status_code==200
    assert claim(client,item).json['activated'] is True
    from remote_hosts import _read_all_remote_host_configs,upsert_remote_host_config
    disabled=_read_all_remote_host_configs()[0];disabled['enabled']=False;upsert_remote_host_config(disabled)
    assert enrollment._setup_sync_records()=={}
    disabled['enabled']=True;upsert_remote_host_config(disabled)
    from remote_hosts import _read_all_remote_host_configs
    assert _read_all_remote_host_configs()[0]['enabled'] is True
    assert post(admin,path,action='revoke').status_code==200
    assert _read_all_remote_host_configs()[0]['enabled'] is False


def test_setup_is_opt_in_and_uses_no_global_loopback_override(enrollment,monkeypatch):
    from remote_hosts import _validate_agent_url,RemoteHostConfigError
    monkeypatch.delenv('EPICVM_ALLOW_NON_TAILSCALE_HOSTS',raising=False)
    monkeypatch.delenv('EPICVM_ALLOW_LOOPBACK_HOST',raising=False)
    with pytest.raises(RemoteHostConfigError): _validate_agent_url('http://127.0.0.1:8765')
    monkeypatch.setenv('EPICVM_ALLOW_LOOPBACK_HOST','1')
    assert _validate_agent_url('http://127.0.0.1:8765')=='http://127.0.0.1:8765'
    with pytest.raises(RemoteHostConfigError): _validate_agent_url('http://169.254.169.254')
    monkeypatch.delenv('EPICVM_ENABLE_HOST_SETUP',raising=False)
    assert enrollment.app.test_client().post('/EpicVM/api/host-setup/start',json={}).status_code==404


def test_each_host_has_separate_signing_authority_and_revocation(enrollment):
    from dashboard.direct_stream_auth import issue_grant,verify_grant
    admin=login(enrollment,'manager')
    keys=[]
    for host in ('first-pc','second-pc'):
        client,item=start(enrollment,host)
        assert 'streamKey' not in str(admin.get('/EpicVM/api/management/host-setup').json)
        assert post(admin,'management/host-setup/'+item['id'],action='approve').status_code==200
        claimed=claim(client,item)
        key=bytes.fromhex(claimed.json['streamKey'])
        assert claim(client,item).json['streamKey']==claimed.json['streamKey']
        assert enrollment._setup_stream_key(host)==key
        assert not enrollment._setup_host_active(host)
        keys.append(key)
    assert keys[0]!=keys[1]
    grant=issue_grant(keys[0],route='seat-'+'a'*24,user='portal:manager',path='/EpicVM/seat-'+'a'*24+'/stream.html')
    with pytest.raises(ValueError):verify_grant(keys[1],grant)
    assert post(admin,'management/host-setup/'+item['id']+'/activation',action='revoke').status_code==200
    with pytest.raises(ValueError):enrollment._setup_stream_key('second-pc')


def test_fresh_activation_requires_recorded_owned_desktop(enrollment,monkeypatch,tmp_path):
    import json
    monkeypatch.setenv('EPICVM_REQUIRE_SETUP_CHECK','1')
    manifest=tmp_path/'streams.json';monkeypatch.setenv('EPICVM_DIRECT_STREAMS_FILE',str(manifest))
    client,item=start(enrollment)
    admin=login(enrollment,'manager')
    assert post(admin,'management/host-setup/'+item['id'],action='approve').status_code==200
    assert claim(client,item).status_code==200
    from remote_agent_client import RemoteAgentClient
    monkeypatch.setattr(RemoteAgentClient,'_request',lambda *a,**kw:{'ready':True})
    path='management/host-setup/'+item['id']
    assert post(admin,path+'/activation',action='activate',streamVerified=True).status_code==409
    route='seat-'+'a'*24
    monkeypatch.setattr(enrollment,'_host_game_stream_record',lambda _:dict(host_id='fresh-pc',realm='portal',username='manager'))
    assert post(admin,path+'/connection-check',route=route,videoVisible=True,inputWorked=True).status_code==409
    manifest.write_text(json.dumps({route:dict(hostId='fresh-pc',enabled=True)}))
    assert post(admin,path+'/connection-check',route=route,videoVisible=True,inputWorked=False).status_code==400
    assert post(admin,path+'/connection-check',route=route,videoVisible=True,inputWorked=True).status_code==200
    assert post(admin,path+'/activation',action='activate',streamVerified=True).status_code==200
    assert enrollment._setup_host_active('fresh-pc')
