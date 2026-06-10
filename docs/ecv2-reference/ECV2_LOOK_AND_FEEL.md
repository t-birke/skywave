# Replicating the ECv2 look & feel — recovered spec

**Goal:** the custom client must look and behave EXACTLY like ECv2, because
in production we'd jump through the custom-domain hoops and ship real ECv2.
The demo must be visually indistinguishable.

**Can we get this from the served assets? YES — fully.** The styling is
recoverable with exact values, no guessing. Here's where each layer lives
and how to extract it.

## Where the styling actually lives (three layers)

The `bootstrap.min.js` our endpoint serves is just a **307 redirect to
`init.min.js`** — a 29KB *loader*. It contains almost no styling. The real
look & feel is in three places:

1. **Parent-page frame chrome** → `assets/styles/init.min.css` (2KB).
   Styles ONLY the iframe container: position, size, border-radius, shadow,
   and the open/minimize/maximize transitions. The launch **button** and
   **all chat-panel UI are NOT here.** (Raw file gitignored — exact values
   transcribed below.)

2. **iframe shell** → `assets/styles/embedded-messaging-styling.min.css`
   (246 bytes) + the full **SLDS stylesheet** (967KB) which provides the
   design tokens (`--slds-g-color-*`, spacing, etc.) every component
   references.

3. **All component CSS + every animation** → inlined as LWC-scoped template
   strings inside the LWR bundle **`home_view`** (`?lwc.mode=prod`, ~3.3MB).
   This is the button, bubbles, header, typing indicator, prechat footer,
   skeleton loaders — the entire visible chat. Extract by fetching the
   bundle and decoding the CSS string literals (the `"+a+"` / `"+s+"` are
   LWC style-scoping token concatenations; strip them to get plain CSS).

### How to re-pull (assets are versioned, so refresh when the org updates)
```bash
SITE="https://<host>.my.site.com/ESADeployment"
curl -sSL "$SITE/assets/js/bootstrap.min.js"            # -> 307 -> init.min.js (loader)
curl -sSL "$SITE/assets/styles/init.min.css"            # frame chrome
curl -sSL "$SITE/?lwc.mode=prod" -o iframe.html         # lists versioned asset URLs
# then fetch the home_view bundle URL listed in iframe.html and grep the CSS strings
```

## Frame chrome — EXACT values (from init.min.css, verbatim)

- Container: `position:fixed; bottom:24px; right:24px; border-radius:20px;
  z-index:999; background:transparent;`
- Resting/minimized size: `--minimized-iframe-width:214px;
  --minimized-iframe-height:56px` (this is the launch-button pill size).
- **Maximized panel: `width:480px; height:742px`**
  box-shadow: `0 10px 25px -3px rgba(0,0,0,.1), 0 4px 12px -2px rgba(0,0,0,.05),
  0 0 2px 0 rgba(0,0,0,.05), 0 20px 45px -5px rgba(0,0,0,.08)`
- Open/close motion:
  - initial → `transition: all 0s ease`
  - minimized → `transition: width .25s ease-in-out, height .25s ease-in-out`
  - maximized → `transition: all .3s ease`
- Mobile (`max-width:639px`): panel goes fullscreen
  `bottom:0;left:0;right:0;width:100%;height:100dvh;border-radius:0`,
  `transition: height .2s ease-in-out`. **This fullscreen-on-mobile behavior
  is exactly what we want on the client iPhone.**

## Chat-panel animations — EXACT keyframes (decoded from home_view)

Full set in `raw-assets/keyframes-decoded.css`. The ones that define the
"feel":

| Element | Animation | Spec (verbatim) |
|---|---|---|
| **Typing dots** | `dot-pop-in` | `400ms cubic-bezier(0,0.7,0.2,1) forwards`; scale `0 → 1.2 → 1`, opacity `0→1` (per-dot, staggered) |
| **Message bubble in** | `fadeInUp` | `0.3s cubic-bezier(0.16,1,0.3,1) forwards`; from `opacity:0; translateY(20px)` → `translateY(0)` |
| **Bubble/spinner out** | `fadeOutDown` | from `translateY(0)` → `opacity:0; translateY(20px)` |
| **Launch button (FAB)** | `fabFadeInWithDelay` | opacity `0→1` (delayed) |
| **Container close** | `container-fade-out` | `400ms ease forwards`, opacity `1→0` |
| **Inbound msg pulse** | `pulse` | bg color-mix flash on the inbound text color |
| **Skeleton loaders** | `shimmer` | `3s linear infinite`, gradient `200%→-200%`; bg `linear-gradient(to right,#eee 8%,#ddd 18%,#eee 33%)` |
| Header reveal | `slide-in-tr` | from `translate(10px,-10px); opacity:0` → `0,0; opacity:1` |
| Reduced motion | — | `@media (prefers-reduced-motion: reduce){ animation:none }` — must honor |

## Color/token strategy

Components reference SLDS global tokens and ESW-specific ones:
`--slds-g-color-neutral-base-10 (#181818)`, `--slds-g-color-brand-base-90
(#d8e6fe)`, `--agentic-message-inbound-text-color`,
`--agentic-chat-container-background`, etc. The **branding values**
(primary color, header text color, font size, height) are returned by the
`embedded-service-config` endpoint under `branding[]` (we already fetch it;
e.g. `agentMessageText:#2E2E2E`, `height:480`). Drive our CSS variables from
that config response so a branding change in Setup flows through, exactly
like the real client.

## Build approach

1. Lift `init.min.css` frame rules onto our parent-page container (we own
   the launch button + frame in the Heroku DOM already — see `site.js`).
2. Port `keyframes-decoded.css` verbatim into the client's stylesheet.
3. Pull SLDS tokens (either include the SLDS sheet or copy the ~20 tokens we
   actually reference).
4. Map `branding[]` from the config response → CSS custom properties.
5. Match the DOM structure of bubbles/header/footer from `iframe-shell.html`
   + the `parseFragment` templates in `home_view` so the same selectors and
   animations apply.

**Verification:** put real ECv2 (desktop, where it works) side-by-side with
the custom client and diff visually + with the timing values above. They
should be frame-for-frame identical.
