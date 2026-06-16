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

Requires the target org authed (`sf org display --target-org si`). The
`salesforce({orgAlias})` Vite plugin proxies `/services/data` (GraphQL reads/
writes) to the org — no in-org deploy needed to iterate. The LIVE feed is the
relay `wss://…/ws/monitor` WebSocket (same as in-org, no proxy); point dev at a
different relay via `VITE_RELAY_WS_URL`. Override the org with
`SKYWAVE_ORG=<alias> npm run dev`.

No live activity? Click **7D**/**30D** in the HUD to replay from records.

## Build

`VITE_RELAY_WS_URL` is **required** at build time — the relay host carries a
per-install Heroku hash, so there is no hardcoded default. Without it the globe
loads but the live feed never connects (it logs an error and stays idle).

```bash
# point at YOUR provisioned relay (see install.sh Tier 3 output / heroku apps:info):
VITE_RELAY_WS_URL="wss://<your-dyno>.herokuapp.com/ws/monitor" npm run build
# → dist/ (the deploy payload; gitignored, rebuild before deploy)
```

## Deploy to org

**Target: prod (`si`) only** — the globe is NOT part of `install.sh`; deploy it
separately. **Prerequisite:** enable the Multi-Framework UIBundle app domain
(`*.salesforce.app`) in Setup on the target org first, or the bundle won't serve.
From the **SFDX project root**, rebuild then deploy the bundle (+ the launch
app/permset + the wss CSP trusted site the first time):

```bash
cd force-app/main/default/uiBundles/SkywaveGlobe && npm install && npm run build && cd -
sf project deploy start --target-org si \
  --source-dir force-app/main/default/uiBundles/SkywaveGlobe \
              force-app/main/default/applications/Skywave_Globe.app-meta.xml \
              force-app/main/default/permissionsets/Skywave_Globe_App.permissionset-meta.xml \
              force-app/main/default/cspTrustedSites/Skywave_Globe_Relay_Wss.cspTrustedSite-meta.xml
sf org assign permset --name Skywave_Globe_App --target-org si   # org-side; not in the deploy
```

Then launch **Skywave Globe** from the App Launcher. The live feed also needs
the relay deployed (`git push heroku …`) — see `docs/GLOBE_MONITOR.md` §6.

## Stack

React 19 · Vite · TypeScript · Tailwind · three.js + @react-three/fiber +
@react-three/drei · WebSocket (Heroku relay live feed) · @salesforce/sdk-data
(in-org UI API GraphQL).
