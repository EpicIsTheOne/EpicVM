import json
from pathlib import Path
import ssl
import sys
from urllib import request
root=Path(sys.argv[1])
state=json.loads((root/'local-gateway.json').read_text())
opener=request.build_opener(request.ProxyHandler({}),request.HTTPSHandler(context=ssl.create_default_context(cafile=str(root/'lan-certificates/pki/authorities/local/root.crt'))))
assert opener.open(state['origin']+'/EpicVM/local-health',timeout=5).read()==b'ok'
print('Service local HTTPS verified against its own CA.')
