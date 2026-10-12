import React, { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { checkSessionResponse, sessionVersion } from '../session'
import { latestDesktopRequest, requestStatus, requestLink } from '../desktopRequests'

export default function DesktopRequestStatus({ onRequest }) {
  const [request, setRequest] = useState(null), [verified, setVerified] = useState(false)
  useEffect(() => {
    let disposed = false, busy = false, current
    async function refresh() {
      if (busy) return
      busy = true
      current = new AbortController()
      const timer = setTimeout(() => current.abort(), 15000)
      try {
        const version = sessionVersion()
        const response = await fetch('/EpicVM/api/account/tickets', { credentials: 'same-origin', cache: 'no-store', signal: current.signal })
        checkSessionResponse(response, version)
        const body = await response.json()
        if (!response.ok || body.ok === false) throw Error()
        if (!disposed) { const latest = latestDesktopRequest(body.tickets); setRequest(latest); onRequest?.(latest); setVerified(true) }
      } catch { if (!disposed) setVerified(false) }
      finally { clearTimeout(timer); busy = false }
    }
    refresh()
    const timer = setInterval(refresh, 10000)
    window.addEventListener('focus', refresh)
    return () => { disposed = true; current?.abort(); clearInterval(timer); window.removeEventListener('focus', refresh) }
  }, [])
  if (!request) return null
  return <section className="evm-library-card evm-request-status" aria-label="Desktop access request">
    <strong>{verified ? requestStatus(request) : 'Request status unverified'}</strong>
    {request.response && <p>{request.response}</p>}
    {!request.response && <p>Your administrator will review your request. You do not need to send another one.</p>}
    <Link className="evm-library-button-secondary" to={requestLink(request)}>View request and replies</Link>
  </section>
}
