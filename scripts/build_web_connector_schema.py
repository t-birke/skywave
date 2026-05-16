#!/usr/bin/env python3
"""Build the Skywave Web Connector schema JSON.

Source: canonical SDK schema v260 + electra-style userProfiling event
extended with attributesQuestionKey and attributesAnswerKey.

Output: docs/web-connector-schema-skywave.json
"""
import json
from pathlib import Path

CANONICAL = Path('/tmp/web-connector-schema-260.json')
OUT = Path('/Users/tbirke/dev/is_interactive_skywave/docs/web-connector-schema-skywave.json')

# Stock events we keep verbatim from the canonical schema
KEEP = {
    'consentLog',
    'catalog',
    'contactPointEmail',
    'partyIdentification',
    'identity',
}

# Stock events we drop (kept here as comments in the JSON output for clarity)
DROP = {
    'cart',           # no on-site cart
    'cartItem',       # no on-site cart
    'order',          # booking happens via the agent, not a checkout flow
    'orderItem',      # same
    'contactPointAddress',  # profile form doesn't capture address; can add later
    'contactPointPhone',    # profile form doesn't capture phone; can add later
    'catalogTime',    # niche personalization signal we don't need
}

with CANONICAL.open() as f:
    canonical = json.load(f)

# Map by developerName for easy lookup
canonical_by_name = {r['developerName']: r for r in canonical['records']}

# --- userProfiling (CUSTOM) ---
# Electra-shaped, extended with the keys-and-text customization.
# All fields in alphabetical order to match what the Web Connector editor
# generates after parsing — keeps diffs clean if we re-export later.
user_profiling = {
    'developerName': 'userProfiling',
    'masterLabel': 'User Profiling Event',
    'category': 'Engagement',
    'externalDataTranFields': [
        {
            'masterLabel': 'Answer',
            'dataType': 'Text',
            'developerName': 'attributesAnswer',
            'isDataRequired': True,
            'isCurrencyIsoCode': False,
        },
        {
            'masterLabel': 'Answer Key',
            'dataType': 'Text',
            'developerName': 'attributesAnswerKey',
            'isDataRequired': True,
            'isCurrencyIsoCode': False,
        },
        {
            'masterLabel': 'Question',
            'dataType': 'Text',
            'developerName': 'attributesQuestion',
            'isDataRequired': True,
            'isCurrencyIsoCode': False,
        },
        {
            'masterLabel': 'Question Key',
            'dataType': 'Text',
            'developerName': 'attributesQuestionKey',
            'isDataRequired': True,
            'isCurrencyIsoCode': False,
        },
        {'masterLabel': 'category',  'dataType': 'Text',     'developerName': 'category',  'isDataRequired': True,  'isCurrencyIsoCode': False},
        {'masterLabel': 'dateTime',  'dataType': 'DateTime', 'developerName': 'dateTime',  'isDataRequired': True,  'isCurrencyIsoCode': False},
        {'masterLabel': 'deviceId',  'dataType': 'Text',     'developerName': 'deviceId',  'isDataRequired': True,  'isCurrencyIsoCode': False},
        {'masterLabel': 'eventId',   'dataType': 'Text',     'developerName': 'eventId',   'isDataRequired': True,  'primaryIndexOrder': 1, 'isCurrencyIsoCode': False},
        {'masterLabel': 'eventType', 'dataType': 'Text',     'developerName': 'eventType', 'isDataRequired': True,  'isCurrencyIsoCode': False},
        {'masterLabel': 'sessionId', 'dataType': 'Text',     'developerName': 'sessionId', 'isDataRequired': True,  'isCurrencyIsoCode': False},
    ],
}
user_profiling['fieldCount'] = len(user_profiling['externalDataTranFields'])

# Assemble final record list in the same order as the canonical so the
# upload is friendlier on the eyes when reviewed in the editor.
records = []
for name in [r['developerName'] for r in canonical['records']]:
    if name in KEEP:
        rec = canonical_by_name[name]
        # Strip availability metadata that the editor will set itself.
        rec = {k: v for k, v in rec.items() if k not in ('availabilityStatus', 'availabilityStatusLabel', 'streamingAppLabel')}
        records.append(rec)
# Append userProfiling at the end (it's the custom one, not part of canonical)
records.append(user_profiling)

out = {'records': records}

OUT.parent.mkdir(parents=True, exist_ok=True)
with OUT.open('w') as f:
    json.dump(out, f, indent=2)
    f.write('\n')

# Self-check
print(f'Wrote {OUT} with {len(records)} records:')
for r in records:
    print(f"  {r['developerName']:24s} ({r['category']:12s}) {r.get('fieldCount','?')} fields")
