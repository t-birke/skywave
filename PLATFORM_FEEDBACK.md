# Salesforce Platform Feedback: Headless Agentforce + MIAW Setup

Captured while building a fully scripted scratch-org setup for an Agentforce
agent + embedded messaging widget on an LWR Experience Cloud site. Each item
below is a concrete friction point where Salesforce could close a gap with a
CLI flag, API endpoint, or metadata support.

---

## 1. `sf agent publish authoring-bundle` doesn't wire the Bot user

**Problem.** Publishing the authoring bundle creates the runtime `Bot` and
`BotVersion` records from the `.agent` file, but `BotDefinition.BotUserId`
stays `null`. `sf agent activate` then fails with:

> This Agent Type should have a user assigned.

Even though the `.agent` file has `default_agent_user` correctly set (and
the UI shows the user assigned), the underlying `BotDefinition.BotUserId`
column on the server is never populated.

**Workaround.** After `sf agent publish`, retrieve the generated `Bot`
metadata, inject a `<botUser>` element pointing at the agent user's
username, and redeploy:

```bash
sf project retrieve start --metadata "Bot:Skywave_Airlines_Agent" --target-metadata-dir "$DIR" --unzip --json
# inject <botUser>$AGENT_USER</botUser> into Bot XML
sf project deploy start --metadata-dir "$DIR/unpackaged/unpackaged"
sf agent activate --api-name Skywave_Airlines_Agent --json
```

**Ask.** Either (a) make `sf agent publish` populate `BotUserId` from the
`.agent` file's `default_agent_user`, or (b) add `--activate` to `sf agent
publish` that does publish + wire user + activate as one atomic operation.

---

## 2. `sf org create agent-user --base-username` appends a GUID

**Problem.** `sf org create agent-user --base-username "skywaveagent@<orgId>.ext"`
creates a user called `skywaveagent.<12-char-guid>@<orgId>.ext`. This is
documented but surprising — if you try to use the base username in later
commands (e.g. `sf org assign permset --on-behalf-of`) they silently fail.

**Workaround.** Capture the actual username from the command's JSON output
and `export` it for downstream steps:

```bash
AGENT_USER=$(sf org create agent-user ... --json | jq -r '.result.username')
export AGENT_USER
```

**Ask.** Make `--base-username` produce a deterministic username. If GUID
suffixing is required for multi-tenant uniqueness, at least expose a
`--username` flag that takes the literal final username.

---

## 3. `sfdx-project.json` `replaceWithEnv` doesn't apply to `sf agent publish`

**Problem.** The top-level `sf project deploy start` honors the
`replacements` block in `sfdx-project.json`. But `sf agent publish` runs its
own internal deploy of the `.agent` bundle that **does not** apply
replacements. So `default_agent_user: "$AGENT_USER"` in the `.agent`
file gets deployed with the literal placeholder string.

**Workaround.** Deploy the agent bundle twice: once via `sf project deploy
start` (which applies replacements) and once via `sf agent publish`
(which creates the runtime artifacts). The first deploy populates the
`.agent` source in the org with the substituted value, so when `sf agent
publish` reads it, the right value is already there.

**Ask.** Make `sf agent publish` respect `sfdx-project.json` `replacements`.

---

## 4. `ExperienceBundle` vs `DigitalExperienceBundle` retrieval quirks on scratch orgs

**Problem.** LWR sites ("Build Your Own (LWR)") use `DigitalExperienceBundle`
metadata, not `ExperienceBundle` (which is Aura-only). But:

- `sf org list metadata --metadata-type ExperienceBundle` returns the LWR
  site (confusing, since it's actually the wrong type)
- `sf project retrieve start --metadata "DigitalExperienceBundle:site/<name>"`
  succeeds but returns zero files on a fresh scratch org, even when the
  metadata exists
- Only `sf project retrieve start --manifest pkg.xml --target-metadata-dir`
  (raw Metadata API path, bypassing source tracking) actually retrieves
  the content

**Workaround.** Always use `--target-metadata-dir` for LWR content and copy
files into source manually.

**Ask.** Fix source-tracking-aware retrieval of `DigitalExperienceBundle`.

---

## 5. LWR `.component` name vs MDAPI internal picasso site name

**Problem.** Deploying a `CustomSite` with `siteType=ChatterNetwork` +
`Network` pair where `Network.<picassoSite>` references a "SiteDotCom"
that doesn't exist yet hits a cyclic dependency failure:

> In field: Name - no Network named X found
> In field: PicassoSite - no SiteDotCom named X1 found

The picasso site is auto-created only when the CustomSite first
materializes on the server.

**Workaround.** Strip `<picassoSite>` from the Network XML, deploy, then
restore it and deploy Network again separately:

```bash
sed -i '' '/<picassoSite>/d' networks/X.network-meta.xml
sf project deploy start --manifest phase1.xml
git checkout -- networks/X.network-meta.xml   # or restore from backup
sf project deploy start --metadata "Network:X"
```

**Ask.** Have the MDAPI resolve intra-deploy cyclic references for this
well-known pair (it does for others).

---

## 6. `CustomSite` ChatterNetwork deploy needs standard Apex pages to pre-exist

**Problem.** Deploying a new `CustomSite` of type `ChatterNetwork` to a
scratch org fails because it references `indexPage=CommunitiesLanding`
and that Apex page doesn't exist yet:

> no ApexPage named CommunitiesLanding found

The `CommunitiesLanding` class is auto-provisioned by the platform the
first time Communities is initialized, not by the `Communities`
`features` flag in `project-scratch-def.json`.

**Workaround.** Run `sf community create --template-name "Build Your Own
(LWR)"` first (ignore the resulting site) — just to trigger the standard
Communities pages getting provisioned.

