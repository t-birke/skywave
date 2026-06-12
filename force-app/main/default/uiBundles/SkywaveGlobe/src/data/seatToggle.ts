/**
 * Inconspicuous seat-capability toggle for the demo globe.
 *
 * The Skywave_Airlines_Agent gates its seat-change subagent on
 * Demo_Session__c.State__c == 'agent_seat_pass' (read per turn by the
 * Skywave_CheckSeatEnabled router action). Flipping that picklist turns
 * seat-change ON/OFF for every OPEN chat session on the visitor's next
 * message — no reload, no agent version switch. This helper drives that
 * flip from the globe HUD.
 *
 * DEV/DEMO transport: same-origin /sf-query (read) and /sf-data (PATCH),
 * which the Vite dev server proxies to the org with a Bearer token
 * injected (see vite.config.ts). No empApi, no Heroku relay.
 */

const SEAT_ON = 'agent_seat_pass';
const SEAT_OFF = 'agent_seat_fail';

interface QueryResponse<T> {
  records: T[];
}

interface ActiveSessionRow {
  Id: string;
  State__c: string | null;
}

/** Resolve the active Demo_Session__c (Active__c=true, newest Started__c). */
async function fetchActiveSession(): Promise<ActiveSessionRow | null> {
  const soql =
    "SELECT Id, State__c FROM Demo_Session__c WHERE Active__c = true " +
    'ORDER BY Started__c DESC NULLS LAST LIMIT 1';
  const res = await fetch(`/sf-query?q=${encodeURIComponent(soql)}`, {
    headers: { Accept: 'application/json' },
  });
  if (!res.ok) {
    throw new Error(`active-session query failed: ${res.status}`);
  }
  const data = (await res.json()) as QueryResponse<ActiveSessionRow>;
  return data.records?.[0] ?? null;
}

/** Whether the active session currently has seat-change enabled. */
export async function isSeatEnabled(): Promise<boolean> {
  const row = await fetchActiveSession();
  return row?.State__c === SEAT_ON;
}

/**
 * Flip seat-change capability on the active demo session. Pass the desired
 * state, or omit to toggle relative to the current value. Returns the new
 * enabled state. Throws if there is no active session.
 */
export async function setSeatEnabled(enabled?: boolean): Promise<boolean> {
  const row = await fetchActiveSession();
  if (!row) {
    throw new Error('no active Demo_Session__c to toggle');
  }
  const currentlyOn = row.State__c === SEAT_ON;
  const next = enabled === undefined ? !currentlyOn : enabled;
  const newState = next ? SEAT_ON : SEAT_OFF;

  const res = await fetch(`/sf-data/Demo_Session__c/${row.Id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ State__c: newState }),
  });
  // Salesforce returns 204 No Content on a successful sObject PATCH.
  if (res.status !== 204 && !res.ok) {
    throw new Error(`seat toggle failed: ${res.status} ${await res.text().catch(() => '')}`);
  }
  return next;
}
