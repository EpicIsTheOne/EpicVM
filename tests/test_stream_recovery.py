import subprocess
from pathlib import Path

from scripts.provision_direct_stream import patch_stream_recovery


def test_recovery_patch_is_repeatable_and_bounds_old_transport(tmp_path):
    (tmp_path / 'stream.js').write_text('''
function startApp() {
        window["app"] = app;
}
export function* reload() {
                const stopped = yield oldStream.stop();
}
''', encoding='utf-8')
    assert patch_stream_recovery(tmp_path)
    assert not patch_stream_recovery(tmp_path)
    assert 'oldStream.ws?.close()' in (tmp_path / 'stream.js').read_text(encoding='utf-8')
    harness = tmp_path / 'teardown.mjs'
    harness.write_text('''
import assert from 'node:assert/strict';
import { reload } from './stream.js';
globalThis.setTimeout = resolve => {queueMicrotask(resolve);return 0};
let closed=0,transportClosed=0;
globalThis.oldStream={stop:()=>new Promise(()=>{}),ws:{close:()=>closed++},
  transport:{close:()=>{transportClosed++;return new Promise(()=>{})}}};
const operation=reload();let result=operation.next();
while(!result.done)result=operation.next(await result.value);
assert.equal(closed,1);assert.equal(transportClosed,1);
''', encoding='utf-8')
    subprocess.run(['node', str(harness)], check=True, capture_output=True, timeout=10)


def test_recovery_waits_bounds_retries_and_deduplicates_clicks(tmp_path):
    module = Path('scripts/stream_recovery.js').resolve().as_uri()
    script = tmp_path / 'recovery.mjs'
    script.write_text('''
import assert from 'node:assert/strict';
import { StreamRecovery } from MODULE;
let now = 0, calls = 0, release;
let stream = {ws:{readyState:1},hasVideoReady:true};
const messages = [];
const app = {getStream:()=>stream,reloadStream:async()=>{calls++;await new Promise(r=>release=r)}};
const recovery = new StreamRecovery(app, (text,busy)=>messages.push({text,busy}), ()=>now);
recovery.tick(true,true);
stream.ws.readyState=3;
recovery.tick(false,true); now=10000; recovery.tick(false,true);
assert.equal(calls,0); assert.match(messages.at(-1).text,/offline/);
recovery.tick(true,true); now=18001; recovery.tick(true,true);
assert.equal(calls,1);
await recovery.retry(true); await recovery.retry(true);
assert.equal(calls,1);
release(); await new Promise(r=>setImmediate(r));
for(let attempt=2;attempt<=3;attempt++){
  now+=31000; recovery.tick(true,true); now+=8001; recovery.tick(true,true); assert.equal(calls,attempt);
  release(); await new Promise(r=>setImmediate(r));
}
now+=31000; recovery.tick(true,true); now+=8001; recovery.tick(true,true); assert.equal(calls,3);
assert.match(messages.at(-1).text,/couldn’t reconnect/);
const manual=recovery.retry(true); assert.equal(calls,4); release(); await manual;
stream={ws:{readyState:1},hasVideoReady:true}; recovery.tick(true,true);
assert.equal(messages.at(-1).text,'');
now+=31000; recovery.tick(true,true); assert.equal(recovery.attempts,0);
recovery.dispose(); stream.ws.readyState=3; now+=60000; recovery.tick(true,true);
assert.equal(calls,4);
'''.replace('MODULE', repr(module)), encoding='utf-8')
    subprocess.run(['node', str(script)], check=True, capture_output=True, timeout=10)


def test_open_transport_with_stalled_video_recovers_and_hidden_tabs_wait(tmp_path):
    module = Path('scripts/stream_recovery.js').resolve().as_uri()
    script = tmp_path / 'media.mjs'
    script.write_text('''
import assert from 'node:assert/strict';
import { StreamRecovery } from MODULE;
let now=0,calls=0,frames=5;
const stream={ws:{readyState:1},hasVideoReady:true,transport:{peer:{connectionState:'connected'},videoReceiver:{
  getStats:async()=>new Map([['video',{type:'inbound-rtp',kind:'video',framesDecoded:frames}]])
}}};
const recovery=new StreamRecovery({getStream:()=>stream,reloadStream:async()=>{calls++}},()=>{},()=>now);
recovery.tick(true,true); await new Promise(r=>setImmediate(r));
now=20000;frames=15;recovery.tick(true,true);await new Promise(r=>setImmediate(r));
assert.equal(calls,0);
now=45000;recovery.tick(true,true);assert.equal(calls,0);
now=51000;recovery.tick(true,true);await new Promise(r=>setImmediate(r));assert.equal(calls,1);
now=90000;recovery.tick(true,false);assert.equal(calls,1);
now=120000;recovery.tick(true,false);assert.equal(calls,1);
frames=25;recovery.tick(true,true);await new Promise(r=>setImmediate(r));
recovery.tick(true,true);assert.equal(calls,1);
'''.replace('MODULE', repr(module)), encoding='utf-8')
    subprocess.run(['node', str(script)], check=True, capture_output=True, timeout=10)
