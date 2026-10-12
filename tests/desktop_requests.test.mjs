import test from 'node:test'
import assert from 'node:assert/strict'
import { latestDesktopRequest, requestStatus, requestLink } from '../epicvm_web/src/desktopRequests.js'
test('prefer an open desktop request over closed requests and unrelated reports', () => {
  const open = { id: 'one', kind: 'desktop', status: 'pending', updated_at: 1 }
  assert.equal(latestDesktopRequest([open, { kind: 'bug', updated_at: 9 }, { kind: 'desktop', status: 'resolved', updated_at: 8 }]), open)
  assert.equal(latestDesktopRequest([]), null)
})
test('readiness copy distinguishes assigned access from a later revoked grant', () => {
  assert.equal(requestStatus({ status: 'resolved', desktopAssigned: true }), 'Desktop access assigned')
  assert.equal(requestStatus({ status: 'resolved', desktopAssigned: false }), 'Request resolved')
  assert.equal(requestStatus({ status: 'in_review' }), 'Request under review')
  assert.equal(requestLink({ id: 'abc' }), '/settings#request-abc')
})
