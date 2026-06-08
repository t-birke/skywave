// Tracks live WebSocket connections keyed by sessionId, fans out
// platform-event payloads to either a specific phone or all phones.
//
// Keep-alive: Heroku's router kills idle WebSockets after 55s (H15).
// We send a ping frame every 30s; the ws library auto-replies pong,
// resetting the idle timer. A socket that misses two pings (60s) is
// presumed dead and terminated so a stale entry doesn't block fan-out.

const sockets = new Map(); // sessionId -> WebSocket

export function register(sessionId, ws) {
    sockets.set(sessionId, ws);
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('close', () => {
        if (sockets.get(sessionId) === ws) sockets.delete(sessionId);
    });
}

// Run a heartbeat sweep over every connection. Call once on startup.
export function startHeartbeat(intervalMs = 30000) {
    setInterval(() => {
        for (const [sid, ws] of sockets.entries()) {
            if (ws.isAlive === false) {
                console.warn(`ws ${sid} missed pong → terminating`);
                ws.terminate();
                sockets.delete(sid);
                continue;
            }
            ws.isAlive = false;
            try { ws.ping(); } catch (_) { /* socket may have just closed */ }
        }
    }, intervalMs);
}

export function fanOut(payload, targetSessionId) {
    const message = JSON.stringify(payload);
    if (targetSessionId) {
        const ws = sockets.get(targetSessionId);
        if (ws && ws.readyState === ws.OPEN) ws.send(message);
        return;
    }
    for (const ws of sockets.values()) {
        if (ws.readyState === ws.OPEN) ws.send(message);
    }
}

export function activeCount() {
    return sockets.size;
}
