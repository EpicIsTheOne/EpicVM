"""EpicVM portal to host-local stream launch handoff."""

from __future__ import annotations

from html import escape
from datetime import datetime, timezone
import json
import hashlib
import hmac
import os
import ipaddress
import re
from pathlib import Path
from urllib.parse import urlsplit, urlencode

from flask import Response, redirect, request

try:
    from .direct_stream_auth import ROUTE_RE, issue_grant, verify_session
except ImportError:
    from direct_stream_auth import ROUTE_RE, issue_grant, verify_session


def configured_streams() -> dict:
    path = os.environ.get("EPICVM_DIRECT_STREAMS_FILE", "/opt/blobe-vm/private/direct-streams.json")
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def validate_local_gateway(value):
    if not isinstance(value, dict) or value.get('mode') != 'local-ca' or value.get('clientTrustRequired') is not True or type(value.get('enabled')) is not bool:
        raise ValueError('Invalid local gateway')
    https=urlsplit(value.get('origin',''))
    address=ipaddress.ip_address(https.hostname or '')
    if address.version!=4 or not any(address in ipaddress.ip_network(n) for n in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')):
        raise ValueError('Not a LAN address')
    origin=f'https://{address}:8443'
    setup=f'http://{address}:8444/'
    fingerprint=value.get('certificateSha256','')
    if value.get('origin')!=origin or value.get('setupUrl')!=setup or not isinstance(fingerprint,str) or not re.fullmatch('[a-f0-9]{64}',fingerprint):
        raise ValueError('Invalid local trust metadata')
    return dict(enabled=value['enabled'],mode='local-ca',origin=origin,setupUrl=setup,certificateSha256=fingerprint,clientTrustRequired=True)


def local_stream_info(host_id):
    """Configured per-host HTTPS origin, never a browser-supplied destination."""
    path = os.environ.get('EPICVM_LOCAL_STREAMS_FILE', '/opt/blobe-vm/private/local-streams.json')
    try:
        value = json.loads(Path(path).read_text())[host_id]
        if not isinstance(value, dict) or not isinstance(value.get('origin'), str):
            return None
        if value.get('mode') == 'local-ca':
            return validate_local_gateway(value) if value.get('enabled') is True else None
        origin = value['origin'].rstrip('/') if value.get('enabled') is True else ''
        parsed = urlsplit(origin)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment:
            return None
        return dict(enabled=True,origin=origin,clientTrustRequired=False)
    except (OSError, ValueError, KeyError, TypeError):
        return None


def local_stream_origin(host_id):
    value=local_stream_info(host_id)
    return value['origin'] if value else None


def register_direct_stream(app, core):
    def signing_key(host_id):
        scoped = core.get('_setup_stream_key', lambda _: None)(host_id)
        return scoped if scoped is not None else Path(os.environ.get('EPICVM_DIRECT_STREAM_KEY_FILE', '/opt/blobe-vm/private/direct-stream.key')).read_bytes()

    def revision(key, user=None, route=''):
        extra = core.get('_host_account_revision', lambda _: '')(route) if route.startswith('seat-') else ''
        if user is not None:
            return f"{user['id']}:{user.get('sessionVersion', 1)}" + (':' + extra if extra else '')
        credentials = (core['_admin_credentials'](), core['_extra_admin_credentials'](), core['_dashboard_secret']())
        return hmac.new(key, repr(credentials).encode(), hashlib.sha256).hexdigest() + (':' + extra if extra else '')

    @app.post('/EpicVM/api/stream/validate')
    def validate_stream_session():
        # Only a host-signed stream session is accepted. Browser cookie auth
        # cannot invoke this endpoint or substitute a different resource.
        if request.content_length is None or request.content_length > 4096:
            return Response('Invalid stream session', 401)
        try:
            data = request.get_json(silent=True) or {}
            route, token = data['route'], data['token']
            record = configured_streams().get(route)
            if not isinstance(record, dict) or record.get('enabled') is not True:
                raise ValueError('Unavailable route')
            host_id = str(record.get('hostId') or 'epic-pc')
            key = signing_key(host_id)
            payload = verify_session(key, token, route=route)
            subject = payload['sub']
            if subject.startswith('portal:'):
                user = core['_get_user_by_username'](subject[7:])
                if (not user or user.get('disabled') or user.get('accountStatus') != 'approved'
                        or payload.get('revision') != revision(key, user, route)):
                    raise ValueError('Revoked account')
                if not core.get('_setup_host_active',lambda _:True)(host_id) and not user.get('isAdmin'):
                    raise ValueError('Host has not been activated for friends')
                if route.startswith('seat-'):
                    seat = core['_host_game_stream_record'](route)
                    allowed = (seat and seat['host_id'] == host_id and seat['realm'] == 'portal'
                               and seat['username'] == user['username'])
                else:
                    allowed = core['_user_can_access_vm'](user, route[3:], host_id=host_id)
                if not allowed:
                    raise ValueError('Resource access revoked')
            elif subject != 'admin:dashboard' or not core['_admin_vm_sso_enabled']() or payload.get('revision') != revision(key, route=route):
                raise ValueError('Revoked administrator')
        except (OSError, KeyError, TypeError, ValueError):
            return Response('Stream access revoked', 401)
        return Response(status=204)

    @app.get("/EpicVM/stream-launch/<route>")
    def launch_direct_stream(route):
        if not ROUTE_RE.fullmatch(route):
            return Response("Stream unavailable", 404)
        user = core["_current_portal_user"]()
        admin = core["_admin_vm_sso_authenticated"]()
        if not user and not admin:
            return redirect("/EpicVM/portal/login?next=" + request.path)
        record = configured_streams().get(route)
        host_id = str(record.get("hostId") or "epic-pc") if isinstance(record, dict) else "epic-pc"
        if not core.get('_setup_host_active',lambda _:True)(host_id) and not admin and not (user and user.get('isAdmin')):
            return Response('Host setup is incomplete',403)
        if route.startswith("seat-"):
            seat = core["_host_game_stream_record"](route)
            if not seat or seat["host_id"] != host_id:
                return Response("Stream unavailable", 404)
            if not admin and not (user and seat["realm"] == "portal"
                                  and seat["username"] == user["username"]):
                return Response("Stream forbidden", 403)
            assignment = core.get('_host_local_account_assignment', lambda *_: None)(seat, host_id)
            if assignment and not request.args.get('unlock'):
                return Response('<main><h1>Windows password required</h1><p>Open or resume this desktop from your workspace and enter its Windows password.</p><a href="/EpicVM/portal">Back to workspace</a></main>', 403, mimetype='text/html', headers={'Cache-Control':'no-store'})
        else:
            name = route[3:]
            if not admin and not core["_user_can_access_vm"](user, name, host_id=host_id):
                return Response("Stream forbidden", 403)
        if not isinstance(record, dict) or record.get("enabled") is not True:
            html = ("<!doctype html><meta charset=utf-8><title>Preparing EpicVM stream</title>"
                    '<meta http-equiv="refresh" content="3">'
                    '<meta name="viewport" content="width=device-width, initial-scale=1">'
                    '<main><h1>Preparing your stream</h1>'
                    '<p>Your desktop connection is getting ready. This page checks again automatically.</p>'
                    '<p>Taking longer than expected? Return to your workspace to check status and open or resume your desktop again.</p>'
                    '<p><a href="/EpicVM/portal">Back to workspace</a></p>'
                    '<p>Returning to your workspace leaves your Windows apps running.</p></main>')
            response = Response(html, status=503, mimetype="text/html")
            response.headers["Cache-Control"] = "no-store"
            return response
        base = str(record.get("hostUrl") or "").rstrip("/")
        path = str(record.get("streamPath") or "")
        # Public support context only. Do not carry launch grants into report links.
        path += ('&' if '?' in path else '?') + urlencode({'epicvmHost': host_id})
        normal_base, normal_path = base, path
        fallback_url = request.path + ('?' + urlencode({'unlock': request.args['unlock']}) if request.args.get('unlock') else '')
        local = request.args.get('connection') == 'local'
        if local:
            base = local_stream_origin(host_id)
            if not base:
                return Response('<main><h1>Local connection is not available</h1><p>Your Windows apps stay running.</p>'
                                f'<a href="{escape(fallback_url, quote=True)}">Use normal connection</a></main>', 503, mimetype='text/html', headers={'Cache-Control': 'no-store'})
            path += ('&' if '?' in path else '?') + 'connection=local&route=' + route
        if not base.startswith("https://") or not path.startswith(f"/EpicVM/{route}/"):
            return Response("Stream configuration unavailable", 503)
        key_path = os.environ.get("EPICVM_DIRECT_STREAM_KEY_FILE", "/opt/blobe-vm/private/direct-stream.key")
        try:
            key = signing_key(host_id)
            if len(key) < 32:
                raise ValueError("Signing key is too short")
            # If administrator SSO supplied the access decision, bind the grant
            # to that identity even when a separate portal cookie is present.
            subject = 'admin:dashboard' if admin else 'portal:' + user['username']
            if route.startswith('seat-') and not core.get('_consume_host_account_unlock', lambda *_: True)(route, request.args.get('unlock')):
                return Response('<main><h1>Windows password required</h1><p>Open or resume this desktop from your workspace and enter its Windows password.</p><a href="/EpicVM/portal">Back to workspace</a></main>', 403, mimetype='text/html', headers={'Cache-Control': 'no-store'})
            grant = issue_grant(key, route=route, user=subject, path=path, revision=revision(key, None if admin else user, route))
        except (OSError, ValueError):
            return Response("Stream authentication unavailable", 503)
        action = escape(base + "/EpicVM/auth/redeem", quote=True)
        html = ("<!doctype html><meta charset=utf-8><title>Opening EpicVM stream</title>"
                "<meta name=referrer content=no-referrer>"
                f'<form method="post" action="{action}">'
                f'<input type="hidden" name="grant" value="{escape(grant, quote=True)}">'
                '<button type="submit">Open stream</button></form>')
        if local:
            # Both handoffs derive from the same fresh password check. A failed
            # LAN probe can use the normal grant without replaying its unlock.
            if not normal_base.startswith('https://') or not normal_path.startswith(f'/EpicVM/{route}/'):
                return Response('Stream configuration unavailable', 503)
            normal_grant = issue_grant(key, route=route, user=subject, path=normal_path, revision=revision(key, None if admin else user, route))
            normal_action = escape(normal_base + '/EpicVM/auth/redeem', quote=True)
            html += (f'<form id="normal" method="post" action="{normal_action}"><input type="hidden" name="grant" value="{escape(normal_grant, quote=True)}">'
                     '<button type="submit">Use normal connection</button></form>')
            probe = json.dumps(base + '/EpicVM/local-health')
            report_url = '/EpicVM/settings?' + urlencode({'report': 'bug', 'host': host_id,
                'source': 'launch', 'stage': 'checking', 'connection': 'local',
                'time': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')})
            html += (f'<main><h1>Opening over your local network</h1><p id="status" role="status">Checking the host. Your browser may ask for local network access.</p>'
                     '<p>Both options use the same desktop and leave your Windows apps running. If you wait more than a minute, open it again from your workspace.</p>'
                     f'<p><a href="{escape(report_url, quote=True)}">Report a problem</a></p></main>'
                     '<script>const controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),5000);'
                     f'fetch({probe},{{mode:"cors",credentials:"omit",signal:controller.signal}})'
                     '.then(r=>{if(!r.ok)throw new Error();document.forms[0].submit()})'
                     '.catch(()=>{document.getElementById("status").textContent="We could not reach the host locally. Check that you are on its network and allow local network access. If the local hostname cannot be found, enable Secure DNS with Cloudflare or Google in your browser, or ask the host to allow it in the router DNS settings. You can also use the normal connection below."})'
                     '.finally(()=>clearTimeout(timeout));</script>')
        else:
            html += '<script>document.forms[0].submit()</script>'
        response = Response(html, mimetype="text/html")
        response.headers["Cache-Control"] = "no-store"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] = f"default-src 'none'; script-src 'unsafe-inline'; connect-src {base}; form-action {base} {normal_base}; base-uri 'none'"
        return response
