"""Run with an isolated protected data root, never the production locator."""
import json
import os
from pathlib import Path
import sqlite3
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from fresh_host_setup import prepare,initialize_admin,atomic
from fresh_host_runtime import prepare_runtime
from portal_service import environment

data,checkpoint,repo=map(Path,sys.argv[1:])
setup=checkpoint/'setup'
package=repo/'onboarding-release-build-20261012/windows-package'
prepare(setup,'same-pc','https://portal.example','https://stream.example','fixture-pc','Fixture PC','http://127.0.0.1:8765',str(data))
initialize_admin(setup,'fixtureadmin','disposable-fixture-password')
state=json.loads((setup/'setup-state.json').read_text());state['stage']='enrolled';atomic(setup/'setup-state.json',state)
private=json.loads((setup/'setup-private.json').read_text());private['streamKey']='ab'*32;atomic(setup/'setup-private.json',private)
runtime=data/'host-runtime'
prepare_runtime(setup,runtime,package,'S-1-5-21-1-2-3-1001')
before={name:(runtime/name).read_bytes() for name in ('signing.key','sync.token','host-runtime.json')}
env=environment(setup,package)
assert Path(env['BLOBEDASH_STATE'])==data/'portal'
assert Path(env['EPICVM_HOST_RUNTIME_ROOT'])==runtime
with sqlite3.connect(data/'portal/persistence.sqlite3') as db:
    db.execute('CREATE TABLE fixture (value TEXT)');db.execute("INSERT INTO fixture VALUES ('retained')")
prepare_runtime(setup,runtime,package,'S-1-5-21-1-2-3-1001')
assert before=={name:(runtime/name).read_bytes() for name in before}
assert environment(setup,package)==env
with sqlite3.connect(data/'portal/persistence.sqlite3') as db:assert db.execute('SELECT value FROM fixture').fetchone()[0]=='retained'
print('Custom-root runtime credentials and portal database preserved on reinitialization.')