**Ask.** Either (a) provision `CommunitiesLanding` and friends when the
`Communities` scratch feature is enabled, or (b) allow `CustomSite` to
declare its own pages.

---

## 7. `sf community create` always appends `vforcesite` to the URL path prefix

**Problem.** `sf community create --url-path-prefix skywave` produces a site
accessible at `/skywavevforcesite`, not `/skywave`. Worse, passing
`--url-path-prefix skywavevforcesite` produces `/skywavevforcesitevforcesite`.
The `Site.UrlPathPrefix` field is read-only after creation, so you can't
patch it.

**Workaround.** Accept the suffix.

**Ask.** Let `--url-path-prefix` produce the literal path prefix the user
requests, without appending anything.

---

## 8. `sf project retrieve start --metadata "Profile"` returns a skeleton

**Problem.** A standalone `Profile` retrieve returns just the frontmatter
— no `classAccesses`, no `fieldPermissions`, etc. You have to include
every dependent type (ApexClass, CustomObject, CustomField, Page, etc.)
in the same retrieve to get the actual permission entries.

**Workaround.** Retrieve a fat package that includes everything:

```xml
<types><members>*</members><name>ApexClass</name></types>
<types><members>*</members><name>ApexPage</name></types>
<types><members>*</members><name>CustomObject</name></types>
<types><members>*</members><name>CustomField</name></types>
<types><members>X</members><name>Profile</name></types>
```

**Ask.** At minimum, document this clearly. Ideally, offer `sf project
retrieve start --metadata "Profile:X" --with-dependencies` that auto-pulls
referenced types.

---

## 9. Retrieved profiles contain references to Apex classes the org doesn't have

**Problem.** A guest-user profile retrieved from a fresh scratch org
contains `classAccesses` entries for `LightningForgotPasswordController`,
`LightningLoginFormController`, etc. — classes that **don't exist** in
that same scratch org. Redeploying the profile then fails with:

> no ApexClass named LightningForgotPasswordController found

**Workaround.** Grep and strip those classAccesses entries from the
retrieved profile before committing to source.

**Ask.** Either provision those Lightning `*Controller` classes in
scratch orgs when the relevant features are enabled, or stop emitting
classAccesses entries for classes that don't exist.

---

## 10. No headless endpoint to create an Embedded Service Deployment

**Problem.** An `EmbeddedServiceConfig` metadata file can only be
successfully deployed if it references an existing `<site>` (and that
site has to be the auto-generated `ESW_*` site). That ESW site is
**only** provisioned when you click through the "Messaging for In-App
and Web" wizard in Setup. Attempts via Tooling API `POST` on
`EmbeddedServiceConfig` return `"You must provide a valid Metadata
field for EmbeddedServiceConfig"` and later
`"An unexpected error occurred"`.

