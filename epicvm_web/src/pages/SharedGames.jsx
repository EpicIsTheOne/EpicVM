import { Link } from 'react-router-dom'
import { requestLink } from '../desktopRequests'
import { reportDestination } from '../supportContext'
import React, { useEffect, useRef, useState } from 'react'
import { Desktop, GameController, Play, ArrowSquareOut } from '@phosphor-icons/react'
import { checkSessionResponse, sessionVersion } from '../session'
import { desktopStatus } from '../desktopStatus'
import { LAUNCH_TIMEOUT, launchStorage, stageText, saveLaunch, readLaunch, clearLaunch, watchLaunch } from '../launchProgress'

const API = '/EpicVM/api'
async function get(path) {
  const version = sessionVersion()
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 15000)
  try {
    const response = await fetch(API + path, { credentials: 'same-origin', cache: 'no-store', signal: controller.signal })
    checkSessionResponse(response, version)
    const body = await response.json()
    if (!response.ok || body.ok === false) throw new Error(body.error?.message || body.error || 'Game library unavailable.')
    return body
  } finally { clearTimeout(timeout) }
}

export function AvailableGames({ onAvailability, owner, desktopRequest }) {
  const [state, setState] = useState(null), [native, setNative] = useState(null)
  const [nativeDesktops, setNativeDesktops] = useState(null)
  const [error, setError] = useState(''), [pending, setPending] = useState(null)
  const [loaded, setLoaded] = useState(false), [failed, setFailed] = useState(false)
  const [checks, setChecks] = useState([0, 1, 2].map(() => ({ verified: false, checkedAt: null })))
  const [failureContext, setFailureContext] = useState(null)
  const [retry, setRetry] = useState(null), [ending, setEnding] = useState(null)
  const operation = useRef(null)
  const [clock, setClock] = useState(Date.now())
  useEffect(() => {
    if (!pending) return
    const timer = setInterval(() => setClock(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [Boolean(pending)])
  const endDialog = useRef(null)
  const [passwordRequest, setPasswordRequest] = useState(null)
  const passwordDialog = useRef(null)
  useEffect(() => { if (passwordRequest && !passwordDialog.current?.open) passwordDialog.current?.showModal() }, [passwordRequest])
  const refreshing = useRef(false)
  const generation = useRef(0)
  useEffect(() => {
    if (ending && !endDialog.current?.open) endDialog.current?.showModal()
  }, [ending])
  const refresh = async () => {
    if (refreshing.current) return
    refreshing.current = true
    const current = generation.current
    try {
      const results = await Promise.allSettled([
        get('/account/games'), get('/account/host-gaming'), get('/account/host-gaming/desktops'),
      ])
      if (current !== generation.current) return
      const setters = [setState, setNative, setNativeDesktops]
      results.forEach((result, i) => { if (result.status === 'fulfilled') setters[i](result.value) })
      setChecks(previous => results.map((result, i) => ({ verified: result.status === 'fulfilled', checkedAt: result.status === 'fulfilled' ? Date.now() : previous[i].checkedAt })))
      setFailed(results.some(result => result.status === 'rejected'))
      setLoaded(true)
    } finally { if (current === generation.current) refreshing.current = false }
  }
  useEffect(() => {
    refreshing.current = false
    refresh()
    const timer = setInterval(refresh, 10000)
    return () => { ++generation.current; clearInterval(timer); operation.current?.abort() }
  }, [])
  const machines = state?.machines || []
  const desktops = (nativeDesktops?.desktops || []).map(desktop => ({ ...desktop, check: checks[2] }))
  if (native?.desktopAccess && !desktops.some(d => d.hostId === native.hostId)) {
    desktops.unshift({ ...native, displayName: 'Personal desktop', check: checks[1] })
  }
  const hasResources = Boolean(machines.length || native?.games?.length || desktops.length)
  useEffect(() => { onAvailability?.({ loaded, hasResources, failed }) }, [loaded, hasResources, failed, onAvailability])

  useEffect(() => {
    const timer = setTimeout(() => {
      const saved = readLaunch(launchStorage(), owner)
      if (saved) void command('', {}, saved.key, saved.label, saved.connection, undefined, saved)
    }, 0)
    return () => clearTimeout(timer)
  }, [owner])

  async function command(path, payload, key, label, connection = 'internet', windowsPassword, restored) {
    if (operation.current) return
    const desktop = desktops.find(item => item.hostId === payload.hostId) || (native?.hostId === payload.hostId ? native : null)
    if (!restored && !path.endsWith('/stop') && desktop?.requiresWindowsPassword && windowsPassword === undefined) {
      setPasswordRequest({path, payload, key, label, connection, accountName: desktop.accountName || desktop.seat?.accountName})
      return
    }
    const controller = new AbortController()
    const launchGeneration = generation.current
    const version = sessionVersion()
    operation.current = controller
    let lastStage = 'preparing'
    const reportHost = restored?.hostId || payload.hostId
    const startedAt = restored?.startedAt || Date.now()
    setClock(Date.now())
    setPending({ key, label, startedAt, stage: 'preparing', stopping: path.endsWith('/stop') }); setError(''); setRetry(null); setFailureContext(null)
    const timeout = setTimeout(() => controller.abort(), path.endsWith('/stop') ? 120000 : Math.max(1, LAUNCH_TIMEOUT - (Date.now() - startedAt)))
    try {
      let body = restored ? { jobId: restored.jobId } : null
      if (!restored) {
        const sessionResponse = await fetch(API + '/account/session', { credentials: 'same-origin', cache: 'no-store', signal: controller.signal })
        checkSessionResponse(sessionResponse, version)
        const session = await sessionResponse.json()
        if (!sessionResponse.ok || !session.csrfToken) throw new Error('We could not verify your account. Check your connection and try again.')
        const response = await fetch(API + path, { method: 'POST', credentials: 'same-origin', signal: controller.signal,
          headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': session.csrfToken }, body: JSON.stringify({ ...payload, windowsPassword, async: !path.endsWith('/stop') }) })
        windowsPassword = undefined
        checkSessionResponse(response, version)
        body = await response.json()
        if (!response.ok || body.ok === false) throw new Error(body.error?.message || body.error || 'Could not complete the request.')
      }
      if (body.jobId) {
        const jobId = body.jobId
        setPending(previous => previous && ({ ...previous, resumable: true }))
        saveLaunch(launchStorage(), owner, { jobId, key, label, connection, startedAt, hostId: reportHost })
        body = await watchLaunch({ signal: controller.signal,
          onProgress: progress => {
            if (progress.stage) lastStage = progress.stage
            setPending(previous => previous && ({ ...previous, ...progress, startedAt: progress.startedAt || previous.startedAt }))
          },
          request: async () => {
            const poll = new AbortController()
            const abort = () => poll.abort()
            controller.signal.addEventListener('abort', abort, { once: true })
            if (controller.signal.aborted) poll.abort()
            const timer = setTimeout(() => poll.abort(), 15000)
            try {
              const status = await fetch(API + '/account/host-gaming/launch-jobs/' + encodeURIComponent(jobId), { credentials: 'same-origin', cache: 'no-store', signal: poll.signal })
              checkSessionResponse(status, version)
              if (status.status === 408 || status.status === 429 || status.status >= 500) {
                throw Object.assign(new Error('Connection interrupted'), { retryable: true })
              }
              const job = await status.json()
              if (!status.ok || job.ok === false) throw new Error(job.error?.message || job.error || 'Could not check your connection. Check status and try opening again.')
              return job
            } catch (error) {
              if (!controller.signal.aborted && (error instanceof TypeError || error.name === 'AbortError')) error.retryable = true
              throw error
            } finally {
              clearTimeout(timer)
              controller.signal.removeEventListener('abort', abort)
            }
          },
        })
      }
      if (controller.signal.aborted || generation.current !== launchGeneration || sessionVersion() !== version) throw new DOMException('Aborted', 'AbortError')
      if (!path.endsWith('/stop') && !body.launchUrl) throw new Error('No connection link was returned. Check status and try opening again.')
      clearLaunch(launchStorage())
      refresh()
      if (body.launchUrl) {
        const target = new URL(body.launchUrl, window.location.origin)
        if (connection === 'local') target.searchParams.set('connection', 'local')
        window.location.assign(target.href)
      }
    } catch (e) {
      if (generation.current !== launchGeneration) return
      clearLaunch(launchStorage())
      setFailureContext({ host: reportHost, connection, stage: lastStage, source: 'launch', time: new Date().toISOString() })
      setError(e.name === 'AbortError'
        ? 'We stopped waiting for a response. Your desktop may still be starting. Check status, then open or resume it again. Ending a session may also have completed; check its status before retrying.'
        : e.message)
      if (!restored && !path.endsWith('/stop')) setRetry({ path, payload, key, label, connection })
      refresh()
    } finally {
      windowsPassword = undefined
      clearTimeout(timeout)
      if (operation.current === controller) { operation.current = null; setPending(null) }
    }
  }
  const nativeDesktop = desktops.find(desktop => desktop.hostId === native?.hostId)
  const nativeStatus = desktopStatus(nativeDesktop || native || {}, checks[1].verified && (!nativeDesktop || nativeDesktop.check.verified))
  const vmGames = checks[0].verified ? machines.reduce((total, vm) => total + (vm.available ? (vm.games?.length || 0) : 0), 0) : 0
  const readyCount = vmGames + (nativeStatus.ready ? (native?.games?.filter(g => g.available).length || 0) : 0) + desktops.filter(d => desktopStatus(d, d.check.verified).ready).length
  const busy = Boolean(pending)
  const active = key => pending?.key === key
  return <details className="evm-shared-games" open><summary><span>Your desktops and games</span>{loaded && <small>{readyCount} ready to open</small>}</summary>
    <div className="evm-library-body">
      {pending && <div className="evm-launch-progress" role="status" aria-live="polite">
        <strong>{pending.stopping ? 'Ending' : 'Connecting to'} {pending.label}â€¦</strong>
        <p>{pending.stopping ? 'Closing apps and signing out of Windows.' : stageText[pending.stage] || stageText.preparing}</p>
        {!pending.stopping && <p>{pending.interrupted ? 'Connection interrupted. Your desktop may still be starting. Weâ€™re retrying the status check automatically.' : pending.resumable ? 'You can refresh this page. Weâ€™ll keep following this launch.' : 'First-time setup can take several minutes. Weâ€™ll check progress automatically.'}</p>}
        <small aria-live="off">Elapsed: {Math.floor(Math.max(0, clock - pending.startedAt) / 60000)}m {Math.floor(Math.max(0, clock - pending.startedAt) / 1000) % 60}s</small>
        <button className="evm-library-button-secondary" onClick={() => { clearLaunch(launchStorage()); operation.current?.abort() }}>Stop waiting</button>
        <small>Stops waiting in this browser. It does not cancel the request on the host.</small>
      </div>}
      {error && <div className="evm-library-error" role="alert"><p>{error}</p>
        <button className="evm-library-button-secondary" onClick={refresh}>Check status</button>
        <Link className="evm-library-button-secondary" to={reportDestination(failureContext)}>Report a problem</Link>
        {retry && <button className="evm-library-button-secondary" disabled={busy || failed} onClick={() => command(retry.path, retry.payload, retry.key, retry.label, retry.connection)}>Try opening again</button>}
      </div>}
      {failed && <p className="evm-library-error" role="status">Some statuses could not be verified. Previously loaded items stay visible, but actions pause until their status is checked. <button className="evm-link-btn" onClick={refresh}>Refresh status</button></p>}
      {!loaded && <p className="evm-library-empty" role="status">Loading your desktops and gamesâ€¦</p>}
      {!!desktops.length && <section className="evm-library-group" aria-label="Your desktops"><div className="evm-library-grid">
        {desktops.map(desktop => {
          const key = 'desktop-' + desktop.hostId, label = desktop.displayName || 'Personal desktop'
          const status = desktopStatus(desktop, desktop.check.verified)
          return <article key={key} className="evm-library-card evm-library-desktop" aria-busy={active(key)}>
            <div className="evm-library-card-top"><span className="evm-library-icon"><Desktop size={22} /></span><span className={`evm-library-status ${active(key) ? 'is-empty' : status.ready ? 'is-ready' : ''}`}>{active(key) ? pending.stopping ? 'Ending session' : 'Connecting' : status.label}</span></div>
            <h3>{label === 'Personal desktop' ? label : 'Personal desktop Â· ' + label}</h3>
            <p>Your Windows desktop, games, and apps in one place.</p>
            {(desktop.accountName || desktop.seat?.accountName) && <p className="evm-session-note">Windows account: <strong>{desktop.accountName || desktop.seat.accountName}</strong>{desktop.requiresWindowsPassword ? ' Â· Password required to connect' : ''}</p>}
            {status.message && <p className="evm-library-note" role="status">{status.message}{status.label === 'Needs recovery' && <> <a href="/EpicVM/settings">Ask Epic for help</a></>}</p>}
            {!desktop.check.verified && desktop.check.checkedAt && <small>Last checked: {new Date(desktop.check.checkedAt).toLocaleTimeString()}</small>}
            <div className="evm-library-actions">
              <button className="evm-library-button" disabled={busy || !status.ready} onClick={() => command('/account/host-gaming/desktop', { hostId: desktop.hostId }, key, label)}><Desktop size={16} />{active(key) ? pending.stopping ? 'Endingâ€¦' : 'Connectingâ€¦' : desktop.seat ? 'Resume desktop' : 'Open desktop'}</button>
              {desktop.localConnectionAvailable && <button className="evm-library-button-secondary" disabled={busy || !status.ready} onClick={() => command('/account/host-gaming/desktop', { hostId: desktop.hostId }, key, label, 'local')}>Open over local network</button>}
              {desktop.seat && <button className="evm-library-button-secondary" disabled={busy || !status.ready} onClick={() => setEnding({ desktop, key, label })}>End session</button>}
            </div>
            {desktop.localConnectionAvailable && <p className="evm-session-note">On the host PCâ€™s network? Use the local option. Both connections use this same desktop.</p>}
            {desktop.localConnection?.clientTrustRequired && <details className="evm-session-note"><summary>First local connection: trust this host certificate</summary><p>On the host network, open the <a href={desktop.localConnection.setupUrl} target="_blank" rel="noopener noreferrer">local certificate setup page</a>. Compare its SHA256 fingerprint with this value before installing it:</p><code style={{overflowWrap: 'anywhere'}}>{desktop.localConnection.certificateSha256}</code><p>Trust only a host you know. Install the certificate once on each device, then use Open over local network. Remove the certificate when you stop using this host. Your normal connection is available without this step.</p></details>}
            {desktop.seat && <p className="evm-session-note">To leave apps running, close the stream tab and use Resume desktop when you return. End session closes apps and signs out of Windows.</p>}
          </article>
        })}
      </div></section>}
      {!!native?.games?.length && <section className="evm-library-group" aria-label="Games on the host"><h3>Play a game</h3><div className="evm-library-grid">{native.games.map(game => {
        const key = 'game-' + game.id
        return <article key={key} className="evm-library-card" aria-busy={active(key)}><div className="evm-library-card-top"><span className="evm-library-icon"><GameController size={22} /></span><span className={`evm-library-status ${nativeStatus.ready && game.available ? 'is-ready' : ''}`}>{active(key) ? 'Connecting' : !checks[1].verified ? 'Status unverified' : nativeStatus.ready && game.available ? 'Ready' : nativeStatus.label === 'Ready' ? 'Unavailable' : nativeStatus.label}</span></div><h4>{game.title}</h4><p>Play on your hosted Windows desktop.</p>{nativeStatus.message && <p className="evm-library-note">{nativeStatus.message}</p>}<button className="evm-library-button" disabled={busy || !nativeStatus.ready || !game.available} onClick={() => command('/account/host-gaming/launch', { hostId: native.hostId, gameId: game.id }, key, game.title)}><Play size={16} />{active(key) ? 'Connectingâ€¦' : 'Play game'}</button></article>
      })}</div></section>}
      {!!machines.length && <div className="evm-library-grid">{machines.map((vm, index) => { const technicalName = /^EpicVM-.*Template/i.test(vm.name); return <article key={vm.resourceKey} className="evm-library-card"><div className="evm-library-card-top"><span className="evm-library-icon"><GameController size={22} /></span><span className={`evm-library-status ${checks[0].verified && vm.available ? (vm.games?.length ? 'is-ready' : 'is-empty') : ''}`}>{!checks[0].verified ? 'Status unverified' : !vm.available ? 'Unavailable' : vm.games?.length ? 'Games ready' : 'No games yet'}</span></div><h3>{technicalName ? `Gaming VM ${index + 1}` : vm.name}</h3>{technicalName && <small className="evm-library-technical">{vm.name}</small>}<p>A separate Windows computer for assigned games.</p>{checks[0].verified && vm.available && vm.games?.length ? <div className="evm-library-games">{vm.games.map(game => <div key={game.id} className="evm-library-game"><span>{game.title}</span><a href={'/dashboard/console/' + encodeURIComponent(vm.name) + '/?host_id=' + encodeURIComponent(vm.hostId)}>Open VM <ArrowSquareOut size={15} /></a></div>)}</div> : <p className="evm-library-note">{!checks[0].verified ? 'Refresh status to check this game host before opening it.' : vm.available ? 'Games assigned to this VM will appear here.' : 'The game host is currently unavailable.'}</p>}</article> })}</div>}
      {loaded && !hasResources && !failed && <p className="evm-library-empty">No desktops or games have been assigned yet. <Link className="evm-library-button-secondary" to={desktopRequest && ['pending', 'in_review'].includes(desktopRequest.status) ? requestLink(desktopRequest) : '/settings?request=desktop#request-form'}>{desktopRequest && ['pending', 'in_review'].includes(desktopRequest.status) ? 'View pending request' : 'Request desktop access'}</Link></p>}
    </div>
    {passwordRequest && <dialog ref={passwordDialog} className="evm-end-dialog" aria-labelledby="evm-password-title" onCancel={() => setPasswordRequest(null)}>
      <form onSubmit={event => {
        event.preventDefault()
        const next = passwordRequest
        const input = event.currentTarget.elements.windowsPassword
        const password = input.value
        input.value = ''
        setPasswordRequest(null)
        command(next.path, next.payload, next.key, next.label, next.connection, password)
      }}>
        <h2 id="evm-password-title">Unlock your Windows desktop</h2>
        <p>Windows account: {passwordRequest.accountName}</p>
        <p>Enter this accountâ€™s Windows password each time you open or resume it. Use the password, not a Windows Hello PIN. EpicVM does not save it.</p>
        <label>Windows password<input autoFocus name="windowsPassword" type="password" autoComplete="off" required maxLength={256} /></label>
        <div className="evm-library-actions"><button type="button" className="evm-library-button-secondary" onClick={() => setPasswordRequest(null)}>Cancel</button><button type="submit" className="evm-library-button">Connect</button></div>
      </form>
    </dialog>}
    {ending && <dialog ref={endDialog} className="evm-end-dialog" aria-labelledby="evm-end-title" onKeyDown={e => { if (e.key === 'Escape') { e.preventDefault(); setEnding(null) } }} onCancel={e => { e.preventDefault(); setEnding(null) }}>
      <h2 id="evm-end-title">End {ending.label}?</h2>
      <p>This closes running apps and signs you out of Windows. Unsaved work may be lost. Your saved files stay in your account.</p>
      <p>If you just want to leave, close the stream tab instead and resume your desktop later.</p>
      <div className="evm-library-actions"><button autoFocus className="evm-library-button-secondary" onClick={() => setEnding(null)}>Keep session</button><button className="evm-library-button" disabled={busy || !desktops.some(desktop => desktop.hostId === ending.desktop.hostId && desktopStatus(desktop, desktop.check.verified).ready)} onClick={() => { const next = ending; setEnding(null); command('/account/host-gaming/stop', { hostId: next.desktop.hostId }, next.key, next.label) }}>End session and close apps</button></div>
    </dialog>}
  </details>
}

export default function SharedGames({ resources = [], users = [], send, desktopRequester, onDesktopAssigned }) {
  const [library, setLibrary] = useState(null), [error, setError] = useState(''), [busy, setBusy] = useState(false)
  const [job, setJob] = useState(null), [vm, setVm] = useState(''), [ids, setIds] = useState([]), [adding, setAdding] = useState(false)
  const [mode, setMode] = useState('local'), [uploadProgress, setUploadProgress] = useState('')
  const [screening, setScreening] = useState(null), [screeningBusy, setScreeningBusy] = useState(false)
  const [nativeAdmin, setNativeAdmin] = useState(null), [nativeNotice, setNativeNotice] = useState('')
  const [desktopHosts, setDesktopHosts] = useState([]), [hostId, setHostId] = useState('')
  const [revealed, setRevealed] = useState(null)
  const assignmentPanel = useRef(null)
  const [assignmentUser, setAssignmentUser] = useState('')
  useEffect(() => { setAssignmentUser(desktopRequester?.realm === 'portal' ? desktopRequester.username : '') }, [desktopRequester])
  useEffect(() => { if (desktopRequester) assignmentPanel.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }) }, [desktopRequester])
  const refreshNative = () => hostId ? get('/management/host-gaming?hostId=' + encodeURIComponent(hostId)).then(setNativeAdmin).catch(e => setNativeNotice(e.message)) : Promise.resolve()
  const refresh = () => get('/management/games?hostId=' + hostId).then(next => {setLibrary(next);const active=next.jobs?.find(j => ['running','queued'].includes(j.state));if(active){setJob(active);setBusy(true)}}).catch(e => setError(e.message))
  useEffect(() => { get('/management/host-gaming/desktops').then(result => {
    setDesktopHosts(result.desktops || [])
    setHostId(current => current || result.desktops?.[0]?.hostId || '')
  }).catch(e => setNativeNotice(e.message)) }, [])
  useEffect(() => { setNativeAdmin(null); if (hostId) { refresh(); refreshNative() } }, [hostId])
  useEffect(() => {
    if (!hostId) return
    let disposed = false, busy = false
    async function poll() {
      if (busy || document.hidden) return
      busy = true
      try { const next = await get('/management/host-gaming?hostId=' + encodeURIComponent(hostId)); if (!disposed) setNativeAdmin(next) }
      catch (e) { if (!disposed) { setNativeAdmin(null); setNativeNotice('Hosting status unverified. ' + e.message) } }
      finally { busy = false }
    }
    const timer = setInterval(poll, 10000)
    window.addEventListener('focus', poll)
    return () => { disposed = true; clearInterval(timer); window.removeEventListener('focus', poll) }
  }, [hostId])
  async function nativeAction(path, payload) {
    setNativeNotice('')
    try { await send('/management/host-gaming/' + path, { ...payload, hostId }); await refreshNative(); setNativeNotice('Saved.'); if (desktopRequester && payload.username === desktopRequester.username && payload.enabled !== false && ['desktop-grants', 'local-account-assign'].includes(path)) onDesktopAssigned?.(payload.username) }
    catch (e) { setNativeNotice(e.message) }
  }
  async function revealSeatPassword(username) {
    setRevealed(null); setNativeNotice('')
    try {
      const result = await send('/management/host-gaming/account-credential/reveal', {hostId, username})
      setRevealed({username, accountName: result.accountName, password: result.password})
    } catch (e) { setNativeNotice(e.message) }
  }
  useEffect(() => {
    if (!job || ['complete', 'failed'].includes(job.state)) return
    const timer = setInterval(async () => {
      try {
        const result = await get(`/management/games/jobs/${job.id}?hostId=${hostId}`)
        if (['complete', 'failed'].includes(result.job.state)) { await refresh(); setBusy(false); if (result.job.error) setError(result.job.error) }
        setJob(result.job)
      } catch (e) { setError(e.message) }
    }, 2500)
    return () => clearInterval(timer)
  }, [job?.id, job?.state])
  async function run(payload) {
    setBusy(true); setError('')
    try { const result = await send('/management/games/jobs', { ...payload, hostId }); setJob(result.job) }
    catch (e) { setError(e.message); setBusy(false) }
  }
  async function add(event) {
    event.preventDefault()
    const fields = new FormData(event.currentTarget)
    const payload = { title: fields.get('title'), id: fields.get('id'), compatibility: fields.get('compatibility') || 'native' }
    if (mode === 'local') return run({ ...payload, action: 'import', sourcePath: fields.get('sourcePath') })
    if (mode === 'codex') return run({ ...payload, action: 'codex', gameName: fields.get('title') })
    if (mode === 'download') return run({ ...payload, action: 'download', url: fields.get('url'), sha256: fields.get('sha256'), subfolder: fields.get('subfolder') })
    setBusy(true); setError('')
    try {
      const file = fields.get('archive')
      if (!file?.size) throw new Error('Choose a ZIP distribution.')
      // Read only one chunk at a time; large packages do not fill browser memory.
      let uploadId = '', offset = 0
      while (offset < file.size) {
        const bytes = new Uint8Array(await file.slice(offset, offset + 192 * 1024).arrayBuffer())
        let binary = ''; for (const byte of bytes) binary += String.fromCharCode(byte)
        const result = await send('/management/games/upload', { hostId, uploadId, offset, chunk: btoa(binary) })
        uploadId = result.uploadId; offset = result.offset
        setUploadProgress(`${Math.floor(offset / file.size * 100)}% uploaded`)
      }
      await run({ ...payload, action: 'archive', uploadId, sha256: fields.get('sha256'), subfolder: fields.get('subfolder') })
    } catch (e) { setError(e.message); setBusy(false) }
  }
  async function screenGame(event) {
    const fields = new FormData(event.currentTarget.closest('form'))
    setScreeningBusy(true); setScreening(null)
    try {
      const evidence = {mode, title:fields.get('title'), sourcePath:fields.get('sourcePath'), url:fields.get('url'), archiveName:fields.get('archive')?.name, subfolder:fields.get('subfolder'), compatibility:fields.get('compatibility')}
      const result = await send('/management/jev/analyze', {task:'game_screening', state:{structuralEvidence:evidence}})
      setScreening(result.advisory)
    } catch (e) { setScreening({error:e.message}) }
    setScreeningBusy(false)
  }
  return <section className="aw-card"><div className="aw-row"><h2>Shared games</h2><button onClick={() => setAdding(!adding)}>Add Game</button><button onClick={refresh}>Refresh games</button></div>
    <p>Share game content with selected machines. Accounts, saves, and launcher sessions stay inside each VM.</p>
    <details ref={assignmentPanel} open={desktopRequester ? true : undefined}><summary>Native game sessions</summary>
      <p>Register machine-wide game installations and assign them to approved accounts. Each account gets an isolated Windows session.</p>
      {nativeNotice && <p role="status">{nativeNotice}</p>}
      {desktopRequester && <p role="status">Assigning desktop access for <strong>{desktopRequester.username}</strong>.{users.some(user => user.username === desktopRequester.username && user.accountStatus === 'approved') ? ' Choose a host and account below.' : ' Approve this account in Accounts first.'}</p>}
      {desktopRequester && nativeAdmin?.desktopGrants?.some(grant => grant.username === desktopRequester.username && grant.realm === 'portal') && <p>This desktop is already assigned. <button type="button" onClick={() => onDesktopAssigned?.(desktopRequester.username)}>Return to request</button></p>}
      <label>MultiSeat Windows desktop<select value={hostId} onChange={e => setHostId(e.target.value)} disabled={!desktopHosts.length}><option value="">Choose a desktop</option>{desktopHosts.map(host => <option key={host.hostId} value={host.hostId}>{host.displayName}</option>)}</select></label>
      {!desktopHosts.length && <p>No available MultiSeat Windows desktops.</p>}
      <p role="status">Host: {nativeAdmin?.ready ? nativeAdmin.hosting?.paused ? 'Hosting paused' : nativeAdmin.hosting?.full ? 'Host full' : 'Ready' : 'Unavailable'} Â· Seats in use: {nativeAdmin?.hosting?.seatCount ?? nativeAdmin?.seats?.length ?? 0}{nativeAdmin?.hosting && <> Â· Session limit: {nativeAdmin.hosting.maxSeats > 0 ? nativeAdmin.hosting.maxSeats : 'Unlimited'}{(nativeAdmin.hosting.paused || nativeAdmin.hosting.full) && ' Â· Existing desktops can still resume.'}</>}</p>
      <form onSubmit={e => { e.preventDefault(); const f = new FormData(e.currentTarget); nativeAction('games', { id: f.get('id'), title: f.get('title'), executable: f.get('executable') }) }}>
        <label>Game ID<input name="id" required pattern="[a-z0-9][a-z0-9-]{0,63}" /></label>
        <label>Title<input name="title" required /></label>
        <label>Installed executable<input name="executable" required placeholder="C:\Program Files\Game\game.exe" /></label>
        <button type="submit">Add native game</button>
      </form>
      <form onSubmit={e => { e.preventDefault(); const f = new FormData(e.currentTarget); nativeAction('grants', { username: f.get('username'), gameId: f.get('gameId'), enabled: true }) }}>
        <label>Approved account<input name="username" required /></label>
        <label>Game<select name="gameId" required>{nativeAdmin?.games?.map(game => <option value={game.id} key={game.id}>{game.title}</option>)}</select></label>
        <button type="submit">Assign game</button>
      </form>
      <form onSubmit={e => { e.preventDefault(); const f = new FormData(e.currentTarget); nativeAction('desktop-grants', {username: f.get('username'), enabled: true}) }}>
        <label>Approved account for personal desktop<select key={desktopRequester?.id || hostId} name="username" required value={users.some(user => user.username === assignmentUser && user.accountStatus === 'approved' && !user.disabled) ? assignmentUser : ''} onChange={e => setAssignmentUser(e.target.value)}><option value="" disabled>Choose an account</option>{users.filter(user => user.accountStatus === 'approved' && !user.disabled && !nativeAdmin?.desktopGrants?.some(grant => grant.realm === 'portal' && grant.username === user.username)).map(user => <option key={user.username} value={user.username}>{user.username}</option>)}</select></label>
        <button type="submit" disabled={!hostId || !nativeAdmin || !users.some(user => user.username === assignmentUser && user.accountStatus === 'approved' && !user.disabled) || nativeAdmin.desktopGrants?.some(grant => grant.username === assignmentUser && grant.realm === 'portal')}>Assign personal desktop</button>
      </form>
      {nativeAdmin?.supportsExistingLocalAccounts && <form onSubmit={e => { e.preventDefault(); const f = new FormData(e.currentTarget); nativeAction('local-account-assign', {username: f.get('username'), accountSid: f.get('accountSid')}) }}>
        <label>Portal account<select key={desktopRequester?.id || hostId} name="username" required value={users.some(user => user.username === assignmentUser && user.accountStatus === 'approved' && !user.disabled) ? assignmentUser : ''} onChange={e => setAssignmentUser(e.target.value)}><option value="" disabled>Choose an account</option>{users.filter(user => user.accountStatus === 'approved' && !user.disabled).map(user => <option key={user.username} value={user.username}>{user.username}</option>)}</select></label>
        <label>Windows account<select name="accountSid" defaultValue=""><option value="">Use an EpicVM-created account</option>{nativeAdmin.localAccounts?.map(account => <option key={account.accountSid} value={account.accountSid}>{account.accountName} (existing local account)</option>)}</select></label>
        <p>Existing accounts require their Windows password for every open or resume. End affected desktop sessions before changing this assignment. Accounts and saved files are preserved.</p>
        <button type="submit" disabled={!nativeAdmin || !users.some(user => user.username === assignmentUser && user.accountStatus === 'approved' && !user.disabled)}>Assign Windows account and desktop access</button>
      </form>}
      {nativeAdmin?.desktopGrants?.map(grant => <div className="aw-row" key={grant.realm + ':' + grant.username}><span>{grant.username} Â· {grant.accountName || 'EpicVM desktop'} Â· {desktopHosts.find(host => host.hostId === grant.host_id)?.displayName || grant.host_id}{grant.requiresWindowsPassword ? ' Â· Windows password required' : ''}</span>{nativeAdmin.supportsCredentialReveal && !grant.requiresWindowsPassword && <button onClick={() => revealSeatPassword(grant.username)}>Reveal password</button>}<button onClick={() => nativeAction('desktop-grants', {username: grant.username, enabled: false})}>Remove desktop access</button></div>)}
      {nativeAdmin?.supportsCredentialReveal && !!nativeAdmin.credentialOwners?.length && <form onSubmit={e => { e.preventDefault(); revealSeatPassword(new FormData(e.currentTarget).get('username')) }}>
        <label>EpicVM-created account owner<select name="username" required>{nativeAdmin.credentialOwners.map(username => <option value={username} key={username}>{username}</option>)}</select></label><button type="submit">Reveal seat password</button>
      </form>}
      {revealed && <div role="status"><p>{revealed.username} Â· {revealed.accountName}</p><p>Windows password: <code>{revealed.password}</code></p><button onClick={() => setRevealed(null)}>Hide password</button></div>}
      {nativeAdmin?.games?.map(game => <div className="aw-row" key={game.id}><span>{game.title} Â· {game.available ? 'Installed' : 'Missing'}</span>{nativeAdmin.supportsRecovery && <button onClick={() => nativeAction('games/remove', { gameId: game.id })}>Remove from catalog</button>}</div>)}
      {nativeAdmin?.supportsRecovery && nativeAdmin.streams?.map(stream => <div className="aw-row" key={stream.name}><span>{stream.username} Â· {stream.accountName || stream.name}{stream.requiresWindowsPassword ? ' Â· Existing local account' : ''}</span>{nativeAdmin.supportsCredentialReveal && stream.realm === 'portal' && !stream.requiresWindowsPassword && <button onClick={() => revealSeatPassword(stream.username)}>Reveal password</button>}<button onClick={() => nativeAction('recover', { owner: stream.realm + ':' + stream.username })}>End and recover seat</button></div>)}
      {nativeAdmin?.seats?.map(seat => <div className="aw-row" key={seat.id}><span>{seat.accountName || 'Seat ' + seat.id.slice(0, 8)} Â· {seat.status}{seat.epicvmOwned === false ? ' Â· Not assigned to EpicVM' : ''}{seat.errorMessage ? ' Â· ' + seat.errorMessage : ''}</span>{nativeAdmin.supportsRecovery && seat.epicvmOwned !== false && <button onClick={() => nativeAction('recover', { seatId: seat.id })}>End and recover desktop</button>}</div>)}
    </details>
    {error && <p role="alert" className="aw-error">{error}</p>}{job && <p role="status">{job.action}: {job.state}{job.state === 'complete' ? '. Ready.' : ''}</p>}
    {adding && <form onSubmit={add}>
      <h3>Add a game</h3><label>Source<select value={mode} onChange={e => setMode(e.target.value)}><option value="local">Existing host installation</option><option value="upload">Upload ZIP distribution</option><option value="download">Download ZIP distribution</option><option value="codex">Ask Codex to prepare a recipe</option></select></label><label>Game name<input name="title" required maxLength={120} /></label>
      <label>Game ID<input name="id" required pattern="[a-z0-9][a-z0-9-]{0,63}" placeholder="my-game" /></label>
      {mode === 'local' && <label>Installation folder on the host<input name="sourcePath" required placeholder="D:\Games\My Game" /></label>}
      {mode === 'local' && <label>Graphics compatibility<select name="compatibility" defaultValue="native"><option value="native">Use the game's native graphics</option><option value="mesa-software">Software OpenGL fallback (slower)</option></select></label>}
      {mode === 'upload' && <label>Game distribution<input name="archive" type="file" accept=".zip" required /></label>}
      {mode === 'download' && <label>Official distribution URL<input name="url" type="url" required placeholder="https://publisher.example/game.zip" /></label>}
      {['upload','download'].includes(mode) && <><label>Distribution SHA-256<input name="sha256" required pattern="[a-fA-F0-9]{64}" /></label><label>Game folder inside ZIP (optional)<input name="subfolder" /></label></>}
      <p>{mode === 'codex' ? 'Use this fallback when existing recipes and automated distribution setup cannot handle the game. Codex prepares reusable setup knowledge; it does not use your game accounts.' : 'EpicVM detects supported package layouts and excludes personal data. Unsupported installations require a reviewed recipe.'}</p><div className="aw-row"><button type="button" disabled={screeningBusy} onClick={screenGame}>{screeningBusy ? 'Screeningâ€¦' : 'Screen layout with Jev'}</button><button disabled={busy}>{mode === 'codex' ? 'Request Codex setup' : 'Inspect and add game'}</button></div>{screening?.error ? <p role="status">{screening.error}</p> : screening?.answers?.family ? <p role="status"><strong>Jev candidate:</strong> {String(screening.answers.family.choice || '').replaceAll('_',' ')}. EpicVM's deterministic inspector still decides support and excludes personal data.</p> : null}{uploadProgress && <p role="status">{uploadProgress}</p>}</form>}
    {!library ? <p>Loading libraryâ€¦</p> : <><ul>{library.games.map(game => <li key={game.id}><strong>{game.title}</strong> Â· {(game.sizeBytes / 1024 ** 3).toFixed(1)} GB {game.compatibility === 'mesa-software' && <small>Software OpenGL compatibility</small>} <button disabled={busy} onClick={() => run({ action: 'update', id: game.id })}>Refresh from host installation</button></li>)}</ul>
      {!!library.legacyGames?.length && <details><summary>Earlier library entries</summary><p>These use the earlier shared library. Import supported installation folders to manage their VM assignments here.</p><ul>{library.legacyGames.map(game => <li key={game.id}>{game.title} Â· {game.status}</li>)}</ul></details>}
      {!library.games.length && <p>No shared games yet.</p>}<h3>Games assigned to a VM</h3>
      <label>Gaming machine<select value={vm} disabled={busy} onChange={e => {setVm(e.target.value);setIds(library?.assignments?.[e.target.value]?.gameIds || [])}}><option value="">Select a machine</option>{resources.filter(r => r.hostId === hostId && r.resourceType === 'vm').map(r => <option key={r.resourceKey} value={r.name}>{r.name}</option>)}</select></label>
      {vm && <><div>{library.games.map(game => <label className="aw-toggle" key={game.id}><input type="checkbox" disabled={busy} checked={ids.includes(game.id)} onChange={e => setIds(e.target.checked ? [...ids, game.id] : ids.filter(id => id !== game.id))} />{game.title}</label>)}</div>
      <button disabled={busy} onClick={() => run({ action: 'assign', vmName: vm, gameIds: ids })}>Apply games to VM</button><p>The VM must be running. Applying also installs the latest prepared releases; existing saves stay local.</p></>}</>}
  </section>
}
