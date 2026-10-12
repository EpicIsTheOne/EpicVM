import json
from pathlib import Path
import sys
import pytest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from fresh_host_setup import prepare, atomic
from fresh_host_runtime import prepare_runtime, prepare_gateway


def setup(tmp_path):
    state=tmp_path/'setup';root=tmp_path/'runtime';package=tmp_path/'package'
    prepare(state,'same-pc','https://portal.owner.example','https://stream.owner.example','owner-pc','Owner PC','http://127.0.0.1:8765')
    saved=json.loads((state/'setup-state.json').read_text());saved['stage']='enrolled';atomic(state/'setup-state.json',saved)
    private=json.loads((state/'setup-private.json').read_text());private['streamKey']='ab'*32;atomic(state/'setup-private.json',private)
    (package/'scripts').mkdir(parents=True)
    for file in ('host_stream_gateway.py','direct_stream_auth.py'):(package/'scripts'/file).write_text('# fixture')
    return state,root,package


def test_fresh_state_is_independent_and_retry_preserves_secrets(tmp_path):
    state,root,package=setup(tmp_path)
    sid='S-1-5-21-1-2-3-1001'
    assert prepare_runtime(state,root,package,sid)['stage']=='runtime-prepared'
    before={file:(root/file).read_bytes() for file in ('signing.key','sync.token','operator.sid','Caddyfile')}
    prepare_runtime(state,root,package,sid)
    assert before=={file:(root/file).read_bytes() for file in before}
    assert (root/'signing.key').read_bytes()==bytes.fromhex('ab'*32)
    assert json.loads((root/'routes.json').read_text())=={}
    assert json.loads((root/'hosting-policy.json').read_text())['maxSeats']==1
    assert 'techexplore' not in (root/'Caddyfile').read_text()
    with pytest.raises(ValueError):prepare_runtime(state,root,package,'S-1-5-21-1-2-3-1002')


def test_gateway_bootstraps_before_enrollment_and_retains_its_config(tmp_path):
    state,root,package=setup(tmp_path)
    prepare_gateway(state,root)
    before=(root/'Caddyfile').read_bytes()
    prepare_runtime(state,root,package,'S-1-5-21-1-2-3-1001')
    assert (root/'Caddyfile').read_bytes()==before
    assert b'127.0.0.1:5050' in before


def test_fresh_runtime_rejects_unapproved_and_mismatched_state(tmp_path):
    state,root,package=setup(tmp_path)
    saved=json.loads((state/'setup-state.json').read_text());saved['stage']='pending';atomic(state/'setup-state.json',saved)
    with pytest.raises(ValueError):prepare_runtime(state,root,package,'S-1-5-21-1-2-3-1001')
    assert not root.exists()
    saved['stage']='enrolled';atomic(state/'setup-state.json',saved)
    prepare_runtime(state,root,package,'S-1-5-21-1-2-3-1001')
    private=json.loads((state/'setup-private.json').read_text());private['streamKey']='cd'*32;atomic(state/'setup-private.json',private)
    with pytest.raises(ValueError):prepare_runtime(state,root,package,'S-1-5-21-1-2-3-1001')
    assert (root/'signing.key').read_bytes()==bytes.fromhex('ab'*32)


@pytest.mark.parametrize('authority',['https://owner.example:8443','https://owner.example/a','https://owner.example\n{','https://user@owner.example'])
def test_gateway_rejects_unsafe_authority(tmp_path,authority):
    state,root,_=setup(tmp_path)
    saved=json.loads((state/'setup-state.json').read_text());saved['configuration']['publicOrigin']=authority;atomic(state/'setup-state.json',saved)
    with pytest.raises(ValueError):prepare_gateway(state,root)
