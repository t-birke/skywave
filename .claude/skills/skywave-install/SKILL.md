---
name: skywave-install
description: "Conductor for installing the Skywave Interactive Agentforce demo into a Salesforce Demo Org (SDO) end-to-end — core demo (agent + MIAW chat + Experience Cloud sites + data), optional Data Cloud observability dashboards, the optional Heroku preflight/consumer-site relay, and the optional 3D globe demo-monitor UIBundle. TRIGGER when: the user has cloned the is_interactive_skywave repo and wants to stand the demo up; says 'install Skywave', 'set up the demo', 'run the installer', 'get the demo working on my SDO'; is resuming an install after the Data Cloud provisioning wait; or hits a gate (ESD publish, data-kit instantiation, stream refresh, Heroku config, globe app-domain) and needs guidance. DO NOT TRIGGER when: the user is editing the demo's agent/Apex/LWC source (that's normal dev work), debugging a specific runtime failure in an already-installed demo, or asking about a different project."
license: MIT
metadata:
  version: "0.1.0"
  author: "Tom Birke"
  last_updated: "2026-06-16"
---

# skywave-install

## What this skill is for

Standing up the **Skywave Interactive** demo from a clean clone into a Salesforce
Demo Org. You are a **conductor**, not a script author: the repo's `install.sh` is
the single source of truth for every command. Your job is to run it, read its
output, and handle the handful of **gates** where a human or a Claude-only tool
(an MCP call, a headless browser, a Setup click) is required. The script is
idempotent and resumable, so you never have to reconstruct state by hand.

**Do not reimplement install.sh's commands in chat.** If a step needs doing, run
the script (or the relevant tier). The only things this skill spells out are the
gates — because those are stable platform constraints, not demo content, so they
don't change when the demo evolves.

## How install.sh is structured (read it first)

Open `install.sh` and skim the section banners. It has four tiers and a few modes:

```
./install.sh                       # Tier 1: core demo (agent, MIAW, sites, data)
./install.sh --with-observability  # + Tier 2: Data Cloud session-tracing dashboards
./install.sh --with-heroku         # + Tier 3: preflight relay + consumer-site backend
./install.sh --with-globe          # + Tier 4: 3D globe demo-monitor UIBundle (needs Tier 3's relay)
./install.sh --all                 # all four
./install.sh --resume              # skip already-completed sections (use after any gate)
./install.sh --check-stdm          # poll: is Data Cloud STDM ready yet? (exit 0/1)
./install.sh --check-prereqs       # green/red tool check for the selected tier
```

Progress + derived values persist to `.deploy-tmp/install-state.env`, so
`--resume` continues exactly where a gate paused — even in a brand-new session.

## Procedure

1. **Pick the tier with the user.** Ask whether they want core only, core +
   observability, or everything (+ Heroku). Default to core unless they say more.
   Observability adds a **2–3 hour async wait** (Data Cloud STDM provisioning), so
   flag that before choosing it.

2. **Prereqs.** Run `./install.sh --check-prereqs` (with the tier flags). Resolve
   anything red before proceeding. (`gh`/corp token are NOT needed by end users —
   the observability metadata is already vendored in `vendor/`.)

3. **Run the tier.** Invoke `install.sh` with the chosen flags. Watch stdout for
   the section banners and for any `[GATE]` line. Let it run unattended through the
   fully-scripted sections.

4. **At each gate, do the matching thing below, then `./install.sh --resume`** with
   the same tier flags to continue.

## The gates (the only places you inject judgment)

### G1 — SDO provisioning / auth  (§0.1)
If `install.sh` exits with the "no usable org aliased 'si'" banner, the user must
provision a **Salesforce Demo Org with Data Cloud** (an SDO, *not* a scratch org)
from their demo-org portal, then authenticate it:
`sf org login web --alias si --set-default`. You cannot do the portal step for
them — wait for them to confirm, then re-run. (To target a different alias, set
`ORG_ALIAS=<alias>` in the environment.)

### G2 — Publish the Embedded Service Deployment  (§1.13)
`install.sh` clicks Publish headlessly via `scripts/publishEmbeddedServiceDeployment.mjs`.
If that fails (Playwright/auth issue), the script prints a Setup deep-link — open it,
have the user click **Publish** on the `Skywave_MIAW_Deployment` deployment, then
`--resume`. Without this, the chat widget never renders on the site.

### G3 — Data Cloud STDM provisioning wait  (§2.4)  ⏳ ~2–3h
After enabling Agentforce Session Tracing, the session-tracing data model
provisions asynchronously for **2–3 hours**. `install.sh` records the start time
and exits 0 without blocking. Tell the user they can **close the session**. When
they return:
- Run `./install.sh --check-stdm` — exit 0 means ready.
- If ready, `./install.sh --all --resume` continues from §2.5.
- If not, report the elapsed minutes and ask them to come back later. Do **not**
  declare failure early — streams can sit provisioning with no visible progress.

