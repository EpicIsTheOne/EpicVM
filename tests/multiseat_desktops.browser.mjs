import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import http from 'node:http'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const requireFromProject = createRequire(import.meta.url)
const requireFromCodexRuntime = createRequire('C:/Users/Epic/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/package.json')
let chromium
try { ({ chromium } = requireFromProject('playwright')) }
catch { ({ chromium } = requireFromCodexRuntime('playwright')) }

const projectRoot = fileURLToPath(new URL('..', import.meta.url))
const buildDir = path.resolve(process.env.EPICVM_BUILD_OUT || path.join(projectRoot, 'epicvm_web', 'dist'))
const indexHtml = await fs.readFile(path.join(buildDir, 'index.html'))
const enteredHosts = []
let assignedDesktops = [
  { hostId: 'win-a', displayName: 'Workstation Alpha', available: true, seat: null },
  { hostId: 'win-b', displayName: 'Workstation Beta', available: true, seat: null },
]
let defaultDesktopAccess = false
const serveFixture = process.env.EPICVM_RECONNECT_FIXTURE === '1' || process.env.EPICVM_UX_FIXTURE === '1'
let launchDelay = 0, launchFailure = false, availabilityFailure = false
const stoppedHosts = []
if (process.env.EPICVM_RECONNECT_FIXTURE === '1') {
  assignedDesktops[0].seat = { id: 'retained-seat', status: 'Ready', launchUrl: '/stale-stream-link' }
}

function sendJson(res, value, status = 200) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' })
  res.end(JSON.stringify(value))
}

function contentType(file) {
  if (file.endsWith('.js')) return 'text/javascript; charset=utf-8'
  if (file.endsWith('.css')) return 'text/css; charset=utf-8'
  if (file.endsWith('.svg')) return 'image/svg+xml'
  return 'application/octet-stream'
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1')
  if (serveFixture && url.pathname === '/__test/launches') {
    return sendJson(res, { enteredHosts, stoppedHosts })
  }
  if (serveFixture && req.method === 'POST' && url.pathname === '/__test/scenario') {
    let raw = ''; for await (const chunk of req) raw += chunk
    const next = JSON.parse(raw)
    launchDelay = Number(next.delay || 0); launchFailure = !!next.fail; availabilityFailure = !!next.unavailable
    assignedDesktops = next.empty ? [] : [
      { hostId: 'win-a', displayName: 'Workstation Alpha', available: true, seat: { id: 'retained-seat', status: 'Ready' } },
      { hostId: 'win-b', displayName: 'Workstation Beta', available: true, seat: null },
    ]
    return sendJson(res, { ok: true })
  }
  if (req.method === 'GET' && url.pathname === '/EpicVM/api/me') {
    return sendJson(res, { authenticated: true, username: 'alice', accountStatus: 'approved' })
  }
  if (req.method === 'GET' && url.pathname === '/portal/api/vms') {
    return sendJson(res, { ok: true, vms: [], summary: { total: 0, ready: 0, provisioning: 0, stopped: 0 } })
  }
  if (req.method === 'GET' && url.pathname === '/EpicVM/api/account/games') {
    return sendJson(res, { ok: true, machines: [] })
  }
  if (req.method === 'GET' && url.pathname === '/EpicVM/api/account/host-gaming') {
    return sendJson(res, { ok: true, hostId: 'epic-pc', available: true, games: [], desktopAccess: defaultDesktopAccess, seat: null })
  }
  if (req.method === 'GET' && url.pathname === '/EpicVM/api/account/host-gaming/desktops') {
    if (availabilityFailure) return sendJson(res, { ok: false, error: 'Host unavailable.' }, 503)
    return sendJson(res, { ok: true, desktops: assignedDesktops })
  }
  if (req.method === 'GET' && url.pathname === '/EpicVM/api/account/session') {
    return sendJson(res, { ok: true, csrfToken: 'test-csrf' })
  }
  if (req.method === 'POST' && url.pathname === '/EpicVM/api/account/host-gaming/desktop') {
    let body = ''
    for await (const chunk of req) body += chunk
    const hostId = JSON.parse(body).hostId
    if (!assignedDesktops.some(desktop => desktop.hostId === hostId)) return sendJson(res, { ok: false, error: 'Unassigned desktop.' }, 400)
    enteredHosts.push(hostId)
    if (launchDelay) await new Promise(resolve => setTimeout(resolve, launchDelay))
    if (launchFailure) return sendJson(res, { ok: false, error: 'The host is temporarily unavailable.' }, 503)
    return sendJson(res, { ok: true, launchUrl: `/EpicVM/stream-launch/seat-${hostId}` })
  }
  if (serveFixture && req.method === 'POST' && url.pathname === '/EpicVM/api/account/host-gaming/stop') {
    let raw = ''; for await (const chunk of req) raw += chunk
    const hostId = JSON.parse(raw).hostId
    stoppedHosts.push(hostId)
    assignedDesktops = assignedDesktops.map(d => d.hostId === hostId ? { ...d, seat: null } : d)
    return sendJson(res, { ok: true })
  }
  if (req.method === 'GET' && url.pathname.startsWith('/EpicVM/stream-launch/seat-')) {
    const hostId = url.pathname.slice('/EpicVM/stream-launch/seat-'.length)
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' })
    return res.end(`<main data-host="${hostId}">Entered desktop ${hostId}</main>`)
  }
  if (req.method === 'GET' && url.pathname.startsWith('/EpicVM/assets/')) {
    const file = path.resolve(buildDir, url.pathname.slice('/EpicVM/'.length))
    if (!file.startsWith(buildDir + path.sep)) return sendJson(res, { error: 'Not found.' }, 404)
    try {
      const data = await fs.readFile(file)
      res.writeHead(200, { 'Content-Type': contentType(file), 'Cache-Control': 'no-store' })
      return res.end(data)
    } catch {
      return sendJson(res, { error: 'Not found.' }, 404)
    }
  }
  if (req.method === 'GET' && url.pathname.startsWith('/EpicVM/')) {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' })
    return res.end(indexHtml)
  }
  return sendJson(res, { error: 'Not found.' }, 404)
})

