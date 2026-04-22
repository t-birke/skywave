# Skywave Airlines Agent

An Agentforce agent demo that helps customers search flights, book trips,
manage bookings, and handle support cases for a fictional airline. Includes a
public LWR Experience Cloud site with an embedded Agentforce Messaging (MIAW)
widget so customers can talk to the agent directly from the website.

## Prerequisites

- [Salesforce CLI (`sf`)](https://developer.salesforce.com/tools/salesforcecli) installed
- Authenticated into a DevHub org (`sf org login web --set-default-dev-hub`)
- [`jq`](https://jqlang.github.io/jq/) on your PATH (`brew install jq` on macOS)
- `python3` on your PATH (ships with macOS)
- Make the setup scripts executable:

  ```sh
  chmod +x orgInit.sh finalize.sh
  ```

## Getting Started

Setup is two scripts with a single Setup-wizard click in between. The
manual step exists because Salesforce does not expose a headless API for
provisioning an Embedded Service Deployment's bootstrap site.

### Step 1 — `./orgInit.sh`

```sh
./orgInit.sh
```

This does everything automatically:

- Recreates the `skywave-scratch` scratch org
- Creates the `skywave website` LWR Experience site via `sf community create`
- Deploys all metadata in two phases (core + site content)
- Creates the agent user, publishes and activates the Agentforce agent
- Patches the Bot metadata to set `BotUserId` (workaround for an
  `sf agent publish` bug that leaves it null)
- Assigns the agent user to the routing queue and presence config
- Publishes the LWR site and flips the Network to `Live`
- Loads sample data
- Opens Setup → Messaging for the manual step below

At the end it prints the exact values you need for step 2, including
your site's trusted-domain URL.

### Step 2 — Create the Messaging Channel + Deployment (manual)

In the Setup tab that opened:

1. **New Channel** → Messaging for In-App and Web
2. Pick any API name
3. Route to queue `main_queue`
4. Session handler: Agentforce agent `Skywave_Airlines_Agent`
5. Save, then **Activate** the channel
6. Setup → **Embedded Service Deployments** → **New Deployment** →
   Messaging for In-App/Web, pick the channel you just created, Save
7. In the deployment, add the Trusted Domain URL shown at the end of
   `orgInit.sh`'s output (host only, no `https://`)
8. **⚠ REQUIRED: Switch the deployment to Enhanced v2.** Without this,
   the widget will connect but immediately error on a 400 from scrt2.

### Step 3 — `./finalize.sh`

```sh
./finalize.sh
```

This:

- Verifies the wizard output (ESC + ESW site exist)
- Reads the 4 runtime values (15-char org ID, ESC developer name, ESW
  bootstrap URL, scrt2 URL)
- Bakes them into a staged copy of the `skywaveAirlinesHome` LWC
- Deploys the LWC and republishes the LWR site

Idempotent — safe to re-run if you change anything in Setup.

### Open the site

After `finalize.sh` completes, hit the LWR site URL it printed. The
messaging widget should appear in the bottom-right corner and connect
to the agent.

## Data Cloud

Data Cloud takes ~20 minutes to activate after the org is created.
Monitor progress in **Setup → Data Cloud Setup Home**. Once active,
go to **Setup → Agentforce Data Library** to create a new Data Library.

## Try it out

Ask the agent questions like:

> Find me a flight from SEA to JFK on Sunday
