/**
 * The Heroku consumer-site origin the join QR points phones at.
 *
 * It's the SAME Heroku app that serves the relay WebSocket (skywave-app serves
 * both the visitor website and `/ws/monitor`), so we derive it from the
 * build-time `VITE_RELAY_WS_URL` (`wss://<dyno>.herokuapp.com/ws/monitor`) by
 * swapping the scheme and dropping the path — no new build env required. This
 * mirrors the 2D `skywaveDemoMonitor` LWC, whose QR encodes
 * `Skywave_HerokuConfig.originUrl() + '?ds=' + <activeSessionId>`.
 *
 * An explicit `VITE_CONSUMER_SITE_URL` overrides the derivation (e.g. when the
 * site is fronted by a custom domain like app.skywave.flights).
 */
export function consumerSiteOrigin(): string {
  const explicit = import.meta.env?.VITE_CONSUMER_SITE_URL as string | undefined;
  if (explicit) return explicit.replace(/\/+$/, '');

  const ws = import.meta.env?.VITE_RELAY_WS_URL as string | undefined;
  if (!ws) return '';
  try {
    const u = new URL(ws);
    const scheme = u.protocol === 'wss:' ? 'https:' : 'http:';
    return `${scheme}//${u.host}`;
  } catch {
    return '';
  }
}

/**
 * Full join URL for a given active demo session, or '' if the origin or the
 * session id can't be resolved. The `ds` tenant key scopes every call from the
 * scanning phone to this presenter's Demo_Session__c (multi-tenancy).
 */
export function joinUrl(sessionId: string | null | undefined): string {
  const origin = consumerSiteOrigin();
  if (!origin || !sessionId) return '';
  return `${origin}/?ds=${encodeURIComponent(sessionId)}`;
}
