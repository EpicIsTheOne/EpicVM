export const SESSION_EXPIRED = 'epicvm:session-expired'
let version = 0
export function sessionVersion() { return version }
export function sessionChanged() { ++version }

export function sessionExpired() {
  sessionChanged()
  window.dispatchEvent(new Event(SESSION_EXPIRED))
  return new Error('Your sign-in has expired. Sign in again to continue.')
}

export function checkSessionResponse(response, requestedVersion = version) {
  if (response.status === 401 && requestedVersion === version) throw sessionExpired()
}

// Only return to routes owned by this app, never a supplied external URL.
export function signInDestination(from) {
  return ['/portal', '/pending', '/settings'].includes(from) ? from : '/portal'
}
