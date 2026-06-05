# Skywave Style Guide

The visual language for Skywave Airlines surfaces — the consumer website,
the in-chat Agentforce cards, and the Lightning console/monitor components.
Derived from what already ships (`heroku/skywave-app/public/assets/site.css`
and the `skywave* ` LWCs), not invented. **When building a new component,
copy the token block below and use the variables — don't hand-pick hex
values.**

> Source of truth for tokens: this file. The consumer site CSS holds the
> original brand palette; the LWC cards extended it with the teal accent and
> a light theme. This guide reconciles them.

---

## 1. Brand in one breath

Skywave is a **modern airline**: deep navy night-sky base, a bright **teal**
as the single interactive accent, generous rounded cards, lots of air. Calm
and premium, not loud. Two render contexts share one palette:

- **Dark theme** — consumer website + in-chat cards (navy surfaces, white text).
- **Light theme** — Lightning console/monitor LWCs (white cards on `#f5f7fb`, navy text).

Same hues, inverted. A component picks the theme of wherever it renders.

---

## 2. Color

### Core palette (theme-independent)

| Token | Hex | Use |
|-------|-----|-----|
| `--sw-navy` | `#0b1d3a` | Primary brand navy; dark-theme text-on-light |
| `--sw-navy-deep` | `#06122a` | Gradient bottom, deepest surface |
| `--sw-blue-soft` | `#12305f` | Dark-theme raised surface / option fill |
| **`--sw-teal`** | **`#14b8a6`** | **THE interactive accent** — buttons, selected states, links, focus |
| `--sw-teal-hover` | `#0d9488` | Teal hover |
| `--sw-teal-active` | `#0f766e` | Teal pressed / deep teal detail (`--sw-teal-deep` is an alias) |

> **Teal is canonical** (decided 2026-06-05). It is the primary action color
> everywhere — website and cards alike. The website's original blue
> (`#2e6df0`) is **legacy**: don't use it in new work, and migrate it to teal
> when you touch a file that still has it. Do not introduce a second "primary".

### Semantic

| Token | Hex | Use |
|-------|-----|-----|
| `--sw-gold` / `--sw-amber` | `#f3c14a` | Loyalty/premium highlight, warnings on light; the website warn pill uses `#ffb84d` |
| `--sw-success` | `#15803d` | Confirmations, paid/booked states |
| error | text `#ffd9d4` on `rgba(186,5,23,.4)` | Error banners (dark theme) |

### Dark theme (website + chat cards)

```
--sw-card-bg:     #1f2836;                    /* desaturated slate card  */
--sw-card-border: rgba(168,188,216,0.18);
--sw-card-divider:rgba(168,188,216,0.15);
--sw-text:        #ffffff;
--sw-text-mute:   #a8bcd8;                     /* == --sw-mute            */
background:       linear-gradient(180deg,#0b1d3a 0%,#06122a 100%);
```

### Light theme (Lightning console / monitor)

```
--sw-card-bg:     #ffffff;
--sw-bg-alt:      #f5f7fb;                     /* page behind cards       */
--sw-card-border: #d8dee8;
--sw-card-divider:#e6e9f0;
--sw-text:        #0b1d3a;                     /* navy text               */
--sw-text-mute:   #4f5a73;
--sw-mute:        #6e7993;
```

---

## 3. Typography

- **Font stack (UI):** `system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`
  — the token `--sw-font`. Use it everywhere; don't introduce `Inter` or other
  bespoke stacks (some older components drifted — consolidate when touched).
- **Mono:** `ui-monospace, "SF Mono", Menlo, monospace` — IDs, codes, telemetry.
- **Scale (observed, keep to it):** hero/question `1.5rem` · card title `1.25rem`
  · body `0.95rem` · secondary `0.85rem` · meta/label `0.75rem`.
- **Weights:** 600 for headings/brand, 500 for buttons/labels, 400 body.
- **Labels/eyebrows:** uppercase, `letter-spacing: 0.1em`, muted color, `0.75rem`.
- Headline letter-spacing slightly tight: `-0.02em`.

---

## 4. Shape, elevation, spacing

