"""Domain-free local HTTPS configuration and public certificate export."""
import hashlib
import ipaddress
import json
from pathlib import Path
from urllib.parse import urlsplit
from fresh_host_setup import atomic,origin


def private_address(value):
    address=ipaddress.ip_address(value)
    if address.version!=4 or not any(address in ipaddress.ip_network(network) for network in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')):
        raise ValueError('Choose this PC\'s private home-network IPv4 address.')
    return str(address)


def configure(root, address, portal_origin, port=8443, setup_port=8444, admin_port=2020):
    root=Path(root);address=private_address(address);portal_origin=origin(portal_origin)
    parsed=urlsplit(portal_origin)
    if any(c in portal_origin for c in ('"','\n','\r','{','}')) or not parsed.hostname:
        raise ValueError('Invalid trusted portal address.')
    if any(not 1024<=p<=65535 for p in (port,setup_port,admin_port)) or len({port,setup_port,admin_port})!=3:
        raise ValueError('Choose distinct LAN ports above 1023.')
    settings=root/'local-gateway.json'
    if settings.exists():
        saved=json.loads(settings.read_text(encoding='utf-8-sig'))
        if saved.get('mode')!='local-ca':
            raise ValueError('Existing local gateway differs. It was preserved; use its repair path.')
    public=root/'lan-public';public.mkdir(exist_ok=True)
    quoted=lambda p:json.dumps(str(p).replace('\\','/'))
    local_origin=f'https://{address}:{port}'
    setup_url=f'http://{address}:{setup_port}/'
    config=f'''{{
 admin 127.0.0.1:{admin_port}
 auto_https disable_redirects
 skip_install_trust
 storage file_system {{
  root {quoted(root/'lan-certificates')}
 }}
}}
{local_origin} {{
 bind {address}
 tls internal
 @localhealth path /EpicVM/local-health
 handle @localhealth {{
  header Access-Control-Allow-Origin "{portal_origin}"
  header Access-Control-Allow-Private-Network true
  header Access-Control-Allow-Methods "GET, OPTIONS"
  header Cache-Control no-store
  respond "ok" 200
 }}
 import {quoted(root/'caddy-routes.caddy')}
 handle {{
  redir "{portal_origin}/EpicVM/portal" 302
 }}
}}
{setup_url.rstrip('/')} {{
 bind {address}
 root * {quoted(public)}
 header Cache-Control no-store
 file_server
}}
'''
    temporary=root/'Caddyfile.lan.tmp'
    temporary.write_text(config,encoding='utf-8');temporary.replace(root/'Caddyfile.lan')
    status=dict(enabled=False,mode='local-ca',origin=local_origin,address=address,setupUrl=setup_url,
                clientTrustRequired=True,stage='awaiting-certificate')
    if settings.exists():
        old=json.loads(settings.read_text(encoding='utf-8-sig'))
        status={**old,**status}
        if old.get('certificateSha256') and old.get('address')==address:
            status.update(enabled=old.get('enabled') is True,stage=old.get('stage'))
    atomic(settings,status)
    return status


def export_certificate(root):
    from cryptography import x509
    from cryptography.hazmat.primitives import serialization
    root=Path(root)
    cert=x509.load_pem_x509_certificate((root/'lan-certificates/pki/authorities/local/root.crt').read_bytes())
    if not cert.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
        raise ValueError('Local certificate is not a certificate authority.')
    der=cert.public_bytes(serialization.Encoding.DER)
    digest=hashlib.sha256(der).hexdigest()
    public=root/'lan-public';public.mkdir(exist_ok=True)
    (public/'EpicVM-LAN-root.cer').write_bytes(der)
    state=json.loads((root/'local-gateway.json').read_text())
    state.update(certificateSha256=digest,enabled=True,stage='ready-for-client-trust')
    html=f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>EpicVM local connection</title><style>body{{font:17px system-ui;max-width:720px;margin:40px auto;padding:24px;background:#10121b;color:#f0f2fa}}a{{color:#b9aaff}}code{{overflow-wrap:anywhere}}</style>
<h1>Trust this host's local certificate</h1><p>This local page provides a public certificate only. Do not enter passwords here.</p>
<p>Before installing it, compare this SHA256 fingerprint with the fingerprint shown in your signed-in EpicVM portal or the host Agent:</p><code>{digest}</code>
<ol><li><a href="EpicVM-LAN-root.cer">Download the public certificate</a>.</li><li>Windows: open the certificate, choose Install Certificate, Current User, then Trusted Root Certification Authorities. macOS: import into Keychain Access and explicitly trust it. iOS: install the certificate profile, then enable it in Certificate Trust Settings. Android: use your device's CA certificate settings; some managed devices or browsers restrict user certificates.</li><li>Only trust a host you know. Remove this certificate from your certificate store when you no longer use that host.</li></ol>
<p>Then <a href="{state['origin']}/EpicVM/local-health">check the local HTTPS connection</a> and return to your portal's local connection button.</p>
<p>No router DNS changes or EpicVM domain are required. This host's LAN address must remain reachable.</p></html>'''
    (public/'index.html').write_text(html,encoding='utf-8')
    atomic(root/'local-gateway.json',state)
    return state


if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser();p.add_argument('action',choices=('configure','export'));p.add_argument('--root',required=True);p.add_argument('--address');p.add_argument('--portal')
    a=p.parse_args()
    try:print(json.dumps(dict(ok=True,data=configure(a.root,a.address,a.portal) if a.action=='configure' else export_certificate(a.root))))
    except Exception as exc:
        print(json.dumps(dict(ok=False,error=str(exc) if isinstance(exc,ValueError) else 'Local setup failed: '+type(exc).__name__)))
        raise SystemExit(1)
