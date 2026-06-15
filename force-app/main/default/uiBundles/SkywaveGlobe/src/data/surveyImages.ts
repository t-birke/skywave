/**
 * Survey option → thumbnail image map.
 *
 * `survey_answer` events (and the persisted Skywave_Survey_Json__c) only carry
 * questionKey/answerKey — the image lives on Survey_Answer_Option__c.Image_Url__c.
 * Fetch the map once (UI API GraphQL via @salesforce/sdk-data; see ./graphql)
 * and resolve `"<questionKey>:<answerKey>"` → URL, exactly like the LWC
 * monitor's getOptionImageMap did.
 *
 * Note: UI API GraphQL can't filter on a parent-relationship field in `where`,
 * so we filter on the option's own Active__c and keep only rows whose parent
 * question is active client-side.
 */
import { queryEdges, v } from './graphql';

export type OptionImageMap = Record<string, string>;

interface OptionNode {
  Option_Key__c: { value: string | null } | null;
  Image_Url__c: { value: string | null } | null;
  Survey_Question__r: {
    Question_Key__c: { value: string | null } | null;
    Active__c: { value: boolean | null } | null;
  } | null;
}

let cache: OptionImageMap | null = null;
let inflight: Promise<OptionImageMap> | null = null;

export function optionImageKey(questionKey: string, answerKey: string): string {
  return `${questionKey}:${answerKey}`;
}

export async function loadOptionImageMap(): Promise<OptionImageMap> {
  if (cache) return cache;
  if (inflight) return inflight;

  inflight = queryEdges<OptionNode>(
    `query {
      uiapi { query {
        Survey_Answer_Option__c(first: 500, where: { and: [
          { Active__c: { eq: true } },
          { Image_Url__c: { ne: null } }
        ] }) {
          edges { node {
            Option_Key__c { value }
            Image_Url__c { value }
            Survey_Question__r { Question_Key__c { value } Active__c { value } }
          } }
        }
      } }
    }`,
    'Survey_Answer_Option__c'
  )
    .then(nodes => {
      const map: OptionImageMap = {};
      for (const n of nodes) {
        const qk = v(n.Survey_Question__r?.Question_Key__c);
        const active = v(n.Survey_Question__r?.Active__c);
        const ok = v(n.Option_Key__c);
        const url = v(n.Image_Url__c);
        if (qk && ok && url && active !== false) {
          map[optionImageKey(qk, ok)] = url;
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
