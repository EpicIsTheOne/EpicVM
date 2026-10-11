import React, { useEffect, useRef, useState } from 'react'
import { Desktop, GameController, Play, ArrowSquareOut } from '@phosphor-icons/react'
import { checkSessionResponse, sessionVersion } from '../session'
import { desktopStatus } from '../desktopStatus'

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

export function AvailableGames({ onAvailability }) {
  const [state, setState] = useState(null), [native, setNative] = useState(null)
  const [nativeDesktops, setNativeDesktops] = useState(null)
  const [error, setError] = useState(''), [pending, setPending] = useState(null)
  const [loaded, setLoaded] = useState(false), [failed, setFailed] = useState(false)
  const [checks, setChecks] = useState([0, 1, 2].map(() => ({ verified: false, checkedAt: null })))
  const [retry, setRetry] = useState(null), [ending, setEnding] = useState(null)
  const operation = useRef(null)
  const endDialog = useRef(null)
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

  async function command(path, payload, key, label, connection = 'internet') {
    if (operation.current) return
    const controller = new AbortController()
    const version = sessionVersion()
    operation.current = controller
    setPending({ key, label, stopping: path.endsWith('/stop') }); setError(''); setRetry(null)
    const timeout = setTimeout(() => controller.abort(), path.endsWith('/stop') ? 120000 : 600000)
    try {
      const sessionResponse = await fetch(API + '/account/session', { credentials: 'same-origin', cache: 'no-store', signal: controller.signal })
      checkSessionResponse(sessionResponse, version)
      const session = await sessionResponse.json()
      if (!sessionResponse.ok || !session.csrfToken) throw new Error('We could not verify your account. Check your connection and try again.')
      const response = await fetch(API + path, { method: 'POST', credentials: 'same-origin', signal: controller.signal,
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': session.csrfToken }, body: JSON.stringify({ ...payload, async: !path.endsWith('/stop') }) })
      checkSessionResponse(response, version)
      let body = await response.json()
      if (!response.ok || body.ok === false) throw new Error(body.error?.message || body.error || 'Could not complete the request.')
      if (body.jobId) {
        const jobId = body.jobId
        while (true) {
          await new Promise((resolve, reject) => {
            if (controller.signal.aborted) return reject(new DOMException('Aborted', 'AbortError'))
            const abort = () => { clearTimeout(timer); reject(new DOMException('Aborted', 'AbortError')) }
            const timer = setTimeout(() => { controller.signal.removeEventListener('abort', abort); resolve() }, 2000)
            controller.signal.addEventListener('abort', abort, { once: true })
          })
          const status = await fetch(API + '/account/host-gaming/launch-jobs/' + encodeURIComponent(jobId), { credentials: 'same-origin', cache: 'no-store', signal: controller.signal })
          checkSessionResponse(status, version)
          const job = await status.json()
          if (!status.ok || job.ok === false) throw new Error(job.error || 'Could not check your connection. Check status and try opening again.')
          if (job.state === 'running') continue
          body = job.result || {}
          if (job.state !== 'ready' || body.ok === false) throw new Error(body.error?.message || body.error || 'Could not prepare your desktop connection.')
          break
        }
      }
      if (!path.endsWith('/stop') && !body.launchUrl) throw new Error('No connection link was returned. Check status and try opening again.')
      refresh()
      if (body.launchUrl) window.location.assign(body.launchUrl + (connection === 'local' ? '?connection=local' : ''))
    } catch (e) {
      setError(e.name === 'AbortError'
        ? 'We stopped waiting for a response. Your desktop may still be starting. Check status, then open or resume it again. Ending a session may also have completed; check its status before retrying.'
        : e.message)
      if (!path.endsWith('/stop')) setRetry({ path, payload, key, label, connection })
      refresh()
    } finally {
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
        <strong>{pending.stopping ? 'Ending' : 'Connecting to'} {pending.label}…</strong>
        <p>{pending.stopping ? 'Closing apps and signing out of Windows.' : 'Getting your connection ready. First-time setup can take several minutes. This page checks progress automatically and reuses your existing desktop when available.'}</p>
        <button className="evm-library-button-secondary" onClick={() => operation.current?.abort()}>Stop waiting</button>
        <small>Stops waiting in this browser. It does not cancel the request on the host.</small>
      </div>}
      {error && <div className="evm-library-error" role="alert"><p>{error}</p>
        <button className="evm-library-button-secondary" onClick={refresh}>Check status</button>
        {retry && <button className="evm-library-button-secondary" disabled={busy || failed} onClick={() => command(retry.path, retry.payload, retry.key, retry.label, retry.connection)}>Try opening again</button>}
      </div>}
      {failed && <p className="evm-library-error" role="status">Some statuses could not be verified. Previously loaded items stay visible, but actions pause until their status is checked. <button className="evm-link-btn" onClick={refresh}>Refresh status</button></p>}
      {!loaded && <p className="evm-library-empty" role="status">Loading your desktops and games…</p>}
      {!!desktops.length && <section className="evm-library-group" aria-label="Your desktops"><div className="evm-library-grid">
        {desktops.map(desktop => {
          const key = 'desktop-' + desktop.hostId, label = desktop.displayName || 'Personal desktop'
          const status = desktopStatus(desktop, desktop.check.verified)
          return <article key={key} className="evm-library-card evm-library-desktop" aria-busy={active(key)}>
            <div className="evm-library-card-top"><span className="evm-library-icon"><Desktop size={22} /></span><span className={`evm-library-status ${active(key) ? 'is-empty' : status.ready ? 'is-ready' : ''}`}>{active(key) ? pending.stopping ? 'Ending session' : 'Connecting' : status.label}</span></div>
            <h3>{label === 'Personal desktop' ? label : 'Personal desktop · ' + label}</h3>
            <p>Your Windows desktop, games, and apps in one place.</p>
            {status.message && <p className="evm-library-note" role="status">{status.message}{status.label === 'Needs recovery' && <> <a href="/EpicVM/settings">Ask Epic for help</a></>}</p>}
            {!desktop.check.verified && desktop.check.checkedAt && <small>Last checked: {new Date(desktop.check.checkedAt).toLocaleTimeString()}</small>}
            <div className="evm-library-actions">
              <button className="evm-library-button" disabled={busy || !status.ready} onClick={() => command('/account/host-gaming/desktop', { hostId: desktop.hostId }, key, label)}><Desktop size={16} />{active(key) ? pending.stopping ? 'Ending…' : 'Connecting…' : desktop.seat ? 'Resume desktop' : 'Open desktop'}</button>
              {desktop.localConnectionAvailable && <button className="evm-library-button-secondary" disabled={busy || !status.ready} onClick={() => command('/account/host-gaming/desktop', { hostId: desktop.hostId }, key, label, 'local')}>Open over local network</button>}
              {desktop.seat && <button className="evm-library-button-secondary" disabled={busy || !status.ready} onClick={() => setEnding({ desktop, key, label })}>End session</button>}
            </div>
            {desktop.localConnectionAvailable && <p className="evm-session-note">On the host PC’s network? Use the local option. Both connections use this same desktop.</p>}
            {desktop.seat && <p className="evm-session-note">To leave apps running, close the stream tab and use Resume desktop when you return. End session closes apps and signs out of Windows.</p>}
          </article>
        })}
      </div></section>}
      {!!native?.games?.length && <section className="evm-library-group" aria-label="Games on the host"><h3>Play a game</h3><div className="evm-library-grid">{native.games.map(game => {
        const key = 'game-' + game.id
        return <article key={key} className="evm-library-card" aria-busy={active(key)}><div className="evm-library-card-top"><span className="evm-library-icon"><GameController size={22} /></span><span className={`evm-library-status ${nativeStatus.ready && game.available ? 'is-ready' : ''}`}>{active(key) ? 'Connecting' : !checks[1].verified ? 'Status unverified' : nativeStatus.ready && game.available ? 'Ready' : nativeStatus.label === 'Ready' ? 'Unavailable' : nativeStatus.label}</span></div><h4>{game.title}</h4><p>Play on your hosted Windows desktop.</p>{nativeStatus.message && <p className="evm-library-note">{nativeStatus.message}</p>}<button className="evm-library-button" disabled={busy || !nativeStatus.ready || !game.available} onClick={() => command('/account/host-gaming/launch', { hostId: native.hostId, gameId: game.id }, key, game.title)}><Play size={16} />{active(key) ? 'Connecting…' : 'Play game'}</button></article>
      })}</div></section>}
      {!!machines.length && <div className="evm-library-grid">{machines.map((vm, index) => { const technicalName = /^EpicVM-.*Template/i.test(vm.name); return <article key={vm.resourceKey} className="evm-library-card"><div className="evm-library-card-top"><span className="evm-library-icon"><GameController size={22} /></span><span className={`evm-library-status ${checks[0].verified && vm.available ? (vm.games?.length ? 'is-ready' : 'is-empty') : ''}`}>{!checks[0].verified ? 'Status unverified' : !vm.available ? 'Unavailable' : vm.games?.length ? 'Games ready' : 'No games yet'}</span></div><h3>{technicalName ? `Gaming VM ${index + 1}` : vm.name}</h3>{technicalName && <small className="evm-library-technical">{vm.name}</small>}<p>A separate Windows computer for assigned games.</p>{checks[0].verified && vm.available && vm.games?.length ? <div className="evm-library-games">{vm.games.map(game => <div key={game.id} className="evm-library-game"><span>{game.title}</span><a href={'/dashboard/console/' + encodeURIComponent(vm.name) + '/?host_id=' + encodeURIComponent(vm.hostId)}>Open VM <ArrowSquareOut size={15} /></a></div>)}</div> : <p className="evm-library-note">{!checks[0].verified ? 'Refresh status to check this game host before opening it.' : vm.available ? 'Games assigned to this VM will appear here.' : 'The game host is currently unavailable.'}</p>}</article> })}</div>}
      {loaded && !hasResources && !failed && <p className="evm-library-empty">No desktops or games have been assigned yet. You can ask Epic for access from Settings.</p>}
    </div>
    {ending && <dialog ref={endDialog} className="evm-end-dialog" aria-labelledby="evm-end-title" onKeyDown={e => { if (e.key === 'Escape') { e.preventDefault(); setEnding(null) } }} onCancel={e => { e.preventDefault(); setEnding(null) }}>
      <h2 id="evm-end-title">End {ending.label}?</h2>
      <p>This closes running apps and signs you out of Windows. Unsaved work may be lost. Your saved files stay in your account.</p>
      <p>If you just want to leave, close the stream tab instead and resume your desktop later.</p>
      <div className="evm-library-actions"><button autoFocus className="evm-library-button-secondary" onClick={() => setEnding(null)}>Keep session</button><button className="evm-library-button" disabled={busy || !desktops.some(desktop => desktop.hostId === ending.desktop.hostId && desktopStatus(desktop, desktop.check.verified).ready)} onClick={() => { const next = ending; setEnding(null); command('/account/host-gaming/stop', { hostId: next.desktop.hostId }, next.key, next.label) }}>End session and close apps</button></div>
    </dialog>}
  </details>
}

export default function SharedGames({ resources = [], users = [], send }) {
  const [library, setLibrary] = useState(null), [error, setError] = useState(''), [busy, setBusy] = useState(false)
  const [job, setJob] = useState(null), [vm, setVm] = useState(''), [ids, setIds] = useState([]), [adding, setAdding] = useState(false)
  const [mode, setMode] = useState('local'), [uploadProgress, setUploadProgress] = useState('')
  const [screening, setScreening] = useState(null), [screeningBusy, setScreeningBusy] = useState(false)
  const [nativeAdmin, setNativeAdmin] = useState(null), [nativeNotice, setNativeNotice] = useState('')
  const [desktopHosts, setDesktopHosts] = useState([]), [hostId, setHostId] = useState('')
  const [revealed, setRevealed] = useState(null)
  const refreshNative = () => hostId ? get('/management/host-gaming?hostId=' + encodeURIComponent(hostId)).then(setNativeAdmin).catch(e => setNativeNotice(e.message)) : Promise.resolve()
  const refresh = () => get('/management/games?hostId=' + hostId).then(next => {setLibrary(next);const active=next.jobs?.find(j => ['running','queued'].includes(j.state));if(active){setJob(active);setBusy(true)}}).catch(e => setError(e.message))
  useEffect(() => { get('/management/host-gaming/desktops').then(result => {
    setDesktopHosts(result.desktops || [])
    setHostId(current => current || result.desktops?.[0]?.hostId || '')
  }).catch(e => setNativeNotice(e.message)) }, [])
  useEffect(() => { setNativeAdmin(null); if (hostId) { refresh(); refreshNative() } }, [hostId])
  async function nativeAction(path, payload) {
    setNativeNotice('')
    try { await send('/management/host-gaming/' + path, { ...payload, hostId }); await refreshNative(); setNativeNotice('Saved.') }
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
    <details><summary>Native game sessions</summary>
      <p>Register machine-wide game installations and assign them to approved accounts. Each account gets an isolated Windows session.</p>
      {nativeNotice && <p role="status">{nativeNotice}</p>}
      <label>MultiSeat Windows desktop<select value={hostId} onChange={e => setHostId(e.target.value)} disabled={!desktopHosts.length}><option value="">Choose a desktop</option>{desktopHosts.map(host => <option key={host.hostId} value={host.hostId}>{host.displayName}</option>)}</select></label>
      {!desktopHosts.length && <p>No available MultiSeat Windows desktops.</p>}
      <p>Host: {nativeAdmin?.ready ? 'Ready' : 'Unavailable'} · Active seats: {nativeAdmin?.seats?.length || 0}</p>
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
        <label>Approved account for personal desktop<select name="username" required defaultValue=""><option value="" disabled>Choose an account</option>{users.filter(user => user.accountStatus === 'approved' && !nativeAdmin?.desktopGrants?.some(grant => grant.realm === 'portal' && grant.username === user.username)).map(user => <option key={user.username} value={user.username}>{user.username}</option>)}</select></label>
        <button type="submit" disabled={!hostId}>Assign personal desktop</button>
      </form>
      {nativeAdmin?.desktopGrants?.map(grant => <div className="aw-row" key={grant.realm + ':' + grant.username}><span>{grant.username} · Your Personal Desktop · {desktopHosts.find(host => host.hostId === grant.host_id)?.displayName || grant.host_id}</span>{nativeAdmin.supportsCredentialReveal && <button onClick={() => revealSeatPassword(grant.username)}>Reveal password</button>}<button onClick={() => nativeAction('desktop-grants', {username: grant.username, enabled: false})}>Remove desktop access</button></div>)}
      {nativeAdmin?.supportsCredentialReveal && <form onSubmit={e => { e.preventDefault(); revealSeatPassword(new FormData(e.currentTarget).get('username')) }}>
        <label>Seat account owner<input name="username" required /></label><button type="submit">Reveal seat password</button>
      </form>}
      {revealed && <div role="status"><p>{revealed.username} · {revealed.accountName}</p><p>Windows password: <code>{revealed.password}</code></p><button onClick={() => setRevealed(null)}>Hide password</button></div>}
      {nativeAdmin?.games?.map(game => <div className="aw-row" key={game.id}><span>{game.title} · {game.available ? 'Installed' : 'Missing'}</span>{nativeAdmin.supportsRecovery && <button onClick={() => nativeAction('games/remove', { gameId: game.id })}>Remove from catalog</button>}</div>)}
      {nativeAdmin?.supportsRecovery && nativeAdmin.streams?.map(stream => <div className="aw-row" key={stream.name}><span>{stream.username} · {stream.name}</span>{nativeAdmin.supportsCredentialReveal && stream.realm === 'portal' && <button onClick={() => revealSeatPassword(stream.username)}>Reveal password</button>}<button onClick={() => nativeAction('recover', { owner: stream.realm + ':' + stream.username })}>End and recover seat</button></div>)}
      {nativeAdmin?.seats?.map(seat => <div className="aw-row" key={seat.id}><span>Seat {seat.id.slice(0, 8)} · {seat.status}{seat.errorMessage ? ' · ' + seat.errorMessage : ''}</span>{nativeAdmin.supportsRecovery && <button onClick={() => nativeAction('recover', { seatId: seat.id })}>Recover seat</button>}</div>)}
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
      <p>{mode === 'codex' ? 'Use this fallback when existing recipes and automated distribution setup cannot handle the game. Codex prepares reusable setup knowledge; it does not use your game accounts.' : 'EpicVM detects supported package layouts and excludes personal data. Unsupported installations require a reviewed recipe.'}</p><div className="aw-row"><button type="button" disabled={screeningBusy} onClick={screenGame}>{screeningBusy ? 'Screening…' : 'Screen layout with Jev'}</button><button disabled={busy}>{mode === 'codex' ? 'Request Codex setup' : 'Inspect and add game'}</button></div>{screening?.error ? <p role="status">{screening.error}</p> : screening?.answers?.family ? <p role="status"><strong>Jev candidate:</strong> {String(screening.answers.family.choice || '').replaceAll('_',' ')}. EpicVM's deterministic inspector still decides support and excludes personal data.</p> : null}{uploadProgress && <p role="status">{uploadProgress}</p>}</form>}
    {!library ? <p>Loading library…</p> : <><ul>{library.games.map(game => <li key={game.id}><strong>{game.title}</strong> · {(game.sizeBytes / 1024 ** 3).toFixed(1)} GB {game.compatibility === 'mesa-software' && <small>Software OpenGL compatibility</small>} <button disabled={busy} onClick={() => run({ action: 'update', id: game.id })}>Refresh from host installation</button></li>)}</ul>
      {!!library.legacyGames?.length && <details><summary>Earlier library entries</summary><p>These use the earlier shared library. Import supported installation folders to manage their VM assignments here.</p><ul>{library.legacyGames.map(game => <li key={game.id}>{game.title} · {game.status}</li>)}</ul></details>}
      {!library.games.length && <p>No shared games yet.</p>}<h3>Games assigned to a VM</h3>
      <label>Gaming machine<select value={vm} disabled={busy} onChange={e => {setVm(e.target.value);setIds(library?.assignments?.[e.target.value]?.gameIds || [])}}><option value="">Select a machine</option>{resources.filter(r => r.hostId === hostId && r.resourceType === 'vm').map(r => <option key={r.resourceKey} value={r.name}>{r.name}</option>)}</select></label>
      {vm && <><div>{library.games.map(game => <label className="aw-toggle" key={game.id}><input type="checkbox" disabled={busy} checked={ids.includes(game.id)} onChange={e => setIds(e.target.checked ? [...ids, game.id] : ids.filter(id => id !== game.id))} />{game.title}</label>)}</div>
      <button disabled={busy} onClick={() => run({ action: 'assign', vmName: vm, gameIds: ids })}>Apply games to VM</button><p>The VM must be running. Applying also installs the latest prepared releases; existing saves stay local.</p></>}</>}
  </section>
}
