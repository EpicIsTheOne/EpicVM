import json,sys,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'scripts'))
from fresh_host_setup import prepare,atomic,initialize_admin
from werkzeug.security import generate_password_hash
state=Path(tempfile.mkdtemp(prefix='epicvm-independent-portal-'))
prepare(state,'same-pc','https://portal.owner.example','https://stream.owner.example','preview-pc','Preview PC','http://127.0.0.1:8765')
initialize_admin(state,'preview_admin','fixture-password-only')
from portal_service import run
run(state,root)
