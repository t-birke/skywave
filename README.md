# Skywave Airlines Agent

An Agentforce agent demo that helps customers search flights, book trips,
manage bookings, and handle support cases for a fictional airline. Includes
a public LWR Experience Cloud site with an embedded Agentforce Messaging
(MIAW) widget so customers can talk to the agent directly from the website.

> **New here?** Read [`ARCHITECTURE.md`](ARCHITECTURE.md) for how the pieces
> fit together (data flows, components, and the moving parts that aren't in
> git). [`SKYWAVE_INTERACTIVE_DESIGN.md`](SKYWAVE_INTERACTIVE_DESIGN.md) has
> the demo vision; [`docs/STYLE_GUIDE.md`](docs/STYLE_GUIDE.md) the visual
> language for new UI; [`SECRETS.md`](SECRETS.md) covers credentials.

## Installing the demo

The demo installs into a **Salesforce Demo Org (SDO)** — not a scratch org —
because the observability tier needs Data Cloud, which SDOs ship with. One
canonical, idempotent, resumable script (`install.sh`) does everything; a
companion Claude skill (`.claude/skills/skywave-install`) conducts it and
handles the few interactive gates. If you have Claude Code, just open this repo
and say **"install Skywave"** — the skill takes over.

### Prerequisites

- [Salesforce CLI (`sf`)](https://developer.salesforce.com/tools/salesforcecli) — v2, not `sfdx`
- An **SDO with Data Cloud**, authenticated and aliased `si`:
  `sf org login web --alias si --set-default`
- [`jq`](https://jqlang.github.io/jq/) and `python3` on your PATH (`brew install jq`; python3 ships with macOS)
- Node.js 18+/20, then `npm install && npx playwright install chromium`
  (Playwright drives the two headless-browser gates: ESD Publish + Data Cloud
  stream refresh)
- For the Heroku tier only: the `heroku` CLI, logged in (`heroku login`)

```sh
npm install
npx playwright install chromium
git config core.hooksPath .githooks   # ARCHITECTURE.md drift reminder on commit
./install.sh --check-prereqs          # green/red check for the selected tier
```

> You do **not** need the internal observability QBrix or a corporate GitHub
> token — that metadata is vendored into `vendor/sdo-agentforce-observability/`.

### Getting started

```sh
./install.sh                       # Tier 1: core demo (agent, MIAW chat, sites, data)
./install.sh --with-observability  # + Data Cloud session-tracing dashboards (adds a ~2–3h wait)
./install.sh --with-heroku         # + live-feed / globe / preflight relay
./install.sh --all                 # all three
./install.sh --resume              # continue after any gate (idempotent — always safe)
```

**Tier 1 (core)** recreates nothing destructively — it find-or-creates the agent
user, the `skywave website` LWR site, deploys all metadata (vendored ESW
bootstrap site, MessagingChannel, Apex/LWC/objects/flows/agent bundle, CSP/CORS),
publishes + activates the agent (patching `BotUserId`), creates the
`Skywave_MIAW_Deployment` Embedded Service config via the Tooling API
(`clientVersion=WebV2`, no "Switch to v2" click), seeds idempotent booking /
seatmap / route data, publishes the ESD (Playwright), bakes the ESW config into
the homepage LWC, and enables guest access. When it finishes it prints the
customer-site URL — hard-refresh (Cmd+Shift+R) to clear the LWR bundle cache; the
chat widget appears bottom-right and routes to `Skywave_Airlines_Agent`.

### The interactive gates

A handful of steps need a human or a Claude-only tool; `install.sh` pauses at
each with a clear message, and the skill knows how to clear them. After clearing
one, re-run with `--resume`:

- **SDO auth** — provision/authenticate the org if absent.
- **ESD Publish** — Salesforce exposes no public API for the deployment's
  "Publish" button ([PLATFORM_FEEDBACK.md #10](PLATFORM_FEEDBACK.md)), so it's
  clicked headlessly via `scripts/publishEmbeddedServiceDeployment.mjs`; falls
  back to a Setup deep-link.
- **STDM provisioning wait** (observability) — ~2–3h async; the script exits and
  you resume with `--check-stdm` / `--resume`.
- **Data-kit instantiation** (observability) — the skill runs it via the data360
  MCP, with a Setup → Data Kits UI fallback.
- **Stream Full Refresh** (observability) — `scripts/refreshDataStreams.mjs`, with
  a Dev Console Apex fallback.
- **Heroku keys** — the Connected App cert + MIAW JWK upload are manual Setup steps.

See `.claude/skills/skywave-install/SKILL.md` for the full gate playbook.

> The legacy scratch-org installer `orgInit.sh` is kept for reference only; the
> SDO path above (`install.sh`) supersedes it.

## Data Cloud

Data Cloud takes ~20 minutes to activate after the org is created.
Monitor progress in **Setup → Data Cloud Setup Home**. Once active,
go to **Setup → Agentforce Data Library** to create a new Data Library.

## Try it out

Ask the agent questions like:

> Find me a flight from SEA to JFK on Sunday
