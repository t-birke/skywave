#!/usr/bin/env python3
"""Normalize the captured live si Data Cloud definitions into clean, canonical,
name-scrubbed POST payloads that the Tier-5 runners replay on a fresh org.

WHY: the live si definitions are the source of truth for the SHAPE of the
working pipeline, but they carry iteration artifacts that must NOT ship to a
fresh org:
  - the unified DMO is `UnifiedssotIndividualSwv2__dlm` (a "Swv2" iteration
    artifact); a clean first IR ruleset yields stock `UnifiedIndividual__dlm`.
  - DLO / mapping / relationship developer names carry per-build hash + epoch
    suffixes (e.g. _F0A96086, _1779104233235) — the platform re-mints these on
    a fresh org, so we strip them and let the runner resolve live names.
  - the Survey_Response DMO GET omits dataType; we merge the dataTypes from our
    own docs/data-cloud-dmo-survey-response.json spec with the live field SET.

INPUT:  scripts/datacloud/payloads/_raw_*.json   (captured from si)
OUTPUT: scripts/datacloud/payloads/*.json        (canonical, committed)

Run once at authoring time (and re-run if the si reference changes). The OUTPUT
files are what the runners read — the _raw_* inputs are reference only.
"""
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAY = HERE / "payloads"
DOCS = HERE.parent.parent / "docs"

# Iteration-artifact → canonical name. The Swv2 unified DMO becomes the stock one.
SWV2 = "UnifiedssotIndividualSwv2__dlm"
CANON_UNIFIED = "UnifiedIndividual__dlm"

# Strip a trailing _<hexOrEpoch> hash/epoch suffix the platform appends to
# developer names (DLOs, maps, relationships, DG runtime DMOs). Keeps the stem.
_SUFFIX = re.compile(r"_(?:[0-9A-F]{8}|\d{10,})$")


def strip_suffix(name: str) -> str:
    if not isinstance(name, str):
        return name
    return _SUFFIX.sub("", name)


def scrub(obj):
    """Recursively scrub iteration artifacts across any string value:
      - the exact Swv2 unified DMO → canonical UnifiedIndividual__dlm
      - any residual 'Swv2' substring (e.g. the derived IIL link DMO name
        UnifiedLinkssotIndividualSwv2__dlm + its field aliases) → drop 'Swv2'
        so the names match a fresh org's standard auto-derived DMOs."""
    if isinstance(obj, str):
        return obj.replace(SWV2, CANON_UNIFIED).replace("Swv2", "")
    if isinstance(obj, list):
        return [scrub(x) for x in obj]
    if isinstance(obj, dict):
        return {k: scrub(v) for k, v in obj.items()}
    return obj


def load(name):
    return json.loads((PAY / name).read_text())


def write(name, data):
    (PAY / name).write_text(json.dumps(data, indent=2) + "\n")
    print(f"  wrote payloads/{name}")


# --------------------------------------------------------------------------- #
# 1. Schema — the 6 Skywave events. Normalize to the StreamingApp PUT shape
#    (schemaType + availabilityStatus:Available, drop runtime/availability noise).
# --------------------------------------------------------------------------- #
def norm_schema():
    raw = load("_raw_schema.json")
    out = []
    for s in raw.get("schemas", []):
        out.append({
            "schemaType": "StreamingApp",
            "availabilityStatus": "Available",
            "category": s["category"],
            "name": s["name"],
            "label": s["label"],
            "fields": [{"name": f["name"], "label": f["label"], "dataType": f["dataType"],
                        "isDataRequired": f.get("isDataRequired", False),
                        "primaryIndexOrder": f.get("primaryIndexOrder", 0)}
                       for f in s.get("fields", [])],
        })
    write("schema.json", {"schemas": out})
    print(f"    {len(out)} events: {sorted((s['category'], s['name']) for s in out)}")


