import hashlib
import json
import sys
from pathlib import Path
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from datetime import datetime, timedelta, timezone

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from local_lan import configure, export_certificate, private_address
from fresh_host_setup import storage_path
from dashboard.direct_stream import local_stream_info
from test_host_runtime_sync import setup


@pytest.mark.parametrize('value',['127.0.0.1','169.254.1.2','100.64.1.2','8.8.8.8','::1','192.168.1.1\n{'])
def test_reject_non_lan(value):
    with pytest.raises(ValueError): private_address(value)


@pytest.mark.parametrize('value',['C:\\','C:\\Users\\Epic\\data','C:\\Windows\\data','D:\\data\\..\\other','D:\\CON','D:\\data.','D:\\a\\.\\b','\\\\server\\share','D:\\data:stream'])
def test_reject_unsafe_storage(value):
    with pytest.raises(ValueError): storage_path(value)


def test_storage_selection():
    assert storage_path('D:\\EpicVM')=='D:\\EpicVM'


def test_local_ca_export_and_repair_preserves_private_ca(tmp_path):
    configure(tmp_path,'192.168.1.7','https://portal.example')
    certroot=tmp_path/'lan-certificates/pki/authorities/local';certroot.mkdir(parents=True)
    key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    subject=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'Fixture local CA')])
    now=datetime.now(timezone.utc)
    cert=x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key()).serial_number(1).not_valid_before(now).not_valid_after(now+timedelta(days=1)).add_extension(x509.BasicConstraints(ca=True,path_length=None),True).sign(key,hashes.SHA256())
    (certroot/'root.crt').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (certroot/'root.key').write_bytes(b'private-key-fixture')
    state=export_certificate(tmp_path)
    public=tmp_path/'lan-public'
    assert set(p.name for p in public.iterdir())=={'index.html','EpicVM-LAN-root.cer'}
    assert hashlib.sha256((public/'EpicVM-LAN-root.cer').read_bytes()).hexdigest()==state['certificateSha256']
    assert state['certificateSha256'] in (public/'index.html').read_text()
    assert configure(tmp_path,'192.168.1.7','https://portal.example')['enabled']
    assert not configure(tmp_path,'192.168.1.8','https://portal.example')['enabled']
    assert (certroot/'root.key').read_bytes()==b'private-key-fixture'
    existing=json.loads((tmp_path/'local-gateway.json').read_text());existing['mode']='domain'
    (tmp_path/'local-gateway.json').write_text(json.dumps(existing))
    with pytest.raises(ValueError): configure(tmp_path,'192.168.1.7','https://portal.example')


def test_authenticated_host_scoped_lan_publication(tmp_path,monkeypatch):
    client,_,_,_=setup(tmp_path,monkeypatch)
    target=tmp_path/'local.json'
    target.write_text(json.dumps({'other':{'enabled':True,'origin':'https://other.example'}}))
    monkeypatch.setenv('EPICVM_LOCAL_STREAMS_FILE',str(target))
    clean=dict(enabled=True,mode='local-ca',origin='https://192.168.1.7:8443',setupUrl='http://192.168.1.7:8444/',certificateSha256='a'*64,clientTrustRequired=True)
    url='/EpicVM/api/host-runtime/local-gateway';headers={'Authorization':'Bearer private-test-token'}
    assert client.post(url,json=clean).status_code==401
    for field,value in [('origin','https://evil.example:8443'),('setupUrl','http://192.168.1.7:8444/?evil'),('certificateSha256','invalid'),('clientTrustRequired',False)]:
        assert client.post(url,json={**clean,field:value},headers=headers).status_code==400
    assert client.post(url,json={**clean,'hostId':'other','privateKey':'must-never-be-stored'},headers=headers).status_code==200
    stored=json.loads(target.read_text())
    assert stored['other']['origin']=='https://other.example'
    assert stored['pc']==clean and local_stream_info('pc')==clean
    assert client.post(url,json={**clean,'enabled':False},headers=headers).status_code==200
    assert local_stream_info('pc') is None
    enroll=tmp_path/'enrollments.json';records=json.loads(enroll.read_text());records['pc']['enabled']=False;enroll.write_text(json.dumps(records))
    assert client.post(url,json=clean,headers=headers).status_code==401


def test_domain_backed_lan_retained(tmp_path,monkeypatch):
    client,_,_,_=setup(tmp_path,monkeypatch)
    target=tmp_path/'local.json';target.write_text(json.dumps({'pc':{'enabled':True,'origin':'https://lan.example:8443'}}))
    monkeypatch.setenv('EPICVM_LOCAL_STREAMS_FILE',str(target))
    value=dict(enabled=True,mode='local-ca',origin='https://192.168.1.7:8443',setupUrl='http://192.168.1.7:8444/',certificateSha256='a'*64,clientTrustRequired=True)
    assert client.post('/EpicVM/api/host-runtime/local-gateway',json=value,headers={'Authorization':'Bearer private-test-token'}).status_code==409
    assert local_stream_info('pc')['origin']=='https://lan.example:8443'


def test_local_ca_recovery_needs_no_dns_token(tmp_path,monkeypatch):
    import supervise_host_direct_streams as supervisor
    configure(tmp_path,'192.168.1.7','https://portal.example')
    state=json.loads((tmp_path/'local-gateway.json').read_text());state['enabled']=True
    (tmp_path/'local-gateway.json').write_text(json.dumps(state))
    (tmp_path/'caddy-routes.caddy').write_text('fixture routes')
    calls=[]
    monkeypatch.setattr(supervisor.subprocess,'run',lambda args,**kwargs:calls.append((args,kwargs)))
    supervisor._ensure_local_gateway(tmp_path)
    assert len(calls)==2 and 'reload' in calls[1][0]
    assert not (tmp_path/'lan-dns.token').exists()


def test_changed_address_revokes_advertised_local_option(tmp_path,monkeypatch):
    import supervise_host_direct_streams as supervisor
    configure(tmp_path,'192.168.1.7','https://portal.example')
    state=json.loads((tmp_path/'local-gateway.json').read_text());state.update(enabled=True,certificateSha256='a'*64)
    (tmp_path/'local-gateway.json').write_text(json.dumps(state))
    monkeypatch.setattr(supervisor,'RUNTIME_CONFIG',{'portalOrigin':'https://portal.example'})
    monkeypatch.setattr(supervisor.psutil,'net_if_addrs',lambda:{})
    published=[]
    monkeypatch.setattr(supervisor,'_host_request',lambda path,payload:published.append((path,payload)))
    supervisor._publish_local_gateway(tmp_path)
    assert published[0][0]=='local-gateway' and published[0][1]['enabled'] is False
    assert 'Normal hosting is independent' in json.loads((tmp_path/'lan-status.json').read_text())['message']
