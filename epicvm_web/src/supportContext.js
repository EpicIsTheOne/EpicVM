export const reportStages = ['preparing', 'windows', 'stream', 'pairing', 'checking', 'recovery']
export function safeContext(value) {
  const context = {}
  if (typeof value?.host === 'string' && /^[a-zA-Z0-9._-]{1,128}$/.test(value.host)) context.host = value.host
  if (['local', 'internet'].includes(value?.connection)) context.connection = value.connection
  if (['launch', 'recovery'].includes(value?.source)) context.source = value.source
  if (reportStages.includes(value?.stage)) context.stage = value.stage
  if (typeof value?.time === 'string' && /^\d{4}-\d{2}-\d{2}T[\d:.]+Z$/.test(value.time) && Number.isFinite(Date.parse(value.time))) context.time = value.time
  return context
}
export function reportDestination(value) {
  return '/settings?' + new URLSearchParams({ report: 'bug', ...safeContext(value) })
}
export function contextFromSearch(search) {
  const params = new URLSearchParams(search)
  return params.get('report') === 'bug' ? safeContext(Object.fromEntries(params)) : null
}
export const contextLabels = { host: 'Host', connection: 'Connection', source: 'Reported from', stage: 'Last launch stage', time: 'Time' }
export function contextValue(key, value) {
  if (key === 'connection') return value === 'local' ? 'Local network' : 'Normal connection'
  if (key === 'time') return new Date(value).toLocaleString()
  if (key === 'source') return value === 'launch' ? 'Desktop launch' : 'Stream recovery'
  if (key === 'stage') return { preparing: 'Checking account and host', windows: 'Preparing Windows desktop',
    stream: 'Starting desktop stream', pairing: 'Pairing secure connection', checking: 'Checking connection', recovery: 'Connection recovery' }[value]
  return value
}
