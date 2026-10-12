export function desktopStatus(desktop, verified = true) {
  if (!verified) return { label: 'Status unverified', ready: false, message: 'We could not check this desktop. Refresh status before opening or ending a session.' }
  if (desktop.hostOnline === false) return { label: 'Host offline', ready: false, message: 'Turn on the host PC and wait for EpicVM to start. This page checks again automatically.' }
  if (!desktop.available) return { label: 'Unavailable', ready: false, message: 'This desktop host is currently unavailable. Try refreshing status shortly. If it stays unavailable, ask Epic for help.' }
  const seatState = String(desktop.seat?.status || '').toLowerCase()
  if (desktop.errorMessage || desktop.seat?.errorMessage || ['error', 'failed'].includes(seatState)) {
    return { label: 'Needs recovery', ready: false, message: 'This desktop needs recovery. Ask Epic for help from Settings. Your saved files stay in your account.' }
  }
  if (desktop.seat && !['ready', 'streaming'].includes(seatState)) {
    return { label: 'Preparing', ready: false, message: 'Your desktop is changing state. This page checks its status automatically.' }
  }
  if (!desktop.seat && desktop.hosting?.paused) return { label: 'Hosting paused', ready: false, message: 'The host has paused new sessions. Existing desktops can still resume. This page checks again automatically.' }
  if (!desktop.seat && desktop.hosting?.full) return { label: 'Host full', ready: false, message: 'The host has reached its session limit. Try again when a space opens up. This page checks again automatically.' }
  return { label: 'Ready', ready: true, message: '' }
}
