# Vendored: SDO Agentforce Observability metadata

This directory contains Salesforce metadata **vendored** (copied into this repo so
we control it) from an internal Q-Branch demo QBrix. We vendor it so recipients of
the Skywave Interactive demo do **not** need to install the QBrix themselves, and so
the observability layer is fully reproducible from this repo's `install.sh`.

## Provenance

| | |
|---|---|
| Source repo | `sfdc-qbranch-emu/QBrix-6-SDO-AgentforceAnalytics` |
| Source commit | `995061b9fd9d1685e37021fe62a228a1972c7140` (2026-06-09) |
| License | Apache-2.0 (`Copyright (c) 2023, Salesforce, Inc.`) |
| Vendored on | 2026-06-16 |

The orchestrating QBrix the demo was originally built against was
`sfdc-qbranch-emu/Brix-4-SDO-AF-Observability-AEA-Data`, a thin CumulusCI/QX wrapper
whose own `force-app` is empty — its real metadata payload lives in QBrix-6 (above),
which is what we vendored. Neither internal repo is needed to install this demo.

## What's here

Copied verbatim from QBrix-6 (`unpackaged/pre/default/` + `force-app/main/default/`):

- **CRM tier** — 12 custom objects (`SDO_Analytics_*_v2__c` + `SDO_AFO_Bot__c`),
  4 Apex classes (`SDO_Analytics_DataStreamNavigator`, `QuickAccessSession`,
  `SessionAudio`, `SyntheticSessionSearch`) + 4 matching LWCs, the
  `SDO_Agentforce_Observability_Demo` Lightning app, 13 tabs, 12 layouts,
  2 flexipages, and the `SDO_Agentforce_Analytics` permission set.
- **Data Cloud tier** — `CustomerDataPlatform.settings` (enables Data Cloud),
  1 `dataPackageKitDefinition` (`SDO_Agentforce_Observability`, ships
  `isDeployed=false`/`isEnabled=false`), 15 `DataPackageKitObjects`,
  12 `dataStreamTemplates`, 144 `dataSrcDataModelFieldMaps`, 12 `dataSourceObjects`,
  3 `dataSourceBundleDefinitions` (`SDO_AFO_STDM`/`Optimization`/`Extra`),
  1 `mktDataSources`.

## Deliberate changes from the source

- **Admin profile patch dropped.** QBrix-6 shipped an `Admin.profile` patch
  (`unpackaged/post/profiles/Admin.profile-meta.xml`) granting object perms +
  4 Apex `classAccesses` + `VoiceCall`/`VoiceCallRecording` access. Deploying a full
  Admin profile into a long-lived SDO is risky (it can clobber admin
  customizations), so we **folded those grants into the `SDO_Agentforce_Analytics`
  permission set** instead. `install.sh` assigns that permset; no profile is deployed.
- **NextGen Data Tool removed.** QBrix-6's CumulusCI flow seeded synthetic data from
  an internal Heroku "NextGen Data Tool" by UUID. We replaced that entirely with our
  own Skywave-branded data: `Skywave_ObservabilitySeeder` (Apex, in `force-app`) +
  the `skywave-observability-dataset/` CSVs (portable fallback).

## Timestamped developer names

Some Data Cloud files carry timestamped developer names (e.g.
`SDO_Analytics_AIAgentSession_v2_c_Home_1780493273440`). These are **intentionally
preserved verbatim** — the `dataStreamTemplate`/`dataSourceObject` files cross-reference
each other by those exact names, and the kit deploys with stable keys
(`developerName: SDO_Agentforce_Observability`). They are filename artifacts, not
org-specific instance Ids; renaming would break the cross-references. Only regenerate
these names if re-pulling from a newer QBrix-6.

## Removing this entirely

To drop the observability layer: delete this directory and remove the
`vendor/sdo-agentforce-observability` entry from `sfdx-project.json` (and the two
`!vendor/...` negations in `.forceignore`). Nothing in `force-app/` depends on it
except the observability tier of `install.sh` and the `Skywave_Observability*` /
`Skywave_DataStreamRunner` Apex classes.