# --------------------------------------------------------------------------- #
# 2. Survey_Response custom DMO — live field SET + dataTypes from our spec doc.
# --------------------------------------------------------------------------- #
def norm_survey_dmo():
    live = load("_raw_survey_dmo.json")
    spec = json.loads((DOCS / "data-cloud-dmo-survey-response.json").read_text())
    spec_types = {f["name"]: f["dataType"] for f in spec["fields"]}
    spec_types_loose = {k.lower(): v for k, v in spec_types.items()}
    # System fields the platform auto-adds — never in a create payload.
    SYS = {"DataSource__c", "DataSourceObject__c", "InternalOrganization__c"}
    fields = []
    for f in live.get("fields", []):
        nm = f["name"]
        if nm in SYS or nm.startswith("KQ_"):
            continue
        dt = (f.get("dataType")
              or spec_types.get(nm)
              or spec_types_loose.get(nm.lower())
              # sensible fallback by name convention
              or ("DateTime" if "DateTime" in nm else "Text"))
        fields.append({"name": nm, "label": f.get("label") or nm.replace("__c", "").replace("_", " "),
                       "dataType": dt, "isPrimaryKey": bool(f.get("isPrimaryKey"))})
    # Guarantee exactly one PK (Id__c).
    if not any(f["isPrimaryKey"] for f in fields):
        for f in fields:
            if f["name"] == "Id__c":
                f["isPrimaryKey"] = True
    dmo = {"name": "Survey_Response", "label": live.get("label") or "Survey Response",
           "category": live.get("category") or "ENGAGEMENT",
           "dataSpaceName": live.get("dataSpaceName") or "default", "fields": fields}
    write("survey_response_dmo.json", dmo)
    print(f"    {len(fields)} fields, PK={[f['name'] for f in fields if f['isPrimaryKey']]}")


# --------------------------------------------------------------------------- #
# 3. Custom DMO relationship Survey_Response.SessionId__c → Individual.ssot__Id__c
#    (the load-bearing non-standard link; built via Metadata API FieldSrcTrgtRelationship).
# --------------------------------------------------------------------------- #
def norm_survey_rel():
    raw = load("_raw_survey_rel.json")
    rels = raw.get("relationships") or raw if isinstance(raw, list) else raw.get("relationships", [])
    rel = rels[0] if isinstance(rels, list) and rels else raw
    out = {
        "cardinality": rel.get("cardinality", "ManyToOne"),
        "sourceObject": rel.get("sourceObject", {}).get("name", "Survey_Response__dlm"),
        "sourceField": rel.get("sourceField", {}).get("name", "SessionId__c"),
        "targetObject": rel.get("targetObject", {}).get("name", "ssot__Individual__dlm"),
        "targetField": rel.get("targetField", {}).get("name", "ssot__Id__c"),
    }
    write("survey_response_relationship.json", out)
    print(f"    {out['sourceObject']}.{out['sourceField']} → {out['targetObject']}.{out['targetField']} ({out['cardinality']})")


# --------------------------------------------------------------------------- #
# 4. Mappings — field-level DLO→DMO maps, source DLO stem-resolved at runtime.
#    We keep the field pairs (the load-bearing part); the runner resolves the
#    live source-DLO dev name (hash suffix re-minted on a fresh org).
# --------------------------------------------------------------------------- #
def norm_mappings():
    # target DMO -> logical source token (resolved live by the runner)
    SRC_TOKEN = {
        "Survey_Response__dlm": "__web_engagement__",
        "ssot__ProductBrowseEngagement__dlm": "__web_engagement__",
        "ssot__PrivacyConsentLog__dlm": "__web_engagement__",
        "ssot__ContactPointEmail__dlm": "web:contactPointEmail",
        "ssot__Individual__dlm": "web:identity",
        "ssot__PartyIdentification__dlm": "web:partyIdentification",
    }
    out = []
    for dmo, token in SRC_TOKEN.items():
        raw = load(f"_raw_map_{dmo}.json")
        maps = raw.get("objectSourceTargetMaps", []) if isinstance(raw, dict) else []
        # keep only the WEB-side map (drop CRM Contact_Home / Lead_Home maps —
        # those are created by the standard CRM connector, not Tier 5).
        web = [m for m in maps if m.get("developerName", "").startswith("skywave_app")]
        for m in web:
            fps = [{"sourceFieldDeveloperName": strip_suffix(fm["sourceFieldDeveloperName"]),
                    "targetFieldDeveloperName": fm["targetFieldDeveloperName"]}
                   for fm in m.get("fieldMappings", [])]
            out.append({"targetDmo": dmo, "sourceToken": token, "fieldMappings": fps})
            print(f"    {token} → {dmo}: {len(fps)} field maps")
    write("mappings.json", scrub({"mappings": out}))


