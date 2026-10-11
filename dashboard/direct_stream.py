"""EpicVM portal to host-local stream launch handoff."""

from __future__ import annotations

from html import escape
import json
import os
from pathlib import Path
from urllib.parse import urlsplit

from flask import Response, redirect, request

try:
    from .direct_stream_auth import ROUTE_RE, issue_grant
except ImportError:
    from direct_stream_auth import ROUTE_RE, issue_grant


def configured_streams() -> dict:
    path = os.environ.get("EPICVM_DIRECT_STREAMS_FILE", "/opt/blobe-vm/private/direct-streams.json")
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def local_stream_origin(host_id):
    """Configured per-host HTTPS origin, never a browser-supplied destination."""
    path = os.environ.get('EPICVM_LOCAL_STREAMS_FILE', '/opt/blobe-vm/private/local-streams.json')
    try:
        value = json.loads(Path(path).read_text())[host_id]
        if not isinstance(value, dict) or not isinstance(value.get('origin'), str):
            return None
        origin = value['origin'].rstrip('/') if value.get('enabled') is True else ''
        parsed = urlsplit(origin)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment:
            return None
        return origin
    except (OSError, ValueError, KeyError, TypeError):
        return None


def register_direct_stream(app, core):
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
        if route.startswith("seat-"):
            seat = core["_host_game_stream_record"](route)
            if not seat or seat["host_id"] != host_id:
                return Response("Stream unavailable", 404)
            if not admin and not (user and seat["realm"] == "portal"
                                  and seat["username"] == user["username"]):
                return Response("Stream forbidden", 403)
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
        local = request.args.get('connection') == 'local'
        if local:
            base = local_stream_origin(host_id)
            if not base:
                return Response('<main><h1>Local connection is not available</h1><p>Your Windows apps stay running.</p>'
                                f'<a href="{escape(request.path, quote=True)}">Use normal connection</a></main>', 503, mimetype='text/html', headers={'Cache-Control': 'no-store'})
            path += ('&' if '?' in path else '?') + 'connection=local&route=' + route
        if not base.startswith("https://") or not path.startswith(f"/EpicVM/{route}/"):
            return Response("Stream configuration unavailable", 503)
        key_path = os.environ.get("EPICVM_DIRECT_STREAM_KEY_FILE", "/opt/blobe-vm/private/direct-stream.key")
        try:
            key = Path(key_path).read_bytes()
            if len(key) < 32:
                raise ValueError("Signing key is too short")
            subject = "portal:" + user["username"] if user else "admin:dashboard"
            grant = issue_grant(key, route=route, user=subject, path=path)
        except (OSError, ValueError):
            return Response("Stream authentication unavailable", 503)
        action = escape(base + "/EpicVM/auth/redeem", quote=True)
        html = ("<!doctype html><meta charset=utf-8><title>Opening EpicVM stream</title>"
                "<meta name=referrer content=no-referrer>"
                f'<form method="post" action="{action}">'
                f'<input type="hidden" name="grant" value="{escape(grant, quote=True)}">'
                '<button type="submit">Open stream</button></form>')
        if local:
            fallback = escape(request.path, quote=True)
            probe = json.dumps(base + '/EpicVM/local-health')
            html += (f'<main><h1>Opening over your local network</h1><p id="status" role="status">Checking the host. Your browser may ask for local network access.</p>'
                     f'<p><a href="{fallback}">Use normal connection</a></p><p>Both options use the same desktop and leave your Windows apps running.</p></main>'
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
        response.headers["Content-Security-Policy"] = f"default-src 'none'; script-src 'unsafe-inline'; connect-src {base}; form-action {base}; base-uri 'none'"
        return response
