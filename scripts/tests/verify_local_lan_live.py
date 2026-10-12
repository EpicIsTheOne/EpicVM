"""Isolated real-Caddy check. Does not install services or trust any certificate."""
import hashlib
import json
from pathlib import Path
import ssl
import subprocess
import sys
import time
from urllib import request,error

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from local_lan import configure,export_certificate

root=Path(sys.argv[1]).resolve();binary=Path(sys.argv[2]).resolve();address=sys.argv[3]
root.mkdir(parents=True,exist_ok=False)
(root/'caddy-routes.caddy').write_text('handle_path /EpicVM/auth/* {\n respond "fixture auth" 200\n}\n')
settings=configure(root,address,'https://portal.example',port=18443,setup_port=18444,admin_port=12020)
subprocess.run([str(binary),'validate','--config',str(root/'Caddyfile.lan')],check=True,capture_output=True)
log=(root/'caddy.log').open('wb')
process=subprocess.Popen([str(binary),'run','--config',str(root/'Caddyfile.lan')],stdout=log,stderr=log)
try:
    for _ in range(80):
        if process.poll() is not None:raise RuntimeError('Caddy exited; inspect isolated log')
        if (root/'lan-certificates/pki/authorities/local/root.crt').exists():break
        time.sleep(.25)
    settings=export_certificate(root)
    context=ssl.create_default_context(cafile=str(root/'lan-certificates/pki/authorities/local/root.crt'))
    opener=request.build_opener(request.ProxyHandler({}),request.HTTPSHandler(context=context))
    for _ in range(40):
        try:
            response=opener.open(settings['origin']+'/EpicVM/local-health',timeout=2)
            assert response.read()==b'ok';break
        except error.URLError:time.sleep(.25)
    else:raise RuntimeError('TLS health did not become ready')
    assert response.headers['Access-Control-Allow-Origin']=='https://portal.example'
    assert response.headers['Access-Control-Allow-Private-Network']=='true'
    assert opener.open(settings['origin']+'/EpicVM/auth/health').read()==b'fixture auth'
    cert=opener.open(settings['setupUrl']+'EpicVM-LAN-root.cer').read()
    assert hashlib.sha256(cert).hexdigest()==settings['certificateSha256']
    for path in ('root.key','lan-certificates/pki/authorities/local/root.key','%2e%2e/lan-certificates/pki/authorities/local/root.key'):
        try:opener.open(settings['setupUrl']+path)
        except error.HTTPError as exc:assert exc.code in (400,404)
        else:raise AssertionError('Private file was exposed')
    fingerprint=settings['certificateSha256']
    process.terminate();process.wait(timeout=10)
    process=subprocess.Popen([str(binary),'run','--config',str(root/'Caddyfile.lan')],stdout=log,stderr=log)
    for _ in range(40):
        try:
            assert opener.open(settings['origin']+'/EpicVM/local-health',timeout=2).read()==b'ok';break
        except error.URLError:time.sleep(.25)
    else:raise RuntimeError('TLS health failed after restart')
    assert export_certificate(root)['certificateSha256']==fingerprint
    report=dict(ok=True,trustedTls=True,publicCertificateFingerprintMatched=True,privateKeyNotServed=True,restartPreservedCA=True,origin=settings['origin'],noSystemTrustInstalled=True)
    (root/'verification.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report))
finally:
    if process.poll() is None:process.terminate();process.wait(timeout=10)
    log.close()
