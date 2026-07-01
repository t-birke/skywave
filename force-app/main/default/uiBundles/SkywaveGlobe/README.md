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

`VITE_CONSUMER_SITE_URL` sets the origin the **join-QR** encodes. Set it to the
PUBLIC origin visitors reach the site on — the custom domain (e.g.
`https://app.skywave.flights`) when one fronts the dyno. **This must match the
Heroku `SKYWAVE_PUBLIC_ORIGIN` CORS gate.** If it's unset, the QR falls back to
deriving the raw Heroku host from `VITE_RELAY_WS_URL` — and if a custom domain is
the CORS origin, phones then land on the wrong origin and every POST
(`session/peek`, `session/init`) is 403'd: returning visitors are misclassified
as new, the survey re-runs, and the survey identity splits from the
chat/booking identity. Omit it only for single-origin installs (no custom domain).

```bash
# point at YOUR provisioned relay + the public site origin:
VITE_RELAY_WS_URL="wss://<your-dyno>.herokuapp.com/ws/monitor" \
VITE_CONSUMER_SITE_URL="https://app.skywave.flights" \
  npm run build
# → dist/ (the deploy payload; gitignored, rebuild before deploy)
```

## Deploy to org

**Normally handled by `install.sh` Tier 4** (`./install.sh --with-globe` or
`--all`): it builds with the relay URL and deploys the bundle + app + permset +
CSP. The manual steps below are the same thing by hand (for iteration).

**Prerequisite:** enable the Multi-Framework UIBundle app domain
(`*.salesforce.app`) in Setup on the target org first, or the bundle won't serve.
The globe is **excluded from the Tier 1 blanket deploy** (a block in the root
`.forceignore`) because its `dist/` must be built first and the app references
the bundle — so deploy the whole set together. From the **SFDX project root**,
rebuild then deploy (note: the root `.forceignore` block must be temporarily
removed for the app/permset/CSP to deploy — Tier 4 does this automatically):

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
