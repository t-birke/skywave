/**
 * Survey option → thumbnail image map.
 *
 * `survey_answer` events (and the persisted Skywave_Survey_Json__c) only carry
 * questionKey/answerKey — the image lives on Survey_Answer_Option__c.Image_Url__c.
 * Fetch the map once (via the /sf-query dev proxy; GraphQL SDK in-org) and
 * resolve `"<questionKey>:<answerKey>"` → URL, exactly like the LWC monitor's
 * getOptionImageMap did.
 */

export type OptionImageMap = Record<string, string>;

interface OptionRow {
  Option_Key__c: string | null;
  Image_Url__c: string | null;
  Survey_Question__r: { Question_Key__c: string | null } | null;
}

let cache: OptionImageMap | null = null;
let inflight: Promise<OptionImageMap> | null = null;

export function optionImageKey(questionKey: string, answerKey: string): string {
  return `${questionKey}:${answerKey}`;
}

export async function loadOptionImageMap(): Promise<OptionImageMap> {
  if (cache) return cache;
  if (inflight) return inflight;

  const query = `SELECT Option_Key__c, Image_Url__c, Survey_Question__r.Question_Key__c
                 FROM Survey_Answer_Option__c
                 WHERE Active__c = true AND Survey_Question__r.Active__c = true
                   AND Image_Url__c != null
                 LIMIT 500`;

  inflight = fetch(`/sf-query?q=${encodeURIComponent(query)}`, {
    headers: { Accept: 'application/json' },
  })
    .then(async res => {
      if (!res.ok) throw new Error(`option map query failed: ${res.status}`);
      const data = (await res.json()) as { records: OptionRow[] };
      const map: OptionImageMap = {};
      for (const o of data.records ?? []) {
        const qk = o.Survey_Question__r?.Question_Key__c;
        if (qk && o.Option_Key__c && o.Image_Url__c) {
          map[optionImageKey(qk, o.Option_Key__c)] = o.Image_Url__c;
        }
      }
      cache = map;
      return map;
    })
    .catch(err => {
      console.error('[surveyImages] load failed', err);
      inflight = null;
      return {};
    });

  return inflight;
}
