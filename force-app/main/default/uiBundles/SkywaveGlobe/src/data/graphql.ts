/**
 * UI API GraphQL helpers — the supported in-org + dev data path.
 *
 * Replaces the custom Vite /sf-query SOQL proxy. `@salesforce/sdk-data`'s
 * createDataSDK().graphql() works the same in-org (native) and in dev (through
 * @salesforce/vite-plugin-ui-bundle's /services/data/.../graphql proxy, which
 * needs salesforce({ orgAlias }) in vite.config.ts).
 *
 * UI API wraps every record as `{ node: { Field__c: { value } } }` inside
 * `edges`, and scalar fields as `{ value }`. `queryEdges()` runs a query and
 * returns the flat node list; `v()` unwraps a scalar field.
 */
import { createDataSDK } from '@salesforce/sdk-data';
import { executeGraphQL } from '@/api/graphqlClient';

const API = '/services/data/v60.0';

/** Unwrap a UI API scalar field `{ value }` (or null). */
export function v<T = unknown>(field: { value: T } | null | undefined): T | null {
  return field ? field.value : null;
}

/**
 * Run a uiapi query and return the `edges[].node` list for the given entity.
 * The query must select `uiapi { query { <Entity>(...) { edges { node {...} } } } }`.
 */
export async function queryEdges<TNode>(query: string, entity: string): Promise<TNode[]> {
  const data = await executeGraphQL<
    { uiapi: { query: Record<string, { edges: { node: TNode }[] }> } },
    Record<string, never>
  >(query);
  const conn = data?.uiapi?.query?.[entity];
  return (conn?.edges ?? []).map(e => e.node);
}

/** A datetime value literal for a UI API `CreatedDate: { gte: { value } }` filter. */
export function sinceIso(hoursAgo: number, nowMs: number): string {
  return new Date(nowMs - hoursAgo * 3600_000).toISOString();
}

/**
 * The running user's 18-char Id, via the OIDC userinfo endpoint (the SDK's
 * authenticated fetch resolves it against the org). Used to scope the globe to
 * the presenter's OWN active Demo_Session__c (multi-tenancy). Returns null in
 * dev (where /services/oauth2 isn't proxied) or on any failure, so callers can
 * fall back to an unscoped query rather than break.
 */
export async function currentUserId(): Promise<string | null> {
  try {
    const sdk = await createDataSDK();
    if (!sdk.fetch) return null;
    const res = await sdk.fetch('/services/oauth2/userinfo');
    if (!res.ok) return null;
    const j = await res.json();
    return (j && j.user_id) || null;
  } catch {
    return null;
  }
}

/**
 * Update fields on a record via UI API (`PATCH /ui-api/records/{id}`), through
 * the SDK's fetch so auth + CSRF headers are handled (a raw fetch 401s). This
 * is the supported write path — UI API GraphQL itself is read-only.
 */
export async function updateRecord(
  recordId: string,
  fields: Record<string, unknown>
): Promise<void> {
  const sdk = await createDataSDK();
  if (!sdk.fetch) throw new Error('Data SDK fetch unavailable');
  const res = await sdk.fetch(`${API}/ui-api/records/${recordId}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ fields }),
  });
  if (!res.ok) {
    throw new Error(`record update failed: ${res.status} ${await res.text().catch(() => '')}`);
  }
}
