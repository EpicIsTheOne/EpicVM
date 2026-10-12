import json
from scripts.host_stream_gateway import Gateway


def test_connection_policy_classifies_trusted_proxy_host(tmp_path):
    key = tmp_path / 'key'
    key.write_bytes(b'a'*32)
    routes = tmp_path / 'routes.json'
    routes.write_text('{}')
    (tmp_path/'local-gateway.json').write_text(json.dumps({'origin':'https://lan.example:8443'}))
    gateway = Gateway(('127.0.0.1',0),key_path=key,routes_path=routes,nonces_path=tmp_path/'nonces')
    try:
        policy = tmp_path/'hosting-policy.json'
        policy.write_text(json.dumps({'localEnabled':False,'normalEnabled':True}))
        assert not gateway.connection_allowed('lan.example:8443')
        assert gateway.connection_allowed('public.example')
        policy.write_text(json.dumps({'localEnabled':True,'normalEnabled':False}))
        assert gateway.connection_allowed('LAN.EXAMPLE:8443')
        assert not gateway.connection_allowed('public.example')
        assert not gateway.connection_allowed('')
    finally:
        gateway.server_close()
