// Tracks live WebSocket connections keyed by sessionId, fans out
// platform-event payloads to either a specific phone or all phones.

const sockets = new Map(); // sessionId -> WebSocket

export function register(sessionId, ws) {
    sockets.set(sessionId, ws);
    ws.on('close', () => {
        if (sockets.get(sessionId) === ws) sockets.delete(sessionId);
    });
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
