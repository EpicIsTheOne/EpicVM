import argparse
import getpass
import json
import re
from pathlib import Path
from werkzeug.security import generate_password_hash
from fresh_host_setup import prepare, atomic, initialize_admin
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--configuration',required=True);p.add_argument('--admin',required=True);a=p.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9_]{3,32}',a.admin):raise SystemExit('Choose an administrator name with 3-32 letters, digits or underscores.')
    root=Path(a.root)
    if (root/'portal-admin.json').exists():raise SystemExit('Administrator already initialized. Existing accounts were preserved.')
    password=getpass.getpass('New EpicVM administrator password: ')
    if len(password)<12:raise SystemExit('Use a password of at least 12 characters.')
    if password!=getpass.getpass('Confirm password: '):raise SystemExit('Passwords did not match.')
    c=json.loads(Path(a.configuration).read_text(encoding='utf-8-sig'))
    prepare(root,c['layout'],c['portalOrigin'],c['publicOrigin'],c['hostId'],c['displayName'],c['agentUrl'])
    initialize_admin(root,a.admin,password)
    print('Independent instance initialized. Configure HTTPS and enroll the Windows host next.')
