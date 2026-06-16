# Install gap analysis — docs vs. install.sh + skill

Scan date: 2026-06-16. Compares what the `.md` docs say the demo NEEDS against what
`install.sh` (5 tiers) + the `skywave-install` skill actually do. Verified against
the live `si` org (many gaps "work on si" only because they were hand-built there —
a fresh org would not have them).

Legend: 🔴 blocks a demo chapter · 🟡 needs a manual touch the installer should own or
flag · 🟢 already covered / correctly gated (listed for completeness).

---

## 🔴 GAP 1 — Survey content is never seeded
**Chapter 1 (the entire opening) depends on it.** `Skywave_SurveySchema` serves
*active* `Survey_Question__c` + `Survey_Answer_Option__c`, and the consumer site /
tracking pipeline / monitor all key on them. The three Tier-1 seeders
(`seedSkywaveBookingData`, `seedSkywaveSeatMaps`, `seedSkywaveRouteNetwork`) seed
flights/bookings/routes/seatmaps but **no survey questions**. There is **no survey
seeder anywhere** in `scripts/` or `classes/`. `si` has 5 questions + 21 options
because they were authored by hand (via `skywaveSurveyAuthor` LWC); a fresh org gets
zero → the survey screen is empty and Chapter 1 + all tracking has no input.
**Fix:** add a `scripts/apex/seedSurveyContent.apex` (the 5 questions + 21 options,
with `Question_Key__c`/`Option_Key__c`/`Image_Url__c`/`Active__c=true`, idempotent
upsert on the keys) and call it in §1.12. Image URLs come from
`scripts/gen-survey-images.sh` + `updateSurveyImageUrls.apex` (already exist).

## 🔴 GAP 2 — install publishes the FULL agent; the demo needs the stripped baseline
The narrative (Chapters 5→7) requires the agent to **start WITHOUT seat-change** so
it visibly fails (Ch5), you see the gap in Observability (Ch6), then add the
seat-change subagent live with Claude (Ch7). `force-app` has both
`Skywave_Airlines_Agent` (full) and `Skywave_Airlines_Agent_Baseline` (the intended
starting state). **install.sh §1.6 publishes the FULL agent**, so seat-change already
works on a fresh install → Chapters 5–7 have no gap to demonstrate.
**Fix:** decide the install default. Either (a) Tier 1 publishes
`Skywave_Airlines_Agent_Baseline` and the live Ch7 step adds seat-change, or (b) a
flag/step resets to baseline before a demo run. Needs your call on which bundle is
"installed state" vs "demo-day reset state" (see also the design doc's reset-script
note).

## 🔴 GAP 3 — Voice agent (Chapter 9) is entirely uncovered
`Skywave_Voice_Agent` bundle EXISTS in `force-app`, and Chapter 9 ("the real seat
change… on the phone") + design Phase 5.5 require it. **install.sh never publishes,
activates, or wires the voice agent**, and the telephony setup (phone number,
Service Cloud Voice, caller-id→Contact routing, the two Agentforce Voice PSTN
toggles, the `skywave_routing` queue at LeastActive) is fully manual — there's a
separate `voice-agent-demo` skill for it.
**Fix:** either add a `--with-voice` tier that publishes/activates the voice agent +
conducts the manual PSTN/queue gates (delegating to the `voice-agent-demo` skill), or
explicitly scope voice OUT and document it as a manual follow-on. Needs your call.

---

## 🟡 GAP 4 — `Preflight_Key__c` CMD not seeded (preflight callout auth mismatch)
Tier 3 sets `PREFLIGHT_KEY` on Heroku from `.secrets/preflight.key`, but never writes
the matching `Skywave_Preflight_Config__mdt.Default.Preflight_Key__c` in the org
(ARCHITECTURE §3g says it's set out-of-band via anonymous Apex). So
`Skywave_PreflightController`'s callout sends a key the dyno rejects → the Preflight
"Check Demo" tab's relay checks fail.
**Fix:** in Tier 3, after setting the Heroku var, run an anonymous-Apex upsert of the
`Default` CMD's `Preflight_Key__c` (+ `Heroku_Origin_Url__c`, already handled) from
the same `.secrets/preflight.key`. (CMD upsert needs Metadata API / a tooling call.)

## 🟡 GAP 5 — demo-seed Contact flag not set
`Skywave_ResolveSession` falls back to "the one Contact where `Skywave_Demo_Seed__c =
true`" when a chat visitor has no resolvable deviceId (the no-website chat path,
ARCHITECTURE §3a'). The field exists; **no seeder sets it on any Contact**. On a fresh
org the fallback finds nothing → no-website chat has no Contact to bind to.
**Fix:** in §1.12's booking seed, stamp `Skywave_Demo_Seed__c = true` on the demo
Contact (Lauren Bailey) it already creates.

## 🟡 GAP 6 — per-user permset assignment for the presenter
Install assigns agent/queue permsets to the agent user, but the **presenter/admin
user** needs `Skywave_Demo_Admin` (and `Skywave_Globe_App` for Tier 4, the analytics
permsets for Tier 2) assigned to actually see the monitor app, globe app, and
dashboards. install.sh assigns some to the running user implicitly but doesn't
explicitly grant `Skywave_Demo_Admin`/`Skywave_Globe_App` to the presenter.
**Fix:** add an explicit `sf org assign permset` for the running user for
`Skywave_Demo_Admin` (Tier 1) and confirm Tier 4's `Skywave_Globe_App` assignment
targets the presenter, not just the default user.

## 🟡 GAP 7 — Agentforce Data Library / Knowledge grounding
The agent `.agent` references `knowledge:`, and the README's last step says "Setup →
Agentforce Data Library → create a new Data Library" — a **manual post-DC step** not
in any tier. If the agent's knowledge grounding is demo-relevant, the Data Library +
its source must be created.
**Fix:** confirm whether knowledge grounding is used in the demo; if so, document it
as a Tier-2-adjacent manual gate (it needs Data Cloud active, like observability).

---

## 🟢 Confirmed COVERED (spot-checked, no gap)
- Sample data (booking/seatmap/route): §1.12 correctly uses the current
  `seedSkywave*` seeders (NOT the stale `createSampleData.apex` — that's only named
  in a comment explaining why it's avoided).
- `AGENT_USER` capture + BotUserId wiring: §1.2/§1.6. ✅
- ESD republish after agent publish (the CLT-degradation trap): §1.13 Playwright. ✅
- Heroku relay origin → CMD + remote site + globe build: §3.2b + Tier 4. ✅
- Multi-Framework app domain: Tier 4 §4.0 gate. ✅
- STDM wait / data-kit / stream refresh: Tier 2 gates + `--check-stdm`. ✅
- Secrets (IPINFO/PROOF/MIAW JWK/dc.env): flagged as manual gates in Tier 3 + SECRETS.md. ✅
  (Note: these are correctly *gated*, not silently skipped.)

---

## Recommended priority
1. **GAP 2 (agent baseline)** + **GAP 1 (survey seed)** — without these, the core
   demo narrative (Ch1 + Ch5–7) doesn't work on a fresh org. Highest impact.
2. **GAP 3 (voice)** — needs a scope decision (tier it, or document as manual).
3. **GAP 4/5** — small, mechanical, high-value (preflight + chat fallback).
4. **GAP 6/7** — verify against how you actually run the demo.