await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
const base = `http://127.0.0.1:${server.address().port}`
if (serveFixture) {
  console.log(base)
  // Serve the isolated fixture for the approved browser wrapper. No production
  // accounts, seats, or stream services are touched by this mode.
  await new Promise(() => {})
}
const chromePath = process.env.EPICVM_CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe'
const browser = await chromium.launch({ executablePath: chromePath, headless: true })
const errors = []

try {
  const page = await browser.newPage()
  page.on('pageerror', error => errors.push(error.message))
  for (const desktop of assignedDesktops) {
    await page.goto(`${base}/EpicVM/portal`, { waitUntil: 'domcontentloaded' })
    const library = page.locator('details.evm-shared-games')
    await library.locator('summary').click()
    const card = page.locator('.evm-library-desktop').filter({ hasText: desktop.displayName })
    await card.getByRole('button', { name: 'Open desktop', exact: true }).click()
    await page.locator(`main[data-host="${desktop.hostId}"]`).waitFor()
    assert.equal(new URL(page.url()).pathname, `/EpicVM/stream-launch/seat-${desktop.hostId}`)
  }
  assignedDesktops[0].seat = { id: 'retained-seat', status: 'Ready', launchUrl: '/stale-stream-link' }
  await page.goto(`${base}/EpicVM/portal`, { waitUntil: 'domcontentloaded' })
  await page.locator('details.evm-shared-games summary').click()
  const resumedDesktop = page.locator('.evm-library-desktop').filter({ hasText: 'Workstation Alpha' })
  await resumedDesktop.getByRole('button', { name: 'Resume desktop', exact: true }).click()
  await page.locator('main[data-host="win-a"]').waitFor()
  assert.equal(new URL(page.url()).pathname, '/EpicVM/stream-launch/seat-win-a')
  assignedDesktops = [{ hostId: 'epic-pc', displayName: 'Default host', available: true, seat: null }]
  defaultDesktopAccess = true
  await page.goto(`${base}/EpicVM/portal`, { waitUntil: 'domcontentloaded' })
  const library = page.locator('details.evm-shared-games')
  await library.locator('summary').click()
  const singleDesktop = page.locator('.evm-library-desktop')
  assert.equal(await singleDesktop.count(), 1)
  assert.equal(await singleDesktop.getByRole('heading', { name: 'Personal desktop', exact: true }).count(), 1)
  await singleDesktop.getByRole('button', { name: 'Open desktop', exact: true }).click()
  await page.locator('main[data-host="epic-pc"]').waitFor()
  assert.deepEqual(enteredHosts, ['win-a', 'win-b', 'win-a', 'epic-pc'])
  assert.deepEqual(errors, [])
  console.log('PASS: assigned desktops, stale-link resume, and the default desktop entered their matching host streams without browser errors.')
} finally {
  await browser.close()
  server.closeAllConnections?.()
  await new Promise(resolve => server.close(resolve))
}