`CustomSite` metadata can't create an ESW site either — the site type
isn't exposed as deployable metadata.

**Workaround.** This is the one piece of the setup that stays manual.
Scripts can't avoid it; you have to click through the Setup wizard.

**Ask.** This is the single biggest friction point for fully headless
Agentforce demo setup. Expose any of:

- A CLI command: `sf embedded-service deployment create --channel X --name Y`
- A Connect API endpoint:
  `POST /services/data/vXX/connect/embedded-service/deployments`
- Or make `EmbeddedServiceConfig` metadata deployable without a
  pre-existing `<site>`, and have the deploy auto-provision the ESW site.

---

## 11. `embeddedservice_bootstrap.init()` requires the 15-char case-sensitive org ID

**Problem.** The Embedded Messaging bootstrap snippet generated by
Salesforce passes a **15-character** org ID. If you pass the
**18-character** ID that `UserInfo.getOrganizationId()` returns
(which is the idiomatic way to get it in Apex), the scrt2 SSE
handshake rejects the session with **HTTP 400** and no body. The widget
loads, the iframe renders, handshakes complete — then silently fails to
connect. Extremely non-obvious.

**Workaround.** Truncate to 15 chars before passing to `init()`:

```apex
String orgId15 = UserInfo.getOrganizationId().substring(0, 15);
```

**Ask.** Accept either form in `embeddedservice_bootstrap.init()`. Or
document the requirement prominently in the snippet doc.

---

## 12. The `esConfigName` argument is the ESC developer name, not the MessagingChannel's

**Problem.** `embeddedservice_bootstrap.init(orgId, X, siteUrl, opts)`:
`X` is the **EmbeddedServiceConfig** deployment developer name, not the
`MessagingChannel` developer name. If you pass the channel name, the
scrt2 config-fetch endpoint returns 400 with no body, and the widget
fails silently.

These records usually have different developer names (e.g.
`skywave_messaging_channel` vs `skywave_deployment`), so the error mode
is easy to fall into if you're extracting values via SOQL.

**Workaround.** Query `EmbeddedServiceConfig.DeveloperName`, not
`MessagingChannel.DeveloperName`.

**Ask.** Rename the argument in the snippet / docs from `esConfigName`
(which is accurate but rarely used in conversation) to something like
`deploymentName` to match what Setup calls it. Also: surface a real error
body on 400 instead of failing silently.

---

## 13. `EmbeddedServiceConfig` must be switched to "Enhanced v2" manually

**Problem.** Newly created Embedded Service Deployments default to the
v1 client. v1 does not integrate with Agentforce agents. To use the
agent, you have to open the deployment in Setup and click "Switch to
Enhanced v2" — but this flag is not exposed in `EmbeddedServiceConfig`
metadata or Tooling API.

**Workaround.** Manual step in the Setup wizard.

**Ask.** Expose `clientVersion` (or whatever internal flag represents
v2) as a deployable metadata field.

---

## 14. "No business hours data available" logs on widget load

**Problem.** MessagingChannel without a `BusinessHoursId` causes the
widget to log `loadBusinessHours ... status 400` before falling back
to "always open". Noisy in the console even when it works.

**Workaround.** Assign the default Business Hours to the channel, or
ignore the log noise.

**Ask.** If business hours are optional, suppress the error logging in
the widget.

---

## 15. Source tracking silently blocks deploys of unchanged-looking types

**Problem.** `sf project deploy start --manifest x.xml --ignore-conflicts`
returns `"No local changes to deploy"` for types that source tracking
hasn't yet recognized as local (e.g. `Queue`, `QueueRoutingConfig`,
`EmbeddedServiceConfig`, `MessagingChannel`, `Profile`) even when those
files are clearly present and the target org lacks them. You get a
success exit code and the metadata silently fails to land.

**Workaround.** Use `sf project deploy start --metadata-dir` which
bypasses source tracking:

