// Isolated HTTP fixture for the approved browser wrapper. No browser API here.
import http from 'node:http'
import fs from 'node:fs/promises'
import path from 'node:path'

const build = path.resolve(process.env.EPICVM_BUILD_OUT || 'epicvm_web/dist')
let scenario = {}, activeChecks = 0, maxChecks = 0, launches = 0, stops = 0, authChecks = 0
const json = (res, body, status = 200) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(body)) }
const user = { username: 'status_friend', accountStatus: 'approved' }
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost')
  if (url.pathname === '/__test/scenario' && req.method === 'POST') {
    let raw = ''; for await (const chunk of req) raw += chunk
    scenario = JSON.parse(raw); maxChecks = activeChecks; authChecks = 0
    return json(res, { ok: true })
  }
  if (url.pathname === '/__test/metrics') return json(res, { activeChecks, maxChecks, launches, stops, authChecks })
  const current = { ...scenario }
  if (url.pathname === '/EpicVM/api/me') {
    ++authChecks
    if (current.authDelay) await new Promise(resolve => setTimeout(resolve, current.authDelay))
    if (current.authFail) return json(res, { error: 'Network unavailable' }, 503)
    return json(res, current.expired ? { authenticated: false } : { authenticated: true, ...user })
  }
  if (url.pathname === '/portal/api/auth/login') { scenario = {}; return json(res, { ok: true, user }) }
  if (url.pathname === '/portal/api/vms') return json(res, { ok: true, vms: [], summary: { total: 0, ready: 0 } })
  if (url.pathname === '/EpicVM/api/account/session') return json(res, current.sessionExpired ? { ok: false, authenticated: false } : { ok: true, csrfToken: 'fixture-only', user }, current.sessionExpired ? 401 : current.sessionFail ? 503 : 200)
  if (url.pathname === '/EpicVM/api/account/host-gaming/desktop' && req.method === 'POST') { ++launches; return json(res, { ok: true, jobId: 'fixture-job' }, 202) }
  if (url.pathname === '/EpicVM/api/account/host-gaming/stop' && req.method === 'POST') { ++stops; return json(res, { ok: true }) }
  if (url.pathname === '/EpicVM/api/account/host-gaming/launch-jobs/fixture-job') return json(res, current.jobExpired ? { ok: false } : { ok: true, state: 'ready', result: { ok: true, launchUrl: '/EpicVM/fixture-stream' } }, current.jobExpired ? 401 : 200)
  if (url.pathname === '/EpicVM/fixture-stream') { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end('<main>Fixture desktop stream</main>') }
  if (['/EpicVM/api/account/games', '/EpicVM/api/account/host-gaming', '/EpicVM/api/account/host-gaming/desktops'].includes(url.pathname)) {
    ++activeChecks; maxChecks = Math.max(maxChecks, activeChecks)
    try {
      if (current.delay) await new Promise(resolve => setTimeout(resolve, current.delay))
      if (current.libraryExpired) return json(res, { ok: false }, 401)
      if (current.statusFail || current.desktopFail && url.pathname.endsWith('/desktops')) return json(res, { ok: false, error: 'Unavailable' }, 503)
      if (url.pathname.endsWith('/account/games')) return json(res, { ok: true, machines: [] })
      if (url.pathname.endsWith('/account/host-gaming')) return json(res, { ok: true, available: true, hostId: 'fixture-host', desktopAccess: false, games: [{ id: 'fixture-game', title: 'Fixture game', available: true }] })
      const desktop = { hostId: 'fixture-host', displayName: 'Friend desktop', localConnectionAvailable: true, available: !current.offline, seat: current.seatError ? { id: 'seat-kept', status: 'Error', errorMessage: 'Technical driver failure' } : current.preparing ? { id: 'seat-kept', status: 'Starting' } : { id: 'seat-kept', status: 'Ready' } }
      if (current.recovery) desktop.errorMessage = 'This desktop needs administrator recovery.'
      return json(res, { ok: true, desktops: [desktop] })
    } finally { --activeChecks }
  }
  if (url.pathname.startsWith('/EpicVM/assets/')) {
    const file = path.resolve(build, url.pathname.slice('/EpicVM/'.length))
    if (!file.startsWith(build + path.sep)) return json(res, {}, 404)
    try { res.writeHead(200, { 'Content-Type': file.endsWith('.js') ? 'text/javascript' : 'text/css' }); return res.end(await fs.readFile(file)) } catch { return res.end() }
  }
  if (url.pathname.endsWith('.js') || url.pathname.endsWith('.svg')) return json(res, {}, 404)
  if (url.pathname.startsWith('/EpicVM/')) { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end(await fs.readFile(path.join(build, 'index.html'))) }
  return json(res, {}, 404)
})
server.listen(0, '127.0.0.1', () => console.log(`http://127.0.0.1:${server.address().port}`))
