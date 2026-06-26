// Skywave Interactive — Web Connector sitemap.
//
// Upload via Setup → Data Cloud → Web & Mobile App Connectors →
// Skywave Interactive → Sitemap → Upload.
//
// Most events fire imperatively from heroku/skywave-app/public/assets/site.js
// using SalesforceInteractions.sendEvent(). The sitemap stays deliberately
// lightweight: it declares consent, types pages so post-demo analytics can
// segment by stage, and sets a default page-type fallback to suppress
// "No matching page found" exceptions.
//
// Cross-references:
//   - SKYWAVE_INTERACTIVE_DESIGN.md §4c — full event plan
//   - ~/dev/claude-skills/sf-interactions-sdk/recipes/sitemap-minimum.md
//
// Things this sitemap deliberately does NOT do:
//   - No declarative click listeners (sendEvent calls live in site.js).
//   - No diagnostic OnException listener phoning home — debug from the
//     browser console when needed.
//
// Logging: setLoggingLevel('trace') is on by default while we build this
// out. Demote to 'warn' or 'error' before any public event / production
// rehearsal — it's the first line of the file.

// Verbose console logging during active development. Flip to 'warn' or
// 'error' before public events / production. Set early so init() and
// initSitemap() emit their own diagnostics on every page load.
SalesforceInteractions.setLoggingLevel('trace');

// Consent is intentionally NOT declared in init's consents array. The
// consumer site shows a consent screen and calls updateConsents() with
// status: 'OptIn' on Accept — that way the consent record reflects an
// actual user action, not a sitemap default. Until then, events are
// queued and dropped (the SDK refuses to ship without consent), which
// is the right behavior.
SalesforceInteractions.init({
  // Custom-domain cutover: the consumer site (app.skywave.flights) and the chat
  // site (chat.skywave.flights) share the registrable domain skywave.flights.
  // Pin the cookie to that registrable domain so the _sfid anonymous-id cookie
  // is valid on both subdomains. A host-literal here makes the browser reject
  // the cookie on any other host → the SDK can't persist it → the deviceId
  // (== anonymousId) regenerates on every event. (Re-upload this sitemap in the
  // Data Cloud Web Connector UI after editing — the live value is the uploaded one.)
  cookieDomain: 'skywave.flights'
});

SalesforceInteractions.initSitemap({
  global: {
    locale: 'en_US'
  },
  // Page-type matching reads document.body.dataset.stage, which site.js sets
  // whenever the SPA's stage changes. URL doesn't change between stages
  // (we're a single-page app), so dataset is the right signal.
  pageTypes: [
    { name: 'consent',  isMatch: () => document.body?.dataset.stage === 'consent' },
    { name: 'waiting',  isMatch: () => document.body?.dataset.stage === 'waiting' },
    { name: 'survey',   isMatch: () => document.body?.dataset.stage === 'survey' },
    { name: 'agent',    isMatch: () => document.body?.dataset.stage === 'agent' },
    { name: 'profile',  isMatch: () => document.body?.dataset.stage === 'profile' },
    { name: 'c360',     isMatch: () => document.body?.dataset.stage === 'c360' },
    { name: 'race',     isMatch: () => document.body?.dataset.stage === 'race' },
    { name: 'thanks',   isMatch: () => document.body?.dataset.stage === 'thanks' }
  ],
  pageTypeDefault: { name: 'other' }
});
