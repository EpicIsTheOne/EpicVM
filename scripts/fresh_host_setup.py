"""Durable fresh-instance configuration. Never import an existing host's secrets."""
import argparse
import base64
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import sys
import time
from urllib.parse import urlsplit
from urllib import request, error


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Setup endpoint redirected. Check the configured portal address before sending credentials.')


def open_setup(req, timeout=20):
    return request.build_opener(NoRedirect()).open(req,timeout=timeout)


def origin(value):
    u=urlsplit(value)
    if u.scheme!='https' or not u.hostname or u.path not in ('','/') or u.username or u.password or u.query or u.fragment:
        raise ValueError('Use an HTTPS origin without paths or credentials.')
    return value.rstrip('/')


def atomic(path, value):
    path=Path(path); path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_name(path.name+'.tmp')
    with tmp.open('w',encoding='utf-8') as handle:
        json.dump(value,handle,indent=2);handle.flush();os.fsync(handle.fileno())
    os.chmod(tmp,0o600);os.replace(tmp,path)


def storage_path(value):
    from pathlib import PureWindowsPath
    import re
    p=PureWindowsPath(value)
    if not re.fullmatch(r'[A-Za-z]:\\[^<>:"|?*\x00-\x1f]+',value) or not p.is_absolute() or len(p.parts)<2 or any(part in ('.','..') or part.endswith((' ','.')) or re.fullmatch(r'(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?',part,re.I) for part in value.split('\\')[1:]):
        raise ValueError('Choose a dedicated folder on a local fixed NTFS drive, such as D:\\EpicVM.')
    if any(part.lower() in ('windows','users','program files','program files (x86)') for part in p.parts[1:]):
        raise ValueError('Use a dedicated data folder outside Windows, user profiles and installed programs.')
    return str(p).rstrip('\\')


def prepare(root, layout, portal_origin, public_origin, host_id, display_name, agent_url, data_root=None):
    import re
    root=Path(root).resolve()
    if layout not in ('same-pc','separate-server'): raise ValueError('Choose a supported layout.')
    if not re.fullmatch('[a-z0-9][a-z0-9._-]{0,62}',host_id) or host_id=='local':raise ValueError('Choose a valid host ID.')
    if not display_name.strip() or len(display_name)>120:raise ValueError('Choose a host name up to 120 characters.')
    u=urlsplit(agent_url)
    try: address=ipaddress.ip_address(u.hostname)
    except ValueError: raise ValueError('Choose the private agent IPv4 address.')
    allowed=address.is_loopback if layout=='same-pc' else address in ipaddress.ip_network('100.64.0.0/10')
    if u.scheme!='http' or not allowed or u.username or u.password or u.path not in ('','/') or u.query or u.fragment or u.port!=8765:
        raise ValueError('Use the loopback agent for same-PC setup or a Tailscale agent for a separate server, on port 8765.')
    public=dict(schema=1,layout=layout,portalOrigin=origin(portal_origin),publicOrigin=origin(public_origin),
                hostId=host_id,displayName=display_name.strip(),agentUrl=agent_url.rstrip('/'))
    if data_root:
        public['dataRoot']=storage_path(data_root)
    state=root/'setup-state.json';credentials=root/'setup-private.json'
    if state.exists():
        old=json.loads(state.read_text(encoding='utf-8'))
        if old['configuration']!=public:raise ValueError('Setup already exists with different settings. Resume it or choose a new setup directory.')
        if not credentials.is_file():raise ValueError('Protected setup credentials are missing. Repair is required.')
        return old
    if credentials.exists():
        private=json.loads(credentials.read_text(encoding='utf-8'))
        if private.get('configuration')!=public:raise ValueError('Protected state already exists with different settings.')
        saved=dict(configuration=public,stage='prepared',checks={},updatedAt=int(time.time()),error=None)
        atomic(state,saved)
        return saved
    if root.exists() and any(root.iterdir()):raise ValueError('Choose an empty protected setup directory.')
    root.mkdir(parents=True,exist_ok=True)
    private=dict(agentToken=secrets.token_urlsafe(32),syncToken=secrets.token_urlsafe(32),
                 dashboardSecret=secrets.token_urlsafe(32),portalSecret=secrets.token_urlsafe(32),remoteHostKey=secrets.token_urlsafe(32))
    private['configuration']=public
    atomic(credentials,private)
    saved=dict(configuration=public,stage='prepared',checks={},updatedAt=int(time.time()),error=None)
    atomic(state,saved)
    return saved


def initialize_admin(root, username, password):
    import re
    from werkzeug.security import generate_password_hash
    path=Path(root)/'portal-admin.json'
    if path.exists():return
    if not re.fullmatch(r'[a-zA-Z0-9_]{3,32}',username) or len(password)<12:raise ValueError('Choose an administrator name and a password of at least 12 characters.')
    salt=secrets.token_hex(16)
    digest=base64.b64encode(hashlib.pbkdf2_hmac('sha256',password.encode(),salt.encode(),260000)).decode()
    atomic(path,dict(username=username,passwordHash=generate_password_hash(password),portalPasswordHash='pbkdf2_sha256$'+salt+'$'+digest))