# --------------------------------------------------------------------------- #
# 5. IR ruleset — templatized (clean), Swv2 scrubbed.
# --------------------------------------------------------------------------- #
def norm_ir():
    rs = load("_raw_ir.json")["identityResolutions"][0]
    out = scrub({
        "label": rs.get("label", "Skywave Unified Individual"),
        "description": rs.get("description", ""),
        "configurationType": rs.get("configurationType", "individual"),
        "dataSpaceName": rs.get("dataSpaceName", "default"),
        "doesRunAutomatically": rs.get("doesRunAutomatically", False),
        "matchRules": rs.get("matchRules", []),
        "reconciliationRules": rs.get("reconciliationRules", []),
    })
    write("identity_resolution.json", out)
    print(f"    {len(out['matchRules'])} match rules, {len(out['reconciliationRules'])} recon rules")


# Runtime keys to DROP from each DG node/field (platform re-mints them per org).
_DG_NODE_DROP = {"id", "devName", "jsonPath", "path", "projectedName", "dependency",
                 "fragmentDMOName", "fragmentDMOLabel"}
_DG_FIELD_DROP = {"id", "devName", "dependency"}


def _clean_dg_node(node):
    """Recursively clean a live DG sourceObject node into a POST-ready shape:
    keep the canonical DMO ref + projected source fields, drop runtime ids.
    Swv2 → canonical is applied via scrub() on the whole result."""
    if not isinstance(node, dict):
        return node
    out = {}
    # Canonical, org-portable DMO identity. Prefer referenceDeveloperName (e.g.
    # "IndividualIdentityLink") — the resolved `name` is org-specific (carries the
    # Swv2 artifact on si). Keep `name` ONLY for the custom DMOs whose name == the
    # deployed dev name (Survey_Response__dlm) where there's no stable ref.
    if node.get("referenceDeveloperName"):
        out["referenceDeveloperName"] = node["referenceDeveloperName"]
    elif node.get("name"):
        out["name"] = node["name"]            # custom DMO (Survey_Response) — scrubbed below
    for k in ("label", "type", "categoryDevName", "recencyCriteria"):
        if node.get(k) not in (None, [], ""):
            out[k] = node[k]
    # projected fields — keep the real source field, drop runtime aliases
    flds = []
    for f in node.get("fields", []) or []:
        cf = {k: v for k, v in f.items() if k not in _DG_FIELD_DROP}
        # the load-bearing keys: sourceFieldName + dataType + projection flags
        flds.append(cf)
    if flds:
        out["fields"] = flds
    kids = [_clean_dg_node(c) for c in (node.get("relatedObjects") or [])]
    if kids:
        out["relatedObjects"] = kids
    return out


# --------------------------------------------------------------------------- #
# 6. Data Graph — clean POST shape, Swv2→canonical, hashed runtime DMOs dropped.
#    Node tree captured as a logical spec the runner expands.
# --------------------------------------------------------------------------- #
def norm_data_graph():
    d = load("_raw_dg.json")
    out = {
        "name": "Skywave_Customers",
        "label": d.get("label", "Skywave Customers"),
        "type": "REALTIME",
        "isRealTimeToggleEnabled": True,
        "isRecordCachingDisabled": d.get("isRecordCachingDisabled", False),
        "cacheDurationInDays": d.get("cacheDurationInDays", 30),
        "maxRecordsCached": d.get("maxRecordsCached", 100000),
        "sessionEnd": d.get("sessionEnd", 120),
        "sessionEndTimeUnit": d.get("sessionEndTimeUnit", "MINUTES"),
        # root scrubbed Swv2 → canonical unified DMO
        "primaryObjectName": CANON_UNIFIED,
        "dataspaceName": d.get("dataspaceName", "default"),
        # The node tree is REPLAYED from the live si DG (scrubbed) — far more
        # reliable than reconstructing field projections (phantom fields →
        # status=ERROR). We keep referenceDeveloperName + each projected field's
        # sourceFieldName/dataType/roles, drop runtime ids/devNames/jsonPaths.
        "sourceObject": _clean_dg_node(d.get("sourceObject")),
    }
    out = scrub(out)   # Swv2 → canonical UnifiedIndividual across the whole tree
    write("data_graph.json", out)
    print(f"    {out['name']} type={out['type']} root={out['primaryObjectName']} sessionEnd={out['sessionEnd']}{out['sessionEndTimeUnit']}")


def main():
    print("Normalizing captured si payloads → canonical:")
    norm_schema()
    norm_survey_dmo()
    norm_survey_rel()
    norm_mappings()
    norm_ir()
    norm_data_graph()
    print("Done. Canonical payloads written to scripts/datacloud/payloads/*.json")


if __name__ == "__main__":
    main()