### G4 — Data-kit instantiation  (§2.6)  ← the one to validate live
The 3 data-stream bundles (`SDO_AFO_STDM`, `SDO_AFO_Optimization`, `SDO_AFO_Extra`)
in the `SDO_Agentforce_Observability` data kit ship un-instantiated. `install.sh`
prints `DATA_KIT_INSTANTIATION_GATE …` and pauses — **you** instantiate them:

- **Preferred (automated):** use the **data360 MCP**. First check the user has
  Data Cloud integration creds in `.secrets/dc.env` (the MCP uses
  `client_credentials`, no JWT). Then: search the MCP for the data-kit family →
  list kits to find `SDO_Agentforce_Observability` → list its components →
  `deploy` each of the 3 bundles that aren't already instantiated. Pre-check
  components so you skip already-live bundles (instantiating twice can error).
- **Fallback (UI):** Setup → **Data Kits** → `SDO Agentforce Observability` →
  Components → click **Deploy** on each of the 3 bundles.

Once the bundles show live data streams, mark §2.6 done in
`.deploy-tmp/install-state.env` (`DONE_2_6=1`) and `--resume`.

> Note for the maintainer: confirm on a live org whether the MCP `deploy` actually
> instantiates `DataStreamBundle` components. If it only touches DMO-level
> components, treat the UI as the canonical path and update this section.

### G5 — Refresh the data streams  (§2.8, §2.9)
SalesforceDotCom streams refresh only from an **interactive browser session**, not
the CLI. `install.sh` runs `scripts/refreshDataStreams.mjs` (Playwright, frontdoor
auth → calls the run endpoint). If it fails, the fallback is the Developer Console
(browser Execute Anonymous), which has the interactive scope:
`Skywave_DataStreamRunner.refreshSdoAnalyticsStreams();` then
`Skywave_DataStreamRunner.refreshBotStreams();`. Then `--resume`.

### G6 — Heroku relay config + push  (§3.1, §3.3, §3.4)
`install.sh` creates/attaches the app, sets the config vars it can derive
(ESW values, org id, etc.), and pushes. Two manual pieces remain:
- **Keys:** confirm the public cert (`secrets/jwt.crt`) is embedded in the
  `Skywave_Heroku_Relay` Connected App, and the **MIAW public JWK is uploaded to
  the Salesforce Keyset** in Setup (authenticated chat fails silently without it).
- **Secret config vars** the script can't derive (`SF_CLIENT_ID`,
  `SF_MIAW_JWT_*`, `SKYWAVE_PROOF_KEY`, `IPINFO_TOKEN`, `CORS_PROXY_URL`): set them
  from the user's values per `.env.example` / `SECRETS.md`. Never echo secrets.

### G7 — Globe app domain  (Tier 4, §4.0)
The globe UIBundle serves from `*.salesforce.app`. That **Multi-Framework UIBundle
app domain must be enabled in Setup** (one-time, org-side — can't be scripted) or
the deploy succeeds but the app won't load. Confirm the user has enabled it, then
`--resume`. Tier 4 otherwise runs unattended: it builds the bundle with the relay
URL baked in (from Tier 3's origin — run `--with-heroku` first or in the same
`--all`), deploys the bundle + app + permset + CSP, and assigns the launcher
permset. If the user runs `--with-globe` without Tier 3, the globe is built
against a placeholder relay URL — rerun `--with-heroku --with-globe --resume`
once the dyno exists so the feed connects.

## When something breaks

- **Idempotency is your friend.** Any section can be re-run; `--resume` skips
  completed ones. If a run dies mid-tier, just `--resume`.
- **Observability data not showing in dashboards:** this is almost always G4 (kit
  not instantiated) or G5 (streams not refreshed), or the agent not being a
  deployed+activated `Skywave_Airlines_Agent` (the `ssot__Bot__dlm` join). For the
  deeper diagnosis tree, see the `observing-agentforce` skill and the
  `agentforce-observability-data` skill's `references/sdo-qbrix.md`.
- **What gets verified by a fresh-SDO run** (the ultimate test, owned by the
  maintainer): the full `--all` pipeline on a never-touched SDO. Cheap checks
  (`--check-prereqs`, vendor deploy `--dry-run`, gitignore `check-ignore`) can run
  anytime.

## What this skill deliberately does NOT contain

Individual `sf` commands, object/permset names, record IDs, or step-by-step deploy
sequences. Those live in `install.sh` and the `vendor/` + `force-app/` source. When
the demo changes, the maintainer edits those — this skill stays valid because the
gates above are platform constraints, not demo specifics.
