# Install gap analysis — docs vs. install.sh + skill

Scan date: 2026-06-16. Compared what the `.md` docs say the demo NEEDS against what
`install.sh` + the `skywave-install` skill actually do, verified against the live
`si` org. Most gaps "worked on si" only because they were hand-built there — a
fresh org would not have them. **All findings resolved or dispositioned below.**

Status: ✅ fixed · 📝 documented (intentionally not automated) · ⏭️ deferred.

---

## ✅ GAP 1 — Survey content was never seeded  → FIXED
Chapter 1 + the whole tracking pipeline key on `Survey_Question__c` /
`Survey_Answer_Option__c`, but no seeder existed (the 3 Tier-1 seeders did
flights/bookings/routes/seatmaps only). `si` had them only via hand-authoring.
**Fix:** `scripts/apex/seedSurveyContent.apex` replicates the AUTHORITATIVE si
state — 5 questions / 21 options with the EXACT active flags (`fly_frequency` +
its options stay INACTIVE). Idempotent (question upsert on Question_Key__c;
options matched on questionKey:optionKey since Option_Key__c isn't a global
External Id; master-detail parent set only on insert). Image URLs use
`%%SKYWAVE_HEROKU_ORIGIN%%` (never the hardcoded dyno hash) — install.sh §1.12
substitutes the resolved origin; §3.2b re-points them once the real dyno exists.
`updateSurveyImageUrls.apex` de-hardcoded the same way.

## ✅ GAP 2 — agent baseline (was flagged "wrong bundle")  → NOT A GAP
The demo script changed: seat reservation is gated by a **Setup item** (enable/
disable), so it's **one agent, no redeployment** between Chapters 5–7. install.sh
correctly publishes the full `Skywave_Airlines_Agent`. (The
`Skywave_Airlines_Agent_Baseline` bundle remains in source as a reference/reset
artifact but is not the install default.) No change to the installer.

## ✅ GAP 3 — Voice agent (Chapter 9) was uncovered  → FIXED (Tier 6)
`Skywave_Voice_Agent` existed but was never published/wired. **Fix:** new Tier 6
(`--with-voice`, in `--all`). Scripts the automatable parts (publish + activate
the voice agent with the bot-user permset + BotUser patch; assign the 3
NativeCCaaS permsets + PSG) and GATES the UI-only parts (phone number +
NativeVoice channel; the 2 PSTN toggles) — no public API for those (confirmed via
the `voice-agent-demo` skill, which the conductor delegates to). The voice
metadata (resolver trigger, queue, routing config, VoiceCall page) already
deploys with Tier 1.

### ✅ Sub-finding (caught during Gap 3) — agent-user not portable  → FIXED
All 3 `.agent` bundles hardcoded si's agent-user hash as `default_agent_user`, and
the `replaceWithEnv` rule was a dead no-op (target placeholder no longer in the
files — a retrieve had overwritten it). **Fix:** restored
`skywaveserviceagent@example.com` in all 3 + added the baseline/voice bundles to
`sfdx-project.json` replacements, so `AGENT_USER` substitution fires on
deploy/publish. Verified on si (deploy errors when AGENT_USER unset; substitutes
when set). The chat agent's §1.6 post-publish BotUser patch remains as a backstop.

## ✅ GAP 4 — Preflight_Key__c CMD not seeded  → FIXED
Tier 3 set `PREFLIGHT_KEY` on Heroku but not the matching org CMD field, so the
preflight callout auth mismatched. **Fix:** `scripts/apex/setPreflightKey.apex`
sets it via the native Metadata API (anonymous Apex), the key substituted from
`.secrets/preflight.key` (never committed). Wired into §3.3. Verified on si.

## 📝 GAP 5 — demo-seed Contact flag  → DOCUMENTED (no seeder)
`Skywave_ResolveSession` falls back to the one Contact with
`Skywave_Demo_Seed__c = true` (no-website chat path). Per decision, this is a
**manual step**, not seeded — see "Manual steps" below.

## 📝 GAP 6 — presenter permset assignment  → DOCUMENTED (sys admin = presenter)
The installer assumes the **System Administrator is the presenter**, who already
has access to the monitor/globe apps and dashboards via the admin profile +
the permsets install assigns to the running user. No per-user assignment step
needed. (If a non-admin presenter is used, assign `Skywave_Demo_Admin` +
`Skywave_Globe_App` + the analytics permsets to that user.)

## ⏭️ GAP 7 — Agentforce Data Library / Knowledge grounding  → DEFERRED
The agent references `knowledge:` and the README mentions creating a Data Library,
but the knowledge source isn't built yet. Out of scope until it exists; revisit as
a Tier-2-adjacent manual gate (needs Data Cloud active) once built.

---

## Manual steps the installer intentionally does NOT automate
These are documented here + flagged by the skill's gates; they are not bugs.

- **demo-seed Contact flag (Gap 5):** set `Skywave_Demo_Seed__c = true` on exactly
  ONE Contact (the demo Contact, e.g. Lauren Bailey) so the no-website chat path
  has a fallback. One-liner: `sf data update record -s Contact -i <contactId>
  -v "Skywave_Demo_Seed__c=true" --target-org <alias>`.
- **Secrets** that must be supplied by hand (Tier 3 flags them): `SF_CLIENT_ID`,
  `SF_MIAW_JWT_*`, `SKYWAVE_PROOF_KEY`, `IPINFO_TOKEN`, `CORS_PROXY_URL`, and the
  MIAW User Verification public-JWK upload to the Salesforce Keyset. See
  `.env.example` / `SECRETS.md`.
- **Voice UI gates (Tier 6):** phone number + channel, the 2 PSTN toggles, re-login.
- **Multi-Framework app domain (Tier 4):** enable `*.salesforce.app` in Setup.
- **Data Cloud + Agentforce enablement:** done via the SDO's first-login "Set up
  your demo org" dialogue (toggle both ON → Apply selections) — the supported
  one-click path; the installer does NOT enable Data Cloud (Tiers 2/5 gate on it).
  Plus, in Tier 2: the Session Tracing toggle, and (on a fresh org) the data-kit
  instantiation + the `Skywave_Customers` data-graph build.

---

## Confirmed COVERED (no gap)
ESD republish (§1.13 Playwright), AGENT_USER capture + BotUserId wiring, current
Booking__c seeders (NOT the stale createSampleData.apex — only named in a comment),
Heroku origin → CMD/remote-site/globe, STDM wait / data-kit / stream refresh,
Tier-5 tracking pipeline, secrets-as-gates.
