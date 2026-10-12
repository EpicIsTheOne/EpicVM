export function privateIPv4(address) {
    if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(String(address || ''))) return false;
    const parts = String(address || '').split('.').map(Number);
    if (parts.length !== 4 || parts.some(n => !Number.isInteger(n) || n < 0 || n > 255)) return false;
    return parts[0] === 10 || parts[0] === 192 && parts[1] === 168 || parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31;
}

export function networkStatus(report) {
    const stats = [...report.values()];
    const transport = stats.find(s => s.type === 'transport' && s.selectedCandidatePairId);
    const pair = transport ? report.get(transport.selectedCandidatePairId) : stats.find(s => s.type === 'candidate-pair' && s.state === 'succeeded' && s.selected === true);
    if (!pair) return 'Checking video connection';
    const remote = report.get(pair.remoteCandidateId), local = report.get(pair.localCandidateId);
    const relay = remote?.candidateType === 'relay' || local?.candidateType === 'relay';
    const remoteAddress = remote?.address || remote?.ip;
    const localAddress = local?.address || local?.ip;
    const lan = !relay && remote?.candidateType === 'host' && local?.candidateType === 'host' &&
        privateIPv4(remoteAddress) && privateIPv4(localAddress) &&
        remoteAddress.split('.').slice(0, 3).join('.') === localAddress.split('.').slice(0, 3).join('.');
    const latency = Number.isFinite(pair.currentRoundTripTime) ? ` · ${Math.round(pair.currentRoundTripTime * 1000)} ms RTT` : '';
    return (lan ? 'LAN connected' : relay ? 'Video uses a relay' : 'Direct video connection') + latency;
}

export function installStreamNetwork(app) {
    if (app.epicvmNetwork) return;
    app.epicvmNetwork = true;
    const panel = document.createElement('aside');
    panel.id = 'epicvm-network';
    panel.style.cssText = 'position:fixed;bottom:12px;right:12px;z-index:9000;background:#071117;color:#e7f0f4;padding:12px;border:1px solid #29404a;border-radius:6px;font:14px sans-serif;max-width:calc(100vw - 48px)';
    panel.hidden = true;
    const status = document.createElement('span');
    status.textContent = 'Checking video connection';
    status.setAttribute('role', 'status');
    panel.append(status);
    const route = new URLSearchParams(location.search).get('route');
    if (new URLSearchParams(location.search).get('connection') === 'local' && /^(seat-[0-9a-f]{24}|vm-[a-z0-9][a-z0-9._-]{0,62})$/.test(route || '')) {
        const link = document.createElement('a');
        link.href = 'https://techexplore.us/EpicVM/stream-launch/' + route;
        link.textContent = ' Use normal connection';
        link.style.color = '#43c9ee';
        panel.append(link);
    }
    document.body.append(panel);
    let disposed = false, sampling = false;
    const syncVisibility = () => {
        panel.hidden = !app.getStream()?.getStats()?.isEnabled();
    };
    // The existing Stats button toggles synchronously before the click bubbles.
    document.addEventListener('click', syncVisibility);
    const timer = setInterval(async () => {
        syncVisibility();
        if (panel.hidden) return;
        if (sampling || disposed) return;
        const stream = app.getStream();
        const peer = stream?.transport?.peer;
        if (!peer?.getStats) {
            const rtt = stream?.stats?.statsData?.browserRtt;
            status.textContent = stream?.transport
                ? 'WebSocket video connection' + (Number.isFinite(rtt) ? ` · ${Math.round(rtt)} ms RTT` : ' · RTT unavailable')
                : 'Checking video connection';
            return;
        }
        sampling = true;
        try {
            const report = await peer.getStats();
            if (!disposed) status.textContent = networkStatus(report);
        } catch { if (!disposed) status.textContent = 'Video connection unavailable'; }
        finally { sampling = false; }
    }, 2000);
    window.addEventListener('pagehide', () => { disposed = true; clearInterval(timer); document.removeEventListener('click', syncVisibility); panel.remove(); }, { once: true });
}
