// Recover transport connections without creating or ending a Windows seat.
export class StreamRecovery {
    constructor(app, show, now = () => Date.now()) {
        this.app = app;
        this.show = show;
        this.now = now;
        this.attempts = 0;
        this.disposed = false;
        this.busy = false;
        this.stream = null;
        this.changedAt = now();
        this.lostAt = null;
        this.nextAt = 0;
        this.healthyAt = null;
        this.mediaCounter = null;
        this.mediaAt = now();
        this.sampling = false;
    }
    sampleMedia(stream) {
        const receiver = stream?.transport?.videoReceiver;
        if (!receiver?.getStats || this.sampling) return;
        this.sampling = true;
        Promise.resolve().then(() => receiver.getStats()).then(report => {
            if (this.disposed || stream !== this.stream) return;
            for (const stat of report.values()) {
                if (stat.type !== 'inbound-rtp' || !['video', undefined].includes(stat.kind)) continue;
                const counter = stat.framesDecoded ?? stat.framesReceived;
                if (!Number.isFinite(counter)) continue;
                if (this.mediaCounter !== counter) {
                    this.mediaCounter = counter;
                    this.mediaAt = this.now();
                }
            }
        }).catch(() => {}).finally(() => { this.sampling = false; });
    }
    async retry(manual = false) {
        if (this.disposed || this.busy || this.app.streamReloading) return;
        if (manual) this.attempts = 0;
        if (this.attempts >= 3) return;
        this.busy = true;
        this.attempts++;
        this.show(`Reconnecting to your desktop… Attempt ${this.attempts} of 3.`, true);
        try {
            await this.app.reloadStream();
        } catch (_) {
            // The monitor confirms success from the new live stream.
        } finally {
            this.busy = false;
            this.changedAt = this.now();
            this.lostAt = null;
            this.nextAt = this.now() + [3000, 8000, 15000][this.attempts - 1];
        }
    }
    tick(online = navigator.onLine, visible = document.visibilityState === 'visible') {
        if (this.disposed) return;
        if (!visible) {
            this.changedAt = this.now();
            this.lostAt = null;
            this.mediaAt = this.now();
            return;
        }
        if (!online) {
            this.healthyAt = null;
            this.show('You’re offline. Your Windows apps stay running. Reconnecting when your internet returns.', false);
            return;
        }
        const stream = this.app.getStream();
        if (stream !== this.stream) {
            this.stream = stream;
            this.changedAt = this.now();
            this.lostAt = null;
            this.healthyAt = null;
            this.mediaCounter = null;
            this.mediaAt = this.now();
        }
        this.sampleMedia(stream);
        const peerState = stream?.transport?.peer?.connectionState;
        const mediaStalled = this.mediaCounter !== null &&
            (this.mediaCounter === 0 || this.now() - this.mediaAt >= 30000);
        const live = stream?.ws?.readyState === 1 && stream.hasVideoReady &&
            (!peerState || peerState === 'connected') && !mediaStalled;
        if (live) {
            this.lostAt = null;
            this.show('', false);
            this.healthyAt ??= this.now();
            // A brief connection does not replenish an endless retry loop.
            if (this.now() - this.healthyAt >= 30000) this.attempts = 0;
            return;
        }
        this.healthyAt = null;
        this.lostAt ??= this.now();
        const broken = stream?.ws?.readyState >= 2 || ['failed', 'closed', 'disconnected'].includes(peerState);
        const stalled = (!stream?.hasVideoReady || mediaStalled) && this.now() - this.changedAt >= 30000;
        if (!broken && !stalled) return;
        if (this.attempts >= 3 && !this.busy && (stalled || this.now() - this.lostAt >= 8000)) {
            this.show('We couldn’t reconnect. Your Windows apps stay running. Try again, or resume your desktop from the workspace.', false);
            return;
        }
        this.show('Connection interrupted. Your Windows apps stay running. Reconnecting…', this.busy);
        if (!this.busy && this.now() >= this.nextAt && (stalled || this.now() - this.lostAt >= 8000)) {
            void this.retry();
        }
    }
    dispose() { this.disposed = true; }
}

export function installStreamRecovery(app) {
    if (app.epicvmRecovery) return app.epicvmRecovery;
    const panel = document.createElement('section');
    panel.id = 'epicvm-recovery';
    panel.hidden = true;
    panel.setAttribute('aria-label', 'Connection recovery');
    panel.style.cssText = 'position:fixed;top:20px;left:50%;transform:translateX(-50%);z-index:2147483646;background:#071117;color:#e7f0f4;border:1px solid #02bdf3;border-radius:8px;padding:16px;max-width:calc(100vw - 48px);width:440px;font:15px/1.5 system-ui;box-shadow:0 4px 24px #0008';
    const message = document.createElement('p');
    message.setAttribute('role', 'status');
    message.setAttribute('aria-live', 'polite');
    const retry = document.createElement('button');
    retry.textContent = 'Try reconnecting';
    retry.style.cssText = 'padding:9px 12px;cursor:pointer;margin-right:16px';
    const back = document.createElement('a');
    back.textContent = 'Back to workspace';
    back.href = 'https://techexplore.us/EpicVM/portal';
    back.style.color = '#7ddfff';
    panel.append(message, retry, back);
    document.body.append(panel);
    for (const event of ['keydown', 'keyup', 'mousedown', 'mouseup', 'touchstart', 'touchend', 'click']) {
        panel.addEventListener(event, e => e.stopPropagation());
    }
    const recovery = new StreamRecovery(app, (text, busy) => {
        panel.hidden = !text;
        if (message.textContent !== text) message.textContent = text;
        retry.disabled = busy;
    });
    app.epicvmRecovery = recovery;
    retry.addEventListener('click', () => void recovery.retry(true));
    const timer = setInterval(() => recovery.tick(), 1000);
    const update = () => recovery.tick();
    window.addEventListener('online', update);
    window.addEventListener('offline', update);
    document.addEventListener('visibilitychange', update);
    const dispose = () => {
        recovery.dispose();
        clearInterval(timer);
        window.removeEventListener('online', update);
        window.removeEventListener('offline', update);
        document.removeEventListener('visibilitychange', update);
    };
    window.addEventListener('pagehide', dispose, { once: true });
    back.addEventListener('click', dispose);
    app.sidebar.exitStreamButton.addEventListener('click', dispose);
    return recovery;
}
