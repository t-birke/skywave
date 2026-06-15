import { existsSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import { resolve } from 'path';
import tailwindcss from '@tailwindcss/vite';
import salesforce from '@salesforce/vite-plugin-ui-bundle';
import codegen from 'vite-plugin-graphql-codegen';

const schemaPath = resolve(__dirname, '../../../../../schema.graphql');
const schemaExists = existsSync(schemaPath);

/**
 * DEV/DEMO ONLY — local CometD bridge.
 *
 * The UIBundle data SDK has no streaming, so for local preview we subscribe
 * to Platform Events over the CometD Streaming API directly. The browser
 * talks to localhost (same-origin); this proxy forwards /cometd to the org
 * with a Bearer token injected and the BAYEUX_BROWSER cookie rewritten onto
 * localhost. Resolved only for `vite` (serve), never for `vite build`, so the
 * production bundle stays org-independent and deployable as-is.
 *
 * Token source: `sf org auth show-access-token` — NOT `sf org display`, which
 * redacts the token to the literal string "[REDACTED] Use 'sf org auth
 * show-access-token' to view" (a newer CLI security default). Reading the
 * token from `sf org display` yields that placeholder, so every API call 401s.
 * `instanceUrl` still comes from `sf org display` (not redacted).
 * Override the org with SKYWAVE_ORG.
 */
function resolveOrg(): { instanceUrl: string; accessToken: string } | null {
  const alias = process.env.SKYWAVE_ORG || 'si';
  try {
    const disp = execSync(`sf org display --target-org ${alias} --json`, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    const instanceUrl = JSON.parse(disp).result?.instanceUrl;

    // The token is redacted in `sf org display`; fetch the real one here.
    // `--json` returns it under result.accessToken (the human form prints a
    // confirmation banner, so we parse from the first '{').
    const tokOut = execSync(
      `sf org auth show-access-token --target-org ${alias} --json`,
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
    );
    const parsed = JSON.parse(tokOut.slice(tokOut.indexOf('{')));
    const accessToken =
      typeof parsed.result === 'string' ? parsed.result : parsed.result?.accessToken;

    if (instanceUrl && accessToken) {
      return { instanceUrl, accessToken };
    }
  } catch {
    // sf not available / org not authed — dev server still runs, just no live feed.
  }
  return null;
}

export default defineConfig(({ command }) => {
  const org = command === 'serve' ? resolveOrg() : null;
  if (command === 'serve') {
    console.log(
      org
        ? `[skywave] CometD proxy → ${org.instanceUrl} (token ${org.accessToken.length} chars)`
        : '[skywave] no org token resolved — globe runs without a live feed'
    );
  }

  return {
    base: './',
    plugins: [
      tailwindcss(),
      react(),
      salesforce(),
      // Only add codegen when schema exists (e.g. after `npm run graphql:schema`).
      // In CI or when schema is not checked in, skip codegen so build succeeds.
      ...(schemaExists
        ? [
            codegen({
              configFilePathOverride: resolve(__dirname, 'codegen.yml'),
              runOnStart: true,
              runOnBuild: true,
              enableWatcher: true,
              throwOnBuild: true,
            }),
          ]
        : []),
    ] as import('vite').PluginOption[],

    // DEV/DEMO ONLY — CometD bridge to the org (see resolveOrg above).
    server: org
      ? {
          proxy: {
            '/cometd': {
              target: org.instanceUrl,
              changeOrigin: true,
              secure: true,
              configure: proxy => {
                // Inject the org bearer token on every forwarded CometD call.
                proxy.on('proxyReq', proxyReq => {
                  proxyReq.setHeader('Authorization', `Bearer ${org.accessToken}`);
                });
                // Rewrite Set-Cookie so BAYEUX_BROWSER sticks on localhost
                // (strip Domain, force Path=/, drop Secure for http dev).
                proxy.on('proxyRes', proxyRes => {
                  const sc = proxyRes.headers['set-cookie'];
                  if (sc) {
                    proxyRes.headers['set-cookie'] = sc.map(c =>
                      c
                        .replace(/;\s*Domain=[^;]+/i, '')
                        .replace(/;\s*Secure/i, '')
                        .replace(/;\s*SameSite=[^;]+/i, '; SameSite=Lax')
                    );
                  }
                });
              },
            },
            // SOQL bridge for replay — forwards /sf-query?q=... to the org
            // REST query API with the token injected. Stands in for the
            // GraphQL SDK until the bundle deploys in-org.
            '/sf-query': {
              target: org.instanceUrl,
              changeOrigin: true,
              secure: true,
              rewrite: (p: string) =>
                p.replace(/^\/sf-query/, '/services/data/v60.0/query'),
              configure: proxy => {
                proxy.on('proxyReq', proxyReq => {
                  proxyReq.setHeader('Authorization', `Bearer ${org.accessToken}`);
                });
              },
            },
            // sObject write bridge — forwards /sf-data/<Object>/<Id> (PATCH)
            // to the org REST sObjects API with the token injected. DEV/DEMO
            // ONLY; used by the inconspicuous seat-capability toggle to flip
            // Demo_Session__c.State__c (agent_seat_fail <-> agent_seat_pass).
            '/sf-data': {
              target: org.instanceUrl,
              changeOrigin: true,
              secure: true,
              rewrite: (p: string) =>
                p.replace(/^\/sf-data/, '/services/data/v60.0/sobjects'),
              configure: proxy => {
                proxy.on('proxyReq', proxyReq => {
                  proxyReq.setHeader('Authorization', `Bearer ${org.accessToken}`);
                });
              },
            },
          },
        }
      : undefined,

    // Build configuration for MPA
    build: {
      outDir: resolve(__dirname, 'dist'),
      assetsDir: 'assets',
      sourcemap: false,
    },

    // Resolve aliases (shared between build and test)
    resolve: {
      dedupe: ['react', 'react-dom'],
      alias: {
        '@': path.resolve(__dirname, './src'),
        '@api': path.resolve(__dirname, './src/api'),
        '@components': path.resolve(__dirname, './src/components'),
        '@utils': path.resolve(__dirname, './src/utils'),
        '@styles': path.resolve(__dirname, './src/styles'),
        '@assets': path.resolve(__dirname, './src/assets'),
      },
    },

    // Vitest configuration
    test: {
      // Override root for tests (build uses src/pages as root)
      root: resolve(__dirname),

      // Use jsdom environment for React component testing
      environment: 'jsdom',

      // Setup files to run before each test
      setupFiles: ['./src/test/setup.ts'],

      // Global test patterns
      include: [
        'src/**/*.{test,spec}.{js,mjs,cjs,ts,mts,cts,jsx,tsx}',
        'src/**/__tests__/**/*.{js,mjs,cjs,ts,mts,cts,jsx,tsx}',
      ],

      // Coverage configuration
      coverage: {
        provider: 'v8',
        reporter: ['text', 'html', 'clover', 'json'],
        exclude: [
          'node_modules/',
          'src/test/',
          'src/**/*.d.ts',
          'src/main.tsx',
          'src/vite-env.d.ts',
          'src/components/**/index.ts',
          '**/*.config.ts',
          'build/',
          'dist/',
          'coverage/',
          'eslint.config.js',
        ],
        thresholds: {
          global: {
            branches: 85,
            functions: 85,
            lines: 85,
            statements: 85,
          },
        },
      },

      // Test timeout
      testTimeout: 10000,

      // Globals for easier testing
      globals: true,
    },
  };
});
