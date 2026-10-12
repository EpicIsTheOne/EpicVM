export const LAUNCH_KEY = 'epicvm.portal.launch.v1'
export const LAUNCH_TIMEOUT = 600000
export function launchStorage() {
  try { return window.sessionStorage } catch { return null }
}
export const stageText = {
  preparing: 'Checking your account and host…',
  windows: 'Preparing your Windows desktop…',
  stream: 'Starting your desktop stream…',
  pairing: 'Pairing the secure connection…',
  checking: 'Checking your desktop connection…',
}

// Store only the job reference and display context, never passwords or launch URLs.
export function saveLaunch(storage, owner, launch) {
  try {
    storage.setItem(LAUNCH_KEY, JSON.stringify({ owner, jobId: launch.jobId,
      key: launch.key, label: launch.label, connection: launch.connection,
      hostId: launch.hostId, startedAt: launch.startedAt }))
  } catch { /* Storage can be disabled; the current launch still works. */ }
}
export function clearLaunch(storage) {
  try { storage.removeItem(LAUNCH_KEY) } catch { /* optional storage */ }
}
export function readLaunch(storage, owner, now = Date.now()) {
  try {
    const value = JSON.parse(storage.getItem(LAUNCH_KEY) || 'null')
    if (!value) return null
    if (value.owner === owner && typeof value.jobId === 'string' && /^[\w-]{1,128}$/.test(value.jobId) &&
        typeof value.key === 'string' && typeof value.label === 'string' &&
        ['internet', 'local'].includes(value.connection) && Number.isFinite(value.startedAt) &&
        value.startedAt <= now && now - value.startedAt < LAUNCH_TIMEOUT) return value
    clearLaunch(storage)
  } catch { clearLaunch(storage) }
  return null
}

export function waitForPoll(ms, signal) {
  return new Promise((resolve, reject) => {
    const abort = () => { clearTimeout(timer); reject(new DOMException('Aborted', 'AbortError')) }
    const timer = setTimeout(() => { signal.removeEventListener('abort', abort); resolve() }, ms)
    if (signal.aborted) abort()
    else signal.addEventListener('abort', abort, { once: true })
  })
}

export async function watchLaunch({ request, signal, onProgress, delay = waitForPoll }) {
  let failures = 0
  while (true) {
    await delay(failures ? Math.min(10000, 2000 * 2 ** Math.min(failures, 3)) : 2000, signal)
    let job
    try { job = await request() } catch (error) {
      if (signal.aborted || !error.retryable) throw error
      failures++
      onProgress({ interrupted: true })
      continue
    }
    failures = 0
    onProgress({ interrupted: false, stage: job.stage || 'preparing', startedAt: job.createdAt ? job.createdAt * 1000 : undefined })
    if (job.state === 'running') continue
    const body = job.result || {}
    if (job.state !== 'ready' || body.ok === false) throw new Error(body.error?.message || body.error || 'Could not prepare your desktop connection.')
    return body
  }
}
