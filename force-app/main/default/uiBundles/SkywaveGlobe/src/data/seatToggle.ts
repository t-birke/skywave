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
 * Transport: UI API GraphQL read + UI API record PATCH write via the Data SDK
 * (see ./graphql). Works natively in-org and through the official dev proxy.
 */
import { queryEdges, v, updateRecord, currentUserId } from './graphql';

const SEAT_ON = 'agent_seat_pass';
const SEAT_OFF = 'agent_seat_fail';

interface ActiveSessionNode {
  // Id is UI API leaf type ID! — selected bare, no { value } subselection.
  Id: string | null;
  State__c: { value: string | null } | null;
}

export interface ActiveSession {
  id: string;
  state: string | null;
}

/**
 * Resolve the presenter's OWN active Demo_Session__c (Active__c=true, newest
 * Started__c, scoped to the running user). Multi-tenant: two presenters each
 * see and flip only their own session's seat state. Falls back to an unscoped
 * query when the running user can't be resolved (e.g. dev proxy).
 */
export async function fetchActiveSession(): Promise<ActiveSession | null> {
  const uid = await currentUserId();
  const ownerFilter = uid ? `, { OwnerId: { eq: "${uid}" } }` : '';
  const nodes = await queryEdges<ActiveSessionNode>(
    `query {
      uiapi { query {
        Demo_Session__c(first: 1, where: { and: [ { Active__c: { eq: true } }${ownerFilter} ] },
                        orderBy: { Started__c: { order: DESC, nulls: LAST } }) {
          edges { node { Id State__c { value } } }
        }
      } }
    }`,
    'Demo_Session__c'
  );
  const n = nodes[0];
  if (!n || !n.Id) return null;
  return { id: n.Id, state: v(n.State__c) };
}

/** Whether the active session currently has seat-change enabled. */
export async function isSeatEnabled(): Promise<boolean> {
  const row = await fetchActiveSession();
  return row?.state === SEAT_ON;
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
  const currentlyOn = row.state === SEAT_ON;
  const next = enabled === undefined ? !currentlyOn : enabled;
  await updateRecord(row.id, { State__c: next ? SEAT_ON : SEAT_OFF });
  return next;
}
