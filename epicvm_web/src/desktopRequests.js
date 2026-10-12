export function latestDesktopRequest(tickets) {
  const requests = (tickets || []).filter(t => t.kind === 'desktop')
  const open = requests.filter(t => ['pending', 'in_review'].includes(t.status))
  return [...(open.length ? open : requests)].sort((a, b) => b.updated_at - a.updated_at || b.created_at - a.created_at)[0] || null
}
export function requestStatus(request) {
  if (request.status === 'resolved') return request.desktopAssigned ? 'Desktop access assigned' : 'Request resolved'
  return { pending: 'Request pending', in_review: 'Request under review', declined: 'Request declined' }[request.status] || 'Desktop access request'
}
export function requestLink(request) {
  return '/settings#request-' + encodeURIComponent(request.id)
}
