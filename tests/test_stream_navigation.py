import subprocess

from flask import Flask

from dashboard import direct_stream
from scripts.provision_direct_stream import patch_stream_navigation


def test_preparing_stream_provides_safe_workspace_exit(monkeypatch):
    app = Flask(__name__)
    monkeypatch.setattr(direct_stream, "configured_streams", lambda: {})
    direct_stream.register_direct_stream(app, {
        "_current_portal_user": lambda: {"username": "alice"},
        "_admin_vm_sso_authenticated": lambda: False,
        "_user_can_access_vm": lambda *args, **kwargs: True,
    })
    response = app.test_client().get('/EpicVM/stream-launch/vm-test')
    assert response.status_code == 503
    assert b'href="/EpicVM/portal"' in response.data
    assert b'leaves your Windows apps running' in response.data
    assert response.headers['Cache-Control'] == 'no-store'


def test_exit_returns_to_workspace_on_success_failure_and_stalled_stop(tmp_path):
    path = tmp_path / 'stream.js'
    path.write_text('''class Sidebar {
    constructor(app) {
        this.app = app;
        this.exitStreamButton = {addEventListener: (_, handler) => this.exit = handler};
        this.buttonDiv = {appendChild: () => {}};
        // Close stream
        this.exitStreamButton.innerText = "Exit";
        this.exitStreamButton.addEventListener("click", () => window.close());
        this.buttonDiv.appendChild(this.exitStreamButton);
    }
}''', encoding='utf-8')
    assert patch_stream_navigation(tmp_path)
    assert not patch_stream_navigation(tmp_path)
    harness = '''
const assert = require('node:assert/strict');
global.setTimeout = resolve => { queueMicrotask(resolve); return 0; };
(async () => {
  for (const stop of [() => Promise.resolve(true), () => Promise.resolve(false),
                     () => Promise.reject(new Error('disconnected')), () => new Promise(() => {}),
                     () => { throw new Error('synchronous failure'); }]) {
    let destination;
    global.window = {location: {assign: url => { destination = url; }}};
    const sidebar = new Sidebar({getStream: () => ({stop})});
    await sidebar.exit();
    assert.equal(destination, 'https://techexplore.us/EpicVM/portal');
    assert.equal(sidebar.exitStreamButton.disabled, true);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
    script = tmp_path / 'check.cjs'
    script.write_text(path.read_text(encoding='utf-8') + harness, encoding='utf-8')
    subprocess.run(['node', str(script)], check=True, capture_output=True, timeout=10)
