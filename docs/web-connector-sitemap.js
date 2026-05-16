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
//   - No setLoggingLevel('trace') — debug output behind a ?debug=1 flag in
//     site.js, off by default in production.
//   - No diagnostic OnException listener phoning home — debug from the
//     browser console when needed.

SalesforceInteractions.init({
  consents: [{
    provider: 'Skywave Interactive',
    purpose:  'Tracking',
    status:   'OptIn'    // exact string: 'OptIn' | 'OptOut' | 'NotSet'
  }],
  // Single-host on Heroku. No subdomain spread, so a literal host is fine.
  cookieDomain: 'skywave-app-bb0e8666933b.herokuapp.com'
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