- **Radius:** `--sw-radius: 0.75rem` for cards; `0.5rem` for buttons/inputs/
  inner tiles; `50%` avatars; `100px`/`1rem` pills. Don't invent new radii.
- **Card shadow (dark):** `0 4px 16px rgba(0,0,0,0.25)`.
  **Card shadow (light):** `0 2px 8px rgba(0,0,0,0.05)` resting,
  `0 4px 16px rgba(11,29,58,0.08)` raised.
- **Teal glow** (selected/active emphasis): `0 0 0 2px rgba(20,184,166,0.25)`
  or `0 4px 12px rgba(20,184,166,0.2)`.
- **Spacing:** rem-based, multiples of `0.25`. Card padding `1.5rem` (website) /
  `0.875rem–1rem` (compact cards). Gaps `0.5–0.75rem` within a card,
  `1.25rem` between sections.
- **Density:** prefer whitespace. Mobile cards cap at `max-width: 32rem`.

---

## 5. Components

- **Buttons** — teal fill, white text, weight 500, radius `0.5rem`, full-width
  on mobile. Hover `--sw-teal-hover`, active `--sw-teal-active`. `font-family: inherit`.
- **Selectable tiles** (survey options, seats, payment) — surface fill,
  `2px solid transparent` border; selected = teal border + teal fill / glow;
  unselected-disabled drop to `opacity: 0.4`. Press feedback `transform: scale(0.98)`.
- **Cards** — themed surface, 1px border, card shadow, radius `0.75rem`,
  internal fl. Route/summary rows use a 3-column grid (origin · connector · dest).
- **Pills / chips** — small, rounded (`1rem`+), used for stage/status/fare.
  Warn/disconnected pill flips to gold with navy-deep text.
- **Imagery** — square `aspect-ratio: 1`, `object-fit: cover`, radius `0.5rem`;
  placeholder is a muted centered label on `rgba(0,0,0,0.2)`.

---

## 6. Rules for new components

1. **Copy the starter token block** (below) into your component's `.css` `:host`
   and reference variables. Pick dark or light overrides for your render context.
2. **Teal is the only accent.** No blue, no second primary. New semantic colors
   only with a reason, added here first.
3. **One font** (`--sw-font`) and the mono stack. No new font families.
4. **Reuse radii/shadows/spacing** from §4. If you need a value not here, it
   probably shouldn't be new — check first, then add it here if it's real.
5. In Lightning, prefer mapping to SLDS styling hooks where one exists
   (`--slds-g-color-*`, `--slds-g-radius-border-*`) and fall back to the sw-token,
   e.g. `var(--slds-g-radius-border-3, 0.75rem)`.
6. If you change a token's value, change it **here and in every component** —
   don't fork. (The teal-vs-blue split is exactly the drift this guide ends.)

### Starter token block (copy into `:host`)

```css
:host {
    /* Skywave tokens — see docs/STYLE_GUIDE.md. Do not hand-pick hex. */
    --sw-navy: #0b1d3a;
    --sw-navy-deep: #06122a;
    --sw-blue-soft: #12305f;
    --sw-teal: #14b8a6;
    --sw-teal-hover: #0d9488;
    --sw-teal-active: #0f766e;
    --sw-gold: #f3c14a;
    --sw-success: #15803d;
    --sw-radius: 0.75rem;
    --sw-font: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;

    /* DARK context (website / chat cards): */
    --sw-card-bg: #1f2836;
    --sw-card-border: rgba(168, 188, 216, 0.18);
    --sw-card-divider: rgba(168, 188, 216, 0.15);
    --sw-text: #ffffff;
    --sw-text-mute: #a8bcd8;

    /* LIGHT context (Lightning console) — swap the four above for:
    --sw-card-bg: #ffffff;
    --sw-bg-alt: #f5f7fb;
    --sw-card-border: #d8dee8;
    --sw-card-divider: #e6e9f0;
    --sw-text: #0b1d3a;
    --sw-text-mute: #4f5a73;
    */

    display: block;
    font-family: var(--sw-font);
    color: var(--sw-text);
}
```

---

*Maintained from the shipping code, not aspiration. When a component
legitimately needs something new, add it here in the same change.*
