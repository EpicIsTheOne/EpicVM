// Isolated async-launch fixture, consumed through Epic's browser wrapper.
import http from 'node:http'
import fs from 'node:fs/promises'
import path from 'node:path'
const build = path.resolve(process.env.EPICVM_BUILD_OUT || 'epicvm_web/dist')
let posts = 0, polls = 0, ready = false, failing = false, startedAt = 0
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost')
  const json = (body, status = 200) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(body)) }
  if (url.pathname === '/__test') {
    if (url.searchParams.has('ready')) ready = true
    if (url.searchParams.has('fail')) failing = url.searchParams.get('fail') === '1'
    return json({ posts, polls, ready, failing })
  }
  if (url.pathname === '/EpicVM/api/me') return json({ authenticated: true, username: 'launch-fixture', accountStatus: 'approved' })
  if (url.pathname === '/portal/api/vms') return json({ ok: true, vms: [], summary: {} })
  if (url.pathname === '/EpicVM/api/account/session') return json({ ok: true, csrfToken: 'fixture' })
  if (url.pathname === '/EpicVM/api/account/games') return json({ ok: true, machines: [] })
  if (url.pathname === '/EpicVM/api/account/host-gaming') return json({ ok: true, games: [] })
  if (url.pathname === '/EpicVM/api/account/host-gaming/desktops') return json({ ok: true, desktops: [{ hostId: 'fixture', displayName: 'Test host', available: true, localConnectionAvailable: true }] })
  if (url.pathname === '/EpicVM/api/account/host-gaming/desktop' && req.method === 'POST') {
    posts++; startedAt = Date.now() / 1000
    return json({ ok: true, jobId: 'fixture-job', state: 'running' }, 202)
  }
  if (url.pathname === '/EpicVM/api/account/host-gaming/launch-jobs/fixture-job') {
    polls++
    if (failing) return json({ error: 'Temporary outage' }, 503)
    return json({ ok: true, state: ready ? 'ready' : 'running', stage: polls > 2 ? 'pairing' : 'windows', createdAt: startedAt,
      result: ready ? { ok: true, launchUrl: '/EpicVM/stream-launch/fixture' } : null })
  }
  if (url.pathname === '/EpicVM/stream-launch/fixture') { res.end('Fixture desktop connected'); return }
  try {
    const asset = url.pathname.startsWith('/EpicVM/assets/')
    const file = asset ? path.join(build, 'assets', path.basename(url.pathname)) : path.join(build, 'index.html')
    res.setHeader('Content-Type', file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'text/html')
    res.end(await fs.readFile(file))
  } catch { res.writeHead(404); res.end() }
})
server.listen(5219, '127.0.0.1', () => console.log('Launch fixture: http://127.0.0.1:5219/EpicVM/portal'))
