#!/usr/bin/env python3
"""
Regenerate Skywave_Demo_Admin field/object permissions.

WHY THIS EXISTS
---------------
Modern Salesforce grants NO field-level security on new custom fields, even
to System Administrator, and describe/SOQL HIDE no-FLS fields entirely — so a
freshly-deployed field looks like it doesn't exist (INVALID_FIELD: No such
column). The presenter/admin (and every anonymous-Apex seed script, which
runs in the admin's FLS context) hits this constantly.

DEFAULT RULE: every custom object/field we create gets full access on the
`Skywave_Demo_Admin` permission set. Rather than hand-add entries one at a
time, this script enumerates fields via the Tooling API and regenerates the
<fieldPermissions>/<objectPermissions> blocks wholesale, preserving every
other grant (tabs, classes, app visibility) already in the permset file.

WHAT IT DOES
------------
  * Full object access (CRUD + viewAll/modifyAll) for each object in OUR_OBJECTS.
  * Read+edit FLS for every custom field on those objects, plus the whitelisted
    custom fields on standard objects (Contact, VoiceCall).
  * editable=false for Formula/Auto-Number/Roll-Up/Summary (can't be edited).
  * EXCLUDES universally-required + master-detail fields entirely — they have
    implicit FLS and cause a deploy error if listed. (Checkboxes report
    IsNillable=false too but DO take FLS, so they are kept.)

USAGE
-----
  1. Add any new object to OUR_OBJECTS / new standard-object field to STD_FIELDS.
  2. python3 scripts/regen-demo-admin-fls.py [org-alias]      # default alias: si
  3. sf project deploy start --target-org <alias> \
         --metadata PermissionSet:Skywave_Demo_Admin

Re-runnable and idempotent. See SECRETS.md / ARCHITECTURE.md and the memory
entry `feedback-demo-admin-grant-all-custom-fls`.
"""

import json, subprocess, re, sys

ORG = sys.argv[1] if len(sys.argv) > 1 else 'si'
PERMSET = 'force-app/main/default/permissionsets/Skywave_Demo_Admin.permissionset-meta.xml'

# Our own custom objects — get full object access + all custom fields.
OUR_OBJECTS = ['Booking_Segment__c', 'Booking__c', 'Demo_Session__c', 'Flight__c',
               'Skywave_Seat_Map__c', 'Survey_Answer_Option__c', 'Survey_Question__c']

# Standard objects — only the custom fields WE added (whitelist; no object perms).
STD_FIELDS = {
    'Contact': ['ContactCardPicture__c', 'ContactCardBackground__c', 'ContactCardHealthScore__c',
                'ContactCardTags__c', 'Demo_Session__c', 'Loyalty_Points__c', 'Member_Number__c',
                'Membership_Start_Date__c', 'Membership_Tier__c', 'Phone_Digits__c', 'Session_Id__c',
                'Skywave_Conversation_Id__c', 'Skywave_Survey_Json__c', 'Skywave_Survey_Summary__c',
                'Profile_Completed__c',
                'Geo_Region__c', 'Geo_Latitude__c',
                'Geo_Longitude__c', 'Home_Airport__c'],
    'VoiceCall': ['Caller_FirstName__c', 'Caller_LastName__c', 'Caller_Salutation__c'],
}


def q(soql):
    out = subprocess.run(['sf', 'data', 'query', '--target-org', ORG, '--use-tooling-api', '--json', '-q', soql],
                         capture_output=True, text=True)
    t = out.stdout
    i = t.find('{')
    if i == -1:
        raise RuntimeError('sf query returned no JSON (org=%s):\n%s' % (ORG, out.stderr or t))
    return json.loads(t[i:])['result']['records']


def editable(dt, calc):
    return not (calc or any(k in (dt or '') for k in ('Formula', 'Auto Number', 'Roll-Up', 'Summary')))


# Universally-required fields & master-detail have implicit FLS and CANNOT appear in
# fieldPermissions (deploy error). Checkboxes report IsNillable=false too but DO take
# FLS — exclude those false positives.
inlist = "','".join(OUR_OBJECTS + list(STD_FIELDS))
REQUIRED = set()
for r in q("SELECT EntityDefinition.QualifiedApiName, QualifiedApiName, DataType FROM FieldDefinition "
           "WHERE EntityDefinition.QualifiedApiName IN ('%s') AND QualifiedApiName LIKE '%%__c' "
           "AND IsNillable=false AND DataType != 'Checkbox'" % inlist):
    REQUIRED.add(r['EntityDefinition']['QualifiedApiName'] + '.' + r['QualifiedApiName'])

field_perms = {}  # api -> editable
for o in OUR_OBJECTS:
    for r in q("SELECT QualifiedApiName, DataType, IsCalculated FROM FieldDefinition "
               "WHERE EntityDefinition.QualifiedApiName='%s' AND QualifiedApiName LIKE '%%__c'" % o):
        field_perms[o + '.' + r['QualifiedApiName']] = editable(r.get('DataType'), r.get('IsCalculated'))
for o, wl in STD_FIELDS.items():
    recs = {r['QualifiedApiName']: r for r in
            q("SELECT QualifiedApiName, DataType, IsCalculated FROM FieldDefinition "
              "WHERE EntityDefinition.QualifiedApiName='%s' AND QualifiedApiName LIKE '%%__c'" % o)}
    for fn in wl:
        r = recs.get(fn)
        if r:
            field_perms[o + '.' + fn] = editable(r.get('DataType'), r.get('IsCalculated'))
        else:
            print('  WARN missing in org:', o + '.' + fn)

src = open(PERMSET).read()

# Strip all existing <fieldPermissions> and <objectPermissions> blocks; keep everything else.
src = re.sub(r'[ \t]*<fieldPermissions>.*?</fieldPermissions>\n', '', src, flags=re.S)
src = re.sub(r'[ \t]*<objectPermissions>.*?</objectPermissions>\n', '', src, flags=re.S)

# Build fresh blocks.
ob = []
for o in OUR_OBJECTS:
    ob.append('    <objectPermissions>\n        <object>%s</object>\n        <allowCreate>true</allowCreate>\n        <allowDelete>true</allowDelete>\n        <allowEdit>true</allowEdit>\n        <allowRead>true</allowRead>\n        <modifyAllRecords>true</modifyAllRecords>\n        <viewAllRecords>true</viewAllRecords>\n    </objectPermissions>' % o)
fb = []
for api in sorted(field_perms):
    if api in REQUIRED:
        continue  # implicit FLS — must not be listed
    fb.append('    <fieldPermissions>\n        <editable>%s</editable>\n        <field>%s</field>\n        <readable>true</readable>\n    </fieldPermissions>' % ('true' if field_perms[api] else 'false', api))

# Insert before </PermissionSet>.
inject = '\n'.join(ob + fb) + '\n'
src = src.replace('</PermissionSet>', inject + '</PermissionSet>')
open(PERMSET, 'w').write(src)
print('Regenerated %s' % PERMSET)
print('  objects:', len(OUR_OBJECTS), '| fields listed:', len([a for a in field_perms if a not in REQUIRED]),
      '| excluded (required/MD):', len([a for a in field_perms if a in REQUIRED]))
