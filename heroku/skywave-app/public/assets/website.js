/**
 * Skywave Airlines website backdrop.
 *
 * Ported from skywave-scratch's skywaveAirlinesHome LWC. Stripped to
 * vanilla HTML/CSS/JS — no Lightning hooks. Renders a full marketing
 * page (nav, hero with search-card mock, ticket strip, deals, points
 * banner, footer) into any host element.
 *
 * Designed to be the visual *backdrop* for the demo flow: the consent /
 * survey / waiting modal sits on top of it and the chat icon floats
 * above it. The site itself is non-functional for now — burger menu
 * opens/closes, links are no-ops — but the markup is here so it can
 * grow into a real interactive site later (working booking form, login,
 * flight overview, etc.) without re-architecting.
 */

const HTML = `
<nav class="nav">
    <div class="nav-logo">
        <div class="logo-mark">
            <svg viewBox="0 0 24 30" fill="none" xmlns="http://www.w3.org/2000/svg">
                <path d="M21 16v-2l-8-5V3.5c0-.83-.67-1.5-1.5-1.5S10 2.67 10 3.5V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5l8 2.5z" fill="white"></path>
                <path d="M3 27 Q7.5 23 12 27 Q16.5 23 21 27" stroke="white" stroke-width="2" fill="none" stroke-linecap="round"></path>
            </svg>
        </div>
        <span class="logo-text">Sky<span>Wave</span></span>
    </div>

    <div class="nav-links">
        <a class="active" data-route="#book">Flights</a>
        <a>Hotels</a>
        <a>Cars</a>
        <a>Vacations</a>
        <a>Deals</a>
        <a data-route="#bookings">My bookings</a>
        <a>SkyRewards</a>
    </div>

    <div class="nav-right" data-identity-slot>
        <a class="nav-link-text desktop-item" data-action="signin" data-when="anonymous">Sign in</a>
        <button class="nav-btn desktop-item" data-when="anonymous">Join SkyRewards</button>
        <a class="nav-greeting desktop-item" data-when="identified" data-route="#profile" hidden>
            <span class="nav-greeting-avatar"></span>
            <span class="nav-greeting-text"></span>
        </a>
        <button class="hamburger-btn" data-action="toggle-burger" aria-label="Open menu">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                <line x1="3" y1="6" x2="21" y2="6"></line><line x1="3" y1="12" x2="21" y2="12"></line><line x1="3" y1="18" x2="21" y2="18"></line>
            </svg>
        </button>
    </div>
</nav>

<div class="mobile-nav-drawer" data-burger-drawer>
    <div class="mob-drawer-inner">
        <div class="mob-nav-links">
            <a class="active" data-route="#book">Flights</a>
            <a>Hotels</a>
            <a>Cars</a>
            <a>Vacations</a>
            <a>Deals</a>
            <a data-route="#bookings">My bookings</a>
            <a>SkyRewards</a>
        </div>
        <div class="mob-drawer-footer">
            <div class="mob-user-links" data-identity-slot>
                <a data-when="anonymous" data-action="signin">Sign in</a>
                <a data-when="anonymous">Join SkyRewards</a>
                <a data-when="identified" data-route="#profile" hidden>
                    <span class="nav-greeting-avatar"></span>
                    <span class="nav-greeting-text"></span>
                </a>
            </div>
        </div>
    </div>
</div>

<section class="hero">
    <div class="hero-dots"></div>
    <div class="hero-glow"></div>

    <svg class="hero-plane" viewBox="0 0 160 310" fill="none" xmlns="http://www.w3.org/2000/svg">
        <rect x="70" y="30" width="20" height="230" rx="10" fill="white"></rect>
        <path d="M70,52 Q80,8 90,52Z" fill="white"></path>
        <path d="M80,118 L6,180 L6,198 L80,158 L154,198 L154,180 Z" fill="white"></path>
        <ellipse cx="34" cy="183" rx="10" ry="18" fill="white" opacity="0.75"></ellipse>
        <ellipse cx="126" cy="183" rx="10" ry="18" fill="white" opacity="0.75"></ellipse>
        <path d="M80,236 L42,272 L42,283 L80,258 L118,283 L118,272 Z" fill="white" opacity="0.85"></path>
        <circle cx="80" cy="128" r="5" fill="#0D1B2A" opacity="0.22"></circle>
        <circle cx="80" cy="146" r="5" fill="#0D1B2A" opacity="0.22"></circle>
        <circle cx="80" cy="164" r="5" fill="#0D1B2A" opacity="0.22"></circle>
        <circle cx="80" cy="182" r="5" fill="#0D1B2A" opacity="0.22"></circle>
        <circle cx="80" cy="200" r="5" fill="#0D1B2A" opacity="0.22"></circle>
        <circle cx="80" cy="218" r="5" fill="#0D1B2A" opacity="0.22"></circle>
    </svg>

    <div class="hero-content">
        <div class="hero-left">
            <div class="hero-eyebrow">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M21 16v-2l-8-5V3.5c0-.83-.67-1.5-1.5-1.5S10 2.67 10 3.5V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5l8 2.5z"></path></svg>
                SkyWave Airlines
            </div>
            <h1 class="hero-title">
                Discover your<br/>
                <span class="accent">Dream Flight</span>
            </h1>
            <p class="hero-sub">
                Find an easy way to book airplane tickets with just a few clicks. Earn 3x points on every flight.
            </p>
            <div class="hero-stats">
                <div>
                    <div class="stat-num">150+</div>
                    <div class="stat-label">Destinations</div>
                </div>
                <div>
                    <div class="stat-num">2M+</div>
                    <div class="stat-label">Travelers</div>
                </div>
                <div>
                    <div class="stat-num">$0</div>
                    <div class="stat-label">Booking fees</div>
                </div>
            </div>
        </div>

        <div class="hero-right">
            <form class="search-card" data-search-form>
                <div class="s-tabs">
                    <div class="s-tab active"><span class="tab-pip"></span>One‑Way</div>
                    <div class="s-tab"><span class="tab-pip"></span>Round Trip</div>
                </div>
                <div class="s-fields">
                    <div class="s-field">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17.8 19.2L16 11l3.5-3.5C21 6 21 4 19.5 2.5S18 2 16.5 3.5L13 7 4.8 5.2l-1.1 1L9 10l-2 2H4l-1 1 3 2 2 3 1-1v-3l2-2 3.2 5.3z"></path></svg>
                        <input type="text" placeholder="From (e.g. SEA)" name="origin" autocomplete="off" maxlength="20"/>
                    </div>
                    <div class="s-field">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17.8 19.2L16 11l3.5-3.5C21 6 21 4 19.5 2.5S18 2 16.5 3.5L13 7 4.8 5.2l-1.1 1L9 10l-2 2H4l-1 1 3 2 2 3 1-1v-3l2-2 3.2 5.3z" transform="rotate(180 12 12)"></path></svg>
                        <input type="text" placeholder="To (e.g. JFK)" name="destination" autocomplete="off" maxlength="20"/>
                    </div>
                    <div class="s-row">
                        <div class="s-field">
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="18" rx="2"></rect><line x1="16" y1="2" x2="16" y2="6"></line><line x1="8" y1="2" x2="8" y2="6"></line><line x1="3" y1="10" x2="21" y2="10"></line></svg>
                            <input type="date" name="date"/>
                        </div>
                        <div class="s-field">
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path><circle cx="12" cy="7" r="4"></circle></svg>
                            <select name="fareClass">
                                <option>Economy</option>
                                <option>Premium Economy</option>
                                <option>Business</option>
                                <option>First</option>
                            </select>
                        </div>
                    </div>
                </div>
                <button class="btn-search" type="submit">Search Flights</button>
            </form>
        </div>
    </div>
</section>

<!-- Customer-area sections render inline with the rest of the website,
     replacing nothing. They're hidden by default and shown when the
     visitor follows a hash route (e.g. clicks "My bookings"). The hero
     stays visible above; the rest of the page (deals, points banner)
     hides while a customer route is active so the page reads as
     "you're now in your account" without removing the website
     surrounding chrome. -->
<section id="customer-area" class="customer-area" data-state="hidden">
    <div class="customer-inner"></div>
</section>

<div class="main" data-customer-aware>
    <div class="section">
        <div class="section-head">
            <h2 class="section-title">Featured deals</h2>
            <a class="section-more">See more &#8594;</a>
        </div>
        <div class="deals-grid">
            <div class="deal-card">
                <div class="deal-img c1">&#x1F5FD;</div>
                <div class="deal-body">
                    <div class="deal-tag">Limited Time</div>
                    <h4>New York from $189</h4>
                    <p>Nonstop flights from Seattle. Book by March 1 to lock in this rate.</p>
                </div>
            </div>
            <div class="deal-card">
                <div class="deal-img c2">&#x1F334;</div>
                <div class="deal-body">
                    <div class="deal-tag">Spring Break</div>
                    <h4>Cancún from $299</h4>
                    <p>Sun, sand, and savings. Earn double points on select international routes.</p>
                </div>
            </div>
            <div class="deal-card">
                <div class="deal-img c3">&#x1F3B0;</div>
                <div class="deal-body">
                    <div class="deal-tag">Weekend Deal</div>
                    <h4>Las Vegas from $89</h4>
                    <p>Quick getaway deals every Thursday. Sign up for SkyAlert to be notified.</p>
                </div>
            </div>
        </div>
    </div>

    <div class="pts-banner">
        <div class="pts-inner">
            <div>
                <h3>Earn points on every flight</h3>
                <p>Join SkyRewards free and start earning toward your next trip. Members fly further on every dollar spent.</p>
            </div>
            <button class="btn-pts">Join SkyRewards</button>
        </div>
    </div>
</div>

<footer class="sw-footer">
    <div class="footer-inner">
        <div class="footer-brand">
            <div class="nav-logo">
                <div class="logo-mark">
                    <svg viewBox="0 0 24 24" fill="none">
                        <path d="M21 16v-2l-8-5V3.5c0-.83-.67-1.5-1.5-1.5S10 2.67 10 3.5V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5l8 2.5z" fill="white"></path>
                    </svg>
                </div>
                <span class="logo-text">Sky<span>Wave</span></span>
            </div>
            <p>Flying you further, faster, and smarter. Committed to exceptional service on every journey.</p>
        </div>
        <div>
            <h5>Travel</h5>
            <a>Book a flight</a>
            <a>Flight status</a>
            <a>Check-in</a>
            <a>Baggage info</a>
        </div>
        <div>
            <h5>Rewards</h5>
            <a>SkyRewards</a>
            <a>Credit card</a>
            <a>Redeem points</a>
            <a>Elite status</a>
        </div>
        <div>
            <h5>Help</h5>
            <a>FAQ</a>
            <a>Contact us</a>
            <a>Cancellations</a>
            <a>Accessibility</a>
        </div>
    </div>
    <div class="footer-bottom">
        <span>&#169; 2026 SkyWave Airlines. All rights reserved.</span>
        <span>Privacy&nbsp;·&nbsp;Terms&nbsp;·&nbsp;Cookie Policy</span>
    </div>
</footer>
`;

/**
 * Render the website backdrop into `host` (an element) and wire up the
 * hamburger toggle. Idempotent — safe to call multiple times. Returns
 * the host element for chaining.
 */
export function renderWebsite(host) {
    host.classList.add('skywave-site');
    host.innerHTML = HTML;

    const burgerBtn = host.querySelector('[data-action="toggle-burger"]');
    const burgerDrawer = host.querySelector('[data-burger-drawer]');
    if (burgerBtn && burgerDrawer) {
        burgerBtn.addEventListener('click', () => {
            burgerDrawer.classList.toggle('open');
        });
    }

    return host;
}