```bash
mkdir -p /tmp/d/Queue
cp src/queues/main_queue.queue-meta.xml /tmp/d/queues/main_queue.queue
# write package.xml
sf project deploy start --metadata-dir /tmp/d --ignore-conflicts
```

**Ask.** Either (a) have `--ignore-conflicts` actually do what it says
for these types, or (b) add a `--force` flag that short-circuits the
source-tracking deduplication entirely.

---

## 16. `Network.Status = UnderConstruction` after `sf community publish` finishes

**Problem.** After `sf community publish` completes successfully, the
corresponding `Network` record's `Status` field stays `UnderConstruction`.
The site's draft content is live and accessible, but the admin-level
activation remains un-flipped. Some Setup UI paths check this flag and
behave differently when it's not `Live`.

**Workaround.** PATCH the field directly after publish completes:

```bash
sf data update record -s Network -i $NET_ID -v "Status=Live"
```

**Ask.** Make `sf community publish` set `Network.Status = Live` atomically
when publishing.

---

## 17. Updating a Network immediately after publish races on a server lock

**Problem.** The `sf data update record -s Network -i X -v Status=Live`
call above frequently returns:

> unable to obtain exclusive access to this record

because the publish job hasn't released its internal lock.

**Workaround.** Retry loop with a 5-second sleep.

**Ask.** Have the publish job release locks before returning, or expose
a `--wait-for-lock` option on `sf data update record`.

---

## 18. LWR bundle caching requires explicit cachebust during dev

**Problem.** LWR Experience Cloud sites cache component bundles by
`versionKey`. `sf community publish` is supposed to bump the key, but
in practice clients often continue serving the old bundle. Hard-refresh
doesn't help — the key is baked into the served HTML.

**Workaround.** Append `?lwr.cachebust=1` (any unique value) to the site
URL to force LWR to bypass its cache.

**Ask.** Ensure `sf community publish` actually bumps the version key
on every publish. Alternatively, expose a `--force-cache-invalidation`
or `sf community flush-cache` command.

---

## 19. `enableExperienceBundleBasedSnaOverrideEnabled` flag default makes retrieve fragile

**Problem.** Newly-created LWR site's `Network.enableExperienceBundleBasedSnaOverrideEnabled
= true` causes source-tracking-aware retrieves of `DigitalExperienceBundle`
to return empty. See #4.

**Workaround.** Switch to `--target-metadata-dir` based retrieve.

**Ask.** See #4.

---

## Summary ranking (by impact on automation)

| # | Issue | Impact |
|---|---|---|
| 10 | No headless ESC deployment creation | 🔴 Blocks end-to-end automation entirely |
| 13 | Manual "Switch to Enhanced v2" step | 🔴 Blocks end-to-end automation entirely |
| 11 | 15 vs 18 char org ID silent failure | 🟠 Easy to lose hours debugging |
| 12 | `esConfigName` vs channel name confusion | 🟠 Easy to lose hours debugging |
| 1  | `sf agent publish` leaves BotUserId null | 🟠 Requires non-obvious 3-step workaround |
| 4  | `DigitalExperienceBundle` source-tracking retrieve | 🟠 Wastes debugging time |
| 5  | Network↔CustomSite cyclic dependency | 🟠 Requires XML editing mid-deploy |
| 6  | `CommunitiesLanding` missing in fresh orgs | 🟡 Fixable by adding a "bootstrap" community |
| 9  | Profile contains refs to nonexistent classes | 🟡 Fixable by stripping |
| 15 | Source tracking silently skips deploys | 🟡 Fixable by `--metadata-dir` |
| 3  | `replaceWithEnv` skipped by `sf agent publish` | 🟡 Fixable by double-deploy |
| 2  | Agent user base-username appended with GUID | 🟢 Minor, documented |
| 7  | `vforcesite` suffix | 🟢 Cosmetic |
| 8  | Profile skeleton retrieve | 🟢 Documented |
| 14 | Business hours log noise | 🟢 Cosmetic |
| 16 | Network stays UnderConstruction | 🟢 Patch-with-PATCH |
| 17 | Lock race after publish | 🟢 Retry loop |
| 18 | LWR bundle cache | 🟢 Cachebust URL |
| 19 | SnaOverride flag | 🟢 See #4 |
