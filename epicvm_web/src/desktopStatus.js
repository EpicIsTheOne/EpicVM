export function desktopStatus(desktop, verified = true) {
  if (!verified) return { label: 'Status unverified', ready: false, message: 'We could not check this desktop. Refresh status before opening or ending a session.' }
  if (!desktop.available) return { label: 'Unavailable', ready: false, message: 'This desktop host is currently unavailable. Try refreshing status shortly. If it stays unavailable, ask Epic for help.' }
  const seatState = String(desktop.seat?.status || '').toLowerCase()
  if (desktop.errorMessage || desktop.seat?.errorMessage || ['error', 'failed'].includes(seatState)) {
    return { label: 'Needs recovery', ready: false, message: 'This desktop needs recovery. Ask Epic for help from Settings. Your saved files stay in your account.' }
  }
  if (desktop.seat && !['ready', 'streaming'].includes(seatState)) {
    return { label: 'Preparing', ready: false, message: 'Your desktop is changing state. This page checks its status automatically.' }
  }
  return { label: 'Ready', ready: true, message: '' }
}
