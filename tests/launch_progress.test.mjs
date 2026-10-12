import test from 'node:test'
import assert from 'node:assert/strict'
import { LAUNCH_KEY, saveLaunch, readLaunch, watchLaunch, waitForPoll } from '../epicvm_web/src/launchProgress.js'

function storage() {
  const entries = new Map()
  return { getItem: k => entries.get(k), setItem: (k, v) => entries.set(k, v), removeItem: k => entries.delete(k) }
}
test('reload preserves LAN selection but stores no password or connection grant', () => {
  const store = storage()
  saveLaunch(store, 'portal:alice', { jobId: 'job-1', key: 'desktop-a', label: 'PC', connection: 'local', startedAt: 100,
    windowsPassword: 'private', launchUrl: '/private-grant' })
  assert.equal(readLaunch(store, 'portal:alice', 200).connection, 'local')
  assert.equal(store.getItem(LAUNCH_KEY).includes('private'), false)
  assert.equal(readLaunch(store, 'portal:bob', 200), null)
  assert.equal(store.getItem(LAUNCH_KEY), undefined)
})
test('expired, invalid and unavailable storage cannot restore a launch', () => {
  const store = storage()
  store.setItem(LAUNCH_KEY, '{')
  assert.equal(readLaunch(store, 'alice'), null)
  saveLaunch(store, 'alice', { jobId: 'j', key: 'k', label: 'PC', connection: 'internet', startedAt: 1 })
  assert.equal(readLaunch(store, 'alice', 600001), null)
  assert.equal(readLaunch({ getItem() { throw Error() }, removeItem() { throw Error() } }, 'alice'), null)
})
test('temporary polling failures recover while watching the same job', async () => {
  const progress = [], delays = []
  let calls = 0
  const result = await watchLaunch({ signal: new AbortController().signal,
    request: async () => {
      calls++
      if (calls < 3) throw Object.assign(new Error('offline'), { retryable: true })
      if (calls === 3) return { state: 'running', stage: 'pairing', createdAt: 10 }
      return { state: 'ready', stage: 'checking', result: { ok: true, launchUrl: '/fresh' } }
    }, delay: async ms => delays.push(ms), onProgress: p => progress.push(p) })
  assert.equal(result.launchUrl, '/fresh')
  assert.deepEqual(delays, [2000, 4000, 8000, 2000])
  assert.equal(progress[0].interrupted, true)
  assert.equal(progress[2].stage, 'pairing')
  assert.equal(progress[2].startedAt, 10000)
  assert.equal(progress[3].interrupted, false)
})
test('terminal ownership and launch errors are never retried', async () => {
  let calls = 0
  await assert.rejects(watchLaunch({ signal: new AbortController().signal, delay: async () => {}, onProgress: () => {},
    request: async () => { calls++; throw Error('Access denied') } }), /Access denied/)
  assert.equal(calls, 1)
  await assert.rejects(watchLaunch({ signal: new AbortController().signal, delay: async () => {}, onProgress: () => {},
    request: async () => ({ state: 'failed', result: { error: { message: 'Host offline' } } }) }), /Host offline/)
})
test('stop waiting and unmount immediately cancel a pending retry', async () => {
  const controller = new AbortController()
  const waiting = waitForPoll(30000, controller.signal)
  controller.abort()
  await assert.rejects(waiting, { name: 'AbortError' })
  await assert.rejects(waitForPoll(30000, controller.signal), { name: 'AbortError' })
})
