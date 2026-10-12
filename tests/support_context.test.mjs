import test from 'node:test'
import assert from 'node:assert/strict'
import { safeContext, reportDestination, contextFromSearch } from '../epicvm_web/src/supportContext.js'
import { streamReportUrl } from '../scripts/stream_recovery.js'

test('launch reports round-trip only the previewed connection fields', () => {
  const context = { host: 'epic-pc', connection: 'local', stage: 'pairing', source: 'launch', time: '2026-10-12T03:00:00.000Z' }
  const destination = reportDestination({ ...context, password: 'SECRET', launchUrl: '/?unlock=SECRET', route: 'private-seat' })
  assert.deepEqual(contextFromSearch(destination.split('?')[1]), context)
  assert.equal(destination.includes('SECRET'), false)
  assert.equal(destination.includes('private-seat'), false)
})
test('malformed context and unknown fields cannot become report content', () => {
  assert.deepEqual(safeContext({ host: 'https://secret/', stage: 'password=secret', time: 'invalid', connection: 'relay' }), {})
  assert.equal(contextFromSearch('?token=secret'), null)
  assert.deepEqual(contextFromSearch('?report=bug&password=secret'), {})
})
test('stream reporting excludes grants and viewer identity and preserves LAN context', () => {
  const destination = streamReportUrl('?epicvmHost=epic-pc&hostId=private-viewer-id&connection=local&route=private-seat&grant=SECRET&unlock=SECRET', new Date('2026-10-12T03:00:00Z'))
  const url = new URL(destination)
  assert.equal(url.origin, 'https://techexplore.us')
  assert.equal(url.pathname, '/EpicVM/settings')
  assert.deepEqual(contextFromSearch(url.search), { host: 'epic-pc', connection: 'local', source: 'recovery', stage: 'recovery', time: '2026-10-12T03:00:00.000Z' })
  assert.equal(destination.includes('SECRET'), false)
  assert.equal(destination.includes('private'), false)
  assert.equal(contextFromSearch(new URL(streamReportUrl('')).search).connection, 'internet')
})
