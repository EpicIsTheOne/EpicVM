import React, { useState, useEffect, useRef, useCallback } from 'react'
import { Routes, Route, Navigate, useLocation } from 'react-router-dom'
import Landing from './pages/Landing'
import Signup from './pages/Signup'
import Signin from './pages/Signin'
import Pending from './pages/Pending'
import Portal from './pages/Portal'
import { me } from './api'
import AccountWorkspace from './pages/AccountWorkspace'
import { SESSION_EXPIRED, sessionChanged } from './session'

function PortalGate({ user, status, expired, children }) {
  const location = useLocation()
  if (!user) return <Navigate to="/signin" replace state={{ from: location.pathname, expired }} />
  if (status === 'pending' || status === 'rejected') return <Navigate to="/pending" replace />
  return children
}

export default function App() {
  const [user, setUser] = useState(null) // null = loading, false = anon, object = authed
  const [checking, setChecking] = useState(true)
  const [authError, setAuthError] = useState('')
  const [expired, setExpired] = useState(false)
  const authRevision = useRef(0)
  const polling = useRef(false)
  const currentUser = useRef(user)
  currentUser.current = user
  const location = useLocation()
  const clearCache = () => { try { window.sessionStorage.removeItem('epicvm.portal.machines.v1') } catch { /* optional cache */ } }

  const checkUser = useCallback(async () => {
    const revision = ++authRevision.current
    try {
      const next = await me()
      if (revision !== authRevision.current) return
      if (currentUser.current && !next) { sessionChanged(); setExpired(true) }
      setUser(next)
      if (!next) clearCache()
      setAuthError('')
    } catch (error) {
      if (revision === authRevision.current) setAuthError('We could not check your sign-in. Check your connection and try again.')
    } finally {
      if (revision === authRevision.current) setChecking(false)
    }
  }, [])

  useEffect(() => {
    const expire = () => {
      ++authRevision.current
      clearCache()
      setUser(false); setExpired(true); setAuthError(''); setChecking(false)
    }
    window.addEventListener(SESSION_EXPIRED, expire)
    return () => { window.removeEventListener(SESSION_EXPIRED, expire); ++authRevision.current }
  }, [])

  useEffect(() => {
    checkUser()
    return () => { ++authRevision.current }
  }, [location.pathname, checkUser])

  useEffect(() => {
    if (!user || !['pending', 'approved'].includes(user.accountStatus || 'approved')) return
    const timer = window.setInterval(() => {
      if (polling.current) return
      polling.current = true
      checkUser().finally(() => { polling.current = false })
    }, 7000)
    return () => window.clearInterval(timer)
  }, [user && user.username, user && user.accountStatus, checkUser])

  if (/^\/(settings|Management)\/?$/i.test(location.pathname)) {
    return <AccountWorkspace management={location.pathname.toLowerCase().startsWith('/management')} />
  }

  if (checking) {
    return <div className="evm-loading" role="status">Loading…</div>
  }
  if (authError && user === null) {
    return <div className="evm-loading" role="alert"><p>{authError}</p><button className="evm-btn evm-btn-primary" onClick={checkUser}>Try again</button></div>
  }

  // Status gating for /portal/*: pending/rejected users get the status view, not the console.
  const status = user ? (user.accountStatus || 'approved') : 'anon'

  return (
    <Routes>
      <Route path="/signup" element={<Signup setUser={setUser} />} />
      <Route path="/signin" element={<Signin setUser={next => { ++authRevision.current; sessionChanged(); setUser(next); setExpired(false); setAuthError('') }} />} />
      <Route path="/pending" element={<Pending user={user} />} />
      <Route
        path="/portal"
        element={<PortalGate user={user} status={status} expired={expired}><Portal key={user?.username} user={user} onSignout={() => { setUser(false); window.location.assign('/EpicVM/') }} /></PortalGate>}
      />
      <Route
        path="/"
        element={<Landing authed={!!user} onSignout={() => { setUser(false); window.location.assign('/EpicVM/') }} />}
      />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}
