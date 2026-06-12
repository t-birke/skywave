# SkywaveGlobe — 3D globe demo monitor

A spinning 3D Earth that plots live Skywave demo visitors as glowing avatars
with great-circle flight arcs, plus an N-hour time-lapse replay. Built as a
React **UIBundle** (Salesforce Multi-Framework) — the successor to the 2D
`skywaveDemoMonitor`/`skywaveWorldMap` LWCs.

> **Full docs:** see [`docs/GLOBE_MONITOR.md`](../../../../../docs/GLOBE_MONITOR.md)
> (from repo root) for architecture, file map, the Monday in-org deploy plan,
> and gotchas. This README is just the run/build/deploy commands.

## Run locally (the fast loop)

```bash
npm install          # first time
npm run dev          # Vite → http://localhost:5173
```

Requires the `si` org authed (`sf org display --target-org si`). The Vite dev
server proxies `/cometd` (live data) and `/sf-query` (replay SOQL) to the org
with a bearer token injected — no in-org deploy needed to iterate. Override the
org with `SKYWAVE_ORG=<alias> npm run dev`.

No live activity? Click **24H** in the HUD to replay the last 24h from records.

## Build

```bash
npm run build        # → dist/ (the deploy payload; gitignored, rebuild before deploy)
```

## Deploy to org (GATED until the Multi-Framework release update)

`UIBundle` metadata can't deploy until the Setup-UI feature gate is enabled
(org preference `UIBundleSettings.webAppOptIn` is already set). Once enabled —
from the **SFDX project root**:

```bash
cd force-app/main/default/uiBundles/SkywaveGlobe && npm install && npm run build && cd -
sf project deploy start --source-dir force-app/main/default/uiBundles --target-org si
```

Then launch from the App Launcher ("SkywaveGlobe"). See the Monday checklist in
`docs/GLOBE_MONITOR.md` §6 — including the in-org data-path swap (Vite proxies →
CometD same-origin / GraphQL SDK).

## Stack

React 19 · Vite · TypeScript · Tailwind · three.js + @react-three/fiber +
@react-three/drei · cometd (Streaming API) · @salesforce/sdk-data (in-org GraphQL).
