import React, { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { checkSessionResponse, sessionVersion } from '../session'
import './Notifications.css'

export default function Notifications({ owner, onChange }) {
  const navigate = useNavigate()
  const [items, setItems] = useState([]), [count, setCount] = useState(0)
  const [open, setOpen] = useState(false), [error, setError] = useState(''), [busy, setBusy] = useState(false)
  const refreshRef = useRef(null), changeRef = useRef(onChange)
  changeRef.current = onChange
  useEffect(() => {
    let disposed = false, loading = false, controller, signature
    setItems([]); setCount(0); setOpen(false); setError('')
    async function refresh(force = false) {
      if (loading || (document.hidden && force !== true)) return
      loading = true; controller = new AbortController()
      const timer = setTimeout(() => controller.abort(), 15000)
      try {
        const version = sessionVersion()
        const response = await fetch('/EpicVM/api/account/notifications', { cache: 'no-store', signal: controller.signal })
        checkSessionResponse(response, version)
        const body = await response.json()
        if (!response.ok || !body.ok) throw Error('Could not check updates. Try again.')
        if (disposed) return
        setItems(body.notifications); setCount(body.unreadCount); setError('')
        const next = body.notifications.map(item => item.id + ':' + (item.state || '')).sort().join(',')
        if (signature !== undefined && next !== signature) changeRef.current?.()
        signature = next
      } catch (e) { if (!disposed) setError(e.message || 'Could not check updates.') }
      finally { clearTimeout(timer); loading = false }
    }
    refreshRef.current = () => refresh(true)
    refresh(true)
    const timer = setInterval(refresh, 10000)
    window.addEventListener('focus', refresh); document.addEventListener('visibilitychange', refresh)
    return () => { disposed = true; controller?.abort(); clearInterval(timer); window.removeEventListener('focus', refresh); document.removeEventListener('visibilitychange', refresh) }
  }, [owner])
  useEffect(() => {
    if (!open) return
    const close = event => { if (event.key === 'Escape') setOpen(false) }
    window.addEventListener('keydown', close)
    return () => window.removeEventListener('keydown', close)
  }, [open])
  async function markRead(ids, target) {
    if (busy) return
    setBusy(true); setError('')
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 15000)
    try {
      const sessionResponse = await fetch('/EpicVM/api/account/session', { cache: 'no-store', signal: controller.signal })
      checkSessionResponse(sessionResponse)
      const session = await sessionResponse.json()
      if (!sessionResponse.ok || !session.ok) throw Error('Refresh your sign-in and try again.')
      const response = await fetch('/EpicVM/api/account/notifications/read', { method: 'POST', signal: controller.signal, headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': session.csrfToken }, body: JSON.stringify({ ids }) })
      checkSessionResponse(response)
      if (!response.ok) throw Error('Could not save read state. Try again.')
      await refreshRef.current?.()
      if (target) { setOpen(false); navigate(target) }
    } catch (e) { setError(e.message) }
    finally { clearTimeout(timer); setBusy(false) }
  }
  return <div className="evm-notifications">
    <button type="button" className="evm-updates-toggle" aria-expanded={open} onClick={() => { setOpen(!open); refreshRef.current?.() }}>Updates{count > 0 && <span aria-label={`${count} unread updates`}>{count > 99 ? '99+' : count}</span>}{error && <span aria-label="Updates unverified">!</span>}</button>
    {open && <section className="evm-updates-panel" aria-label="Account updates">
      <div className="evm-updates-heading"><strong>Updates{count > 0 ? ` (${count} unread)` : ''}</strong><button type="button" onClick={() => setOpen(false)} aria-label="Close updates">×</button></div>
      {error && <p role="alert">{error} <button disabled={busy} onClick={() => refreshRef.current?.()}>Retry</button></p>}
      {!items.length && !error && <p>No updates yet.</p>}
      {items.some(item => !item.read) && <button disabled={busy} onClick={() => markRead(items.filter(item => !item.read).map(item => item.id))}>Mark displayed updates read</button>}
      <ul>{items.map(item => <li key={item.id}><button disabled={busy} className={item.read ? 'is-read' : 'is-unread'} onClick={() => item.read ? (setOpen(false), navigate(item.target)) : markRead([item.id], item.target)}>{!item.read && <span className="evm-update-dot" aria-label="Unread" />}{item.title}</button></li>)}</ul>
      {count > 100 && <p>Showing the first 100 updates. Mark these read to see more.</p>}
    </section>}
  </div>
}
