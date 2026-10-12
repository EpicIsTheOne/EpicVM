"""Private Windows pairing backend; public streaming remains host-runtime managed."""
import json
import os
from pathlib import Path
import socket
import secrets
from urllib.parse import urlsplit
import subprocess
import time
import atexit

try:
    from .moonlight_orchestrator import MoonlightOrchestrator, ConsoleOrchestrationError, validate_vm_name
except ImportError:
    from moonlight_orchestrator import MoonlightOrchestrator, ConsoleOrchestrationError, validate_vm_name


class NativeMoonlightOrchestrator(MoonlightOrchestrator):
    def __init__(self, *, viewer_package, root, **kwargs):
        self.viewer=Path(viewer_package).resolve()
        self.web_binary=self.viewer/('web-server.exe' if os.name=='nt' else 'web-server')
        self.stream_binary=self.viewer/('streamer.exe' if os.name=='nt' else 'streamer')
        self.processes={}
        atexit.register(self.close)
        # The Linux portal runs pairing APIs only. Media runs on the Windows host.
        if not self.web_binary.is_file() or (os.name=='nt' and not self.stream_binary.is_file()):
            raise ConsoleOrchestrationError('Native viewer package is incomplete.',status=503,code='viewer_missing')
        super().__init__(root=root,routing_probe=lambda:True,route_owner_probe=lambda route:True,**kwargs)

    def build_compose(self, **kwargs):
        return '# Native private pairing backend; no Docker container.\n'

    def _container_url(self,name,route_prefix=None):
        plan=self._read_plan(name)
        return 'http://127.0.0.1:'+str(plan['pairingPort'])+str(plan['routePrefix']).rstrip('/')

    def _runtime_isolated(self,name):
        safe=validate_vm_name(name)
        process=self.processes.get(safe)
        if process is not None:return process.poll() is None
        return self._retained_process(safe) is not None

    def start_staged(self,name):
        if self._runtime_isolated(name):return {'ok':True}
        plan=self._read_plan(name);target=self._instance_root(name)
        self._wait_for_sunshine(plan['guestIp'],timeout=30,sunshine_port=plan['sunshinePort'])
        # Allocate a private pairing listener; the packaged streamer is not public.
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
        config=json.loads((target/'server/config.json').read_text(encoding='utf-8'))
        config['web_server']['bind_address']='127.0.0.1:'+str(port)
        plan.setdefault('pairingHeader','X-EpicVM-Internal-'+secrets.token_hex(32))
        config['web_server']['forwarded_header']['username_header']=plan['pairingHeader']
        config['streamer_path']=str(self.stream_binary)
        (target/'server/config.json').write_text(json.dumps(config),encoding='utf-8')
        plan['pairingPort']=port
        (target/'plan.json').write_text(json.dumps(plan),encoding='utf-8')
        process=subprocess.Popen([str(self.web_binary),'--config-path','server/config.json','run'],cwd=target,
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        self.processes[validate_vm_name(name)]=process
        import psutil
        plan['pairingPid']=process.pid;plan['pairingCreatedAt']=psutil.Process(process.pid).create_time()
        (target/'plan.json').write_text(json.dumps(plan),encoding='utf-8')
        for _ in range(40):
            if process.poll() is not None:break
            if self._tcp_probe('127.0.0.1',port,0.5):return {'ok':True,'pairingPrivate':True}
            time.sleep(.25)
        self.stop_staged(name)
        raise ConsoleOrchestrationError('Native pairing service did not start.',status=502,code='pairing_start_failed')

    def _http(self, method, url, *, headers=None, body=None, timeout=15):
        parsed=urlsplit(url)
        if parsed.hostname!='127.0.0.1':raise ConsoleOrchestrationError('Pairing must use the private viewer.',status=403,code='pairing_scope')
        pieces=parsed.path.strip('/').split('/')
        if len(pieces)<2 or pieces[0]!='vm':raise ConsoleOrchestrationError('Invalid pairing route.',status=403,code='pairing_scope')
        name=validate_vm_name(pieces[1]);plan=self._read_plan(name)
        if parsed.port!=plan.get('pairingPort'):raise ConsoleOrchestrationError('Invalid pairing listener.',status=403,code='pairing_scope')
        clean=dict(headers or {})
        user=clean.pop('X-EpicVM-User',None)
        if user:clean[plan['pairingHeader']]=user
        return super()._http(method,url,headers=clean,body=body,timeout=timeout)

    def stop_staged(self,name):
        process=self.processes.pop(validate_vm_name(name),None)
        if process is None:
            retained=self._retained_process(name)
            if retained:
                retained.terminate()
                try:retained.wait(timeout=5)
                except Exception:pass
            return
        if process and process.poll() is None:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)

    def _retained_process(self,name):
        import psutil
        try:
            plan=self._read_plan(name)
            process=psutil.Process(int(plan['pairingPid']))
            if abs(process.create_time()-float(plan['pairingCreatedAt']))>.01:return None
            if Path(process.exe()).resolve()!=self.web_binary:return None
            if Path(process.cwd()).resolve()!=self._instance_root(name).resolve():return None
            if process.cmdline()[1:]!=['--config-path','server/config.json','run']:return None
            return process
        except (OSError,ValueError,KeyError,psutil.Error,ConsoleOrchestrationError):return None

    def close(self):
        for name in list(self.processes):self.stop_staged(name)