def enrollment(root):
    # Pin the independent instance before sending host credentials.
    connectivity(root)
    root=Path(root);state=json.loads((root/'setup-state.json').read_text());private=json.loads((root/'setup-private.json').read_text())
    config=state['configuration']
    if state.get('stage')=='expired':
        private.pop('enrollment',None)
        atomic(root/'setup-private.json',private)
    if 'enrollment' not in private:
        payload={**config,'agentToken':private['agentToken'],'syncToken':private['syncToken']}
        req=request.Request(config['portalOrigin']+'/EpicVM/api/host-setup/start',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'},method='POST')
        with open_setup(req) as response: item=json.load(response)
        private['enrollment']={k:item[k] for k in ('id','deviceToken','code','expiresAt')}
        atomic(root/'setup-private.json',private)
        state.update(stage='awaiting-approval',updatedAt=int(time.time()),error=None)
        atomic(root/'setup-state.json',state)
    return {k:v for k,v in private['enrollment'].items() if k!='deviceToken'}


def connectivity(root):
    root=Path(root)
    state=json.loads((root/'setup-state.json').read_text(encoding='utf-8'))
    c=state['configuration']
    with open_setup(c['portalOrigin']+'/EpicVM/api/host-setup/health',timeout=15) as response:
        health=json.loads(response.read(8193))
    if health.get('profile')!='multiseat' or not isinstance(health.get('instanceId'),str):
        raise ValueError('This address is not a host-setup portal.')
    previous=state.get('portalInstanceId')
    if previous and previous!=health['instanceId']:
        raise ValueError('Portal identity changed. Check the address before continuing.')
    state['portalInstanceId']=health['instanceId']
    state.setdefault('checks',{})['portalHttps']=True
    # Gateway health proves HTTPS reachability, never media or external NAT.
    try:
        with open_setup(c['publicOrigin']+'/EpicVM/auth/health',timeout=15) as response:
            state['checks']['gatewayHttps']=response.status==200
    except (OSError,error.URLError):
        state['checks']['gatewayHttps']=False
    atomic(root/'setup-state.json',state)
    return dict(portalHttps=True,gatewayHttps=state['checks']['gatewayHttps'],
                instanceId=health['instanceId'],externalMediaVerified=False,
                message='Portal HTTPS verified. Gateway health becomes available after runtime installation; test media from the intended client network.')


def poll(root):
    connectivity(root)
    root=Path(root);state=json.loads((root/'setup-state.json').read_text());private=json.loads((root/'setup-private.json').read_text());item=private['enrollment']
    req=request.Request(state['configuration']['portalOrigin']+'/EpicVM/api/host-setup/'+item['id']+'/claim',data=b'{}',headers={'Content-Type':'application/json','Authorization':'Bearer '+item['deviceToken']},method='POST')
    try:
        with open_setup(req) as response: result=json.load(response)
    except error.HTTPError as exc:
        if exc.code!=410:raise
        result=dict(state='expired',ok=False)
    if result.get('state') == 'enrolled':
        key = result.pop('streamKey', None)
        if not isinstance(key, str) or len(key) != 64:
            raise ValueError('Portal did not provide this host signing authority. Update or repair the portal.')
        bytes.fromhex(key)
        if private.get('streamKey') and private['streamKey'] != key:
            raise ValueError('Host signing authority changed. Repair is required.')
        private['streamKey'] = key
        atomic(root/'setup-private.json', private)
    stage='enrolled' if result['state']=='enrolled' else 'awaiting-approval' if result['state']=='pending' else result['state']
    if stage=='enrolled' and state['stage'] in ('runtime-prepared','runtime-installed','connection-check','complete'):
        stage=state['stage']
    state.update(stage=stage,activated=result.get('activated',False),updatedAt=int(time.time()),error=None)
    atomic(root/'setup-state.json',state)
    return result


def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','enroll','poll','status','connectivity']);parser.add_argument('--root',required=True);parser.add_argument('--configuration')
    args=parser.parse_args()
    try:
        if args.action=='prepare':
            c=json.loads(Path(args.configuration).read_text(encoding='utf-8-sig'))
            result=prepare(args.root,c['layout'],c['portalOrigin'],c['publicOrigin'],c['hostId'],c['displayName'],c['agentUrl'],c.get('dataRoot'))
            if c['layout']=='same-pc': initialize_admin(args.root,c.get('adminUsername',''),c.get('adminPassword',''))
            if c.get('operatorSid'):
                import re
                if not re.fullmatch(r'S-1-5-21-(?:\d+-){2}\d+-\d+',c['operatorSid']):raise ValueError('Choose a local Windows operator account.')
                if result.get('operatorSid') and result['operatorSid']!=c['operatorSid']:raise ValueError('Operator account differs from saved setup.')
                result['operatorSid']=c['operatorSid'];atomic(Path(args.root)/'setup-state.json',result)
        elif args.action=='enroll':result=enrollment(args.root)
        elif args.action=='poll':result=poll(args.root)
        elif args.action=='connectivity':result=connectivity(args.root)
        else:result=json.loads((Path(args.root)/'setup-state.json').read_text())
        print(json.dumps(dict(ok=True,data=result)))
    except Exception as e:
        # Do not leak HTTP payloads, credentials or file contents through diagnostics.
        print(json.dumps(dict(ok=False,error=str(e) if isinstance(e,ValueError) else 'Setup operation failed: '+type(e).__name__)))
        return 1
    return 0

if __name__=='__main__':sys.exit(main())
