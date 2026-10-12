"""Smoke-test the Linux package without production mounts or networking."""
import json
import os
from pathlib import Path
import sys
import tempfile
sys.path.insert(0,'/package/scripts')
from fresh_host_setup import prepare,initialize_admin
from portal_service import environment

state=Path(tempfile.mkdtemp(prefix='epicvm-lan-storage-'))
prepare(state,'separate-server','https://portal.example','https://stream.example','fixture-pc','Fixture PC','http://100.64.0.1:8765',r'D:\EpicVM')
initialize_admin(state,'fixtureadmin','disposable-fixture-password')
env=environment(state,Path('/package'))
assert Path(env['BLOBEDASH_STATE'])==state/'portal'
assert Path(env['EPICVM_LOCAL_STREAMS_FILE'])==state/'portal/local-streams.json'
os.environ.update(env);sys.path.insert(0,'/package/dashboard')
import app
client=app.app.test_client()
health=client.get('/EpicVM/api/host-setup/health')
assert health.status_code==200 and health.json['profile']=='multiseat'
assert client.post('/EpicVM/api/host-runtime/local-gateway',json={}).status_code==401
assert client.get('/EpicVM/api/management/host-setup').status_code in (401,403)
assets=list(Path('/package/epicvm_web/dist/assets').glob('*.js'))
assert len(assets)==1 and 'First local connection: trust this host certificate' in assets[0].read_text()
print(json.dumps(dict(ok=True,linuxStorageIndependent=True,portalStartup=True,localMetadataAuthEnforced=True,frontendTrustInstructionsIncluded=True)))
