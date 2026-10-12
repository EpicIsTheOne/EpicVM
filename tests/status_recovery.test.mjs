import test from 'node:test'
import assert from 'node:assert/strict'
import { desktopStatus } from '../epicvm_web/src/desktopStatus.js'
import { sessionVersion, sessionChanged, checkSessionResponse, signInDestination } from '../epicvm_web/src/session.js'

test('only healthy verified desktops count as ready', () => {
  assert.equal(desktopStatus({ available: true }).ready, true)
  for (const status of ['Ready', 'Streaming']) assert.equal(desktopStatus({ available: true, seat: { status } }).ready, true)
  assert.equal(desktopStatus({ available: true }, false).label, 'Status unverified')
  assert.equal(desktopStatus({ available: false }).label, 'Unavailable')
  assert.equal(desktopStatus({ available: false, hostOnline: false }).label, 'Host offline')
  assert.equal(desktopStatus({ available: true, hostOnline: false }).ready, false)
  assert.equal(desktopStatus({ hostOnline: false }, false).label, 'Status unverified')
  assert.equal(desktopStatus({ available: true, errorMessage: 'duplicate seats' }).label, 'Needs recovery')
  assert.equal(desktopStatus({ available: true, seat: { status: 'Error' } }).label, 'Needs recovery')
  assert.equal(desktopStatus({ available: true, seat: { status: 'Ready', errorMessage: 'failed capture' } }).ready, false)
  assert.equal(desktopStatus({ available: true, seat: { status: 'Starting' } }).label, 'Preparing')
  assert.equal(desktopStatus({ available: true, seat: { status: 'Unexpected' } }).ready, false)
})
test('recovery copy does not reveal provider details', () => {
  assert.equal(desktopStatus({ available: true, errorMessage: 'private technical failure' }).message.includes('private technical failure'), false)
})
test('only a current confirmed 401 expires the session', () => {
  let events = 0
  globalThis.window = { dispatchEvent: () => { ++events } }
  const previous = sessionVersion()
  sessionChanged()
  checkSessionResponse({ status: 401 }, previous)
  checkSessionResponse({ status: 503 })
  checkSessionResponse({ status: 403 })
  assert.equal(events, 0)
  assert.throws(() => checkSessionResponse({ status: 401 }), /expired/)
  assert.equal(events, 1)
})
test('sign-in return targets cannot redirect outside the app', () => {
  assert.equal(signInDestination('/settings'), '/settings')
  for (const value of ['https://example.com', '//example.com', '/unknown', undefined]) assert.equal(signInDestination(value), '/portal')
})

test('paused and full hosts block new seats but preserve healthy resume', () => {
  for (const [hosting, label] of [[{ paused: true }, 'Hosting paused'], [{ full: true }, 'Host full']]) {
    assert.equal(desktopStatus({ available: true, hosting }).label, label)
    assert.equal(desktopStatus({ available: true, hosting }).ready, false)
    for (const status of ['Ready', 'Streaming']) assert.equal(desktopStatus({ available: true, hosting, seat: { status } }).ready, true)
    assert.equal(desktopStatus({ available: true, hosting, seat: { status: 'Error' } }).label, 'Needs recovery')
    assert.equal(desktopStatus({ available: true, hosting }, false).label, 'Status unverified')
    assert.equal(desktopStatus({ available: false, hostOnline: false, hosting }).label, 'Host offline')
  }
  assert.equal(desktopStatus({ available: true, hosting: { paused: true, full: true } }).label, 'Hosting paused')
  assert.equal(desktopStatus({ available: true, hosting: { paused: false, full: false } }).ready, true)
})
