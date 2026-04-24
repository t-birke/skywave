# Skywave Airlines Agent

An Agentforce agent demo that helps customers search flights, book trips,
manage bookings, and handle support cases for a fictional airline. Includes
a public LWR Experience Cloud site with an embedded Agentforce Messaging
(MIAW) widget so customers can talk to the agent directly from the website.

## Prerequisites

- [Salesforce CLI (`sf`)](https://developer.salesforce.com/tools/salesforcecli) installed
- Authenticated into a DevHub org (`sf org login web --set-default-dev-hub`)
- [`jq`](https://jqlang.github.io/jq/) on your PATH (`brew install jq` on macOS)
- `python3` on your PATH (ships with macOS)
- Node.js 18+ (for Playwright — skip if you prefer to click Publish manually)

Install Playwright + Chromium so `orgInit.sh` can click Publish headlessly
(otherwise the script will prompt you to click it):

```sh
npm install
npx playwright install chromium
chmod +x orgInit.sh scripts/createEmbeddedServiceConfig.sh
```

## Getting Started

Run one script. It pauses for a single Setup click, then finishes itself:

```sh
./orgInit.sh
```

What it does automatically:

- Recreates the `skywave-scratch` scratch org
- Creates the customer-facing `skywave website` LWR site (`sf community create`)
- Deploys all metadata in one pass — including the vendored ESW bootstrap
  site (DigitalExperienceBundle + CustomSite + Network), the
  `Skywave_Channel` MessagingChannel, Apex, LWC, objects, flows, agent
  bundle, CSP/CORS entries, and the guest profile
- Creates the agent user, publishes + activates the Agentforce agent,
  patches the Bot to set `BotUserId` (workaround for an `sf agent publish`
  bug that leaves it null)
- Activates `Skywave_Channel` via Apex (`IsActive` is read-only via the
  Metadata API); routing to the agent goes through `Skywave_Route_to_Agent`
  routing flow
- Publishes the ESW bootstrap site
- Creates the `Skywave_MIAW_Deployment` Embedded Service Deployment via the
  Tooling API with `clientVersion=WebV2` (no "Switch to Enhanced v2" click)
- Publishes the customer LWR site, flips the Network to `Live`, loads
  sample data

### The Publish step

Salesforce doesn't expose a public API for the "Publish" button on an
Embedded Service Deployment (confirmed internally — see
[PLATFORM_FEEDBACK.md #10](PLATFORM_FEEDBACK.md)). The script works
around this by driving a headless Chromium via Playwright to click
the button for you. See `scripts/publishEmbeddedServiceDeployment.mjs`.

If Playwright isn't installed, the script falls back to prompting you
to click Publish in Setup, then press Enter to continue.

### Open the site

After the script completes, hit the LWR site URL it prints. Hard-refresh
(Cmd+Shift+R) to clear the LWR bundle cache. The messaging widget should
appear bottom-right and connect to the agent.

## Data Cloud

Data Cloud takes ~20 minutes to activate after the org is created.
Monitor progress in **Setup → Data Cloud Setup Home**. Once active,
go to **Setup → Agentforce Data Library** to create a new Data Library.

## Try it out

Ask the agent questions like:

> Find me a flight from SEA to JFK on Sunday
