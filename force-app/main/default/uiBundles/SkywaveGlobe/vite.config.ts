import { existsSync } from 'node:fs';
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
 * Live feed transport note (no proxy needed):
 *
 * Reads/writes go through UI API GraphQL + the Data SDK, proxied in dev by the
 * official salesforce({orgAlias}) plugin (/services/data). The LIVE feed is a
 * WebSocket to the Heroku relay's /ws/monitor channel (Pub/Sub runs server-side
 * there — see useDemoFeed.ts for why browser-direct CometD/Pub/Sub is a dead
 * end). That WS is an absolute wss:// URL, so it works the same in dev and
 * in-org with NO Vite proxy. Point dev at a different relay via VITE_RELAY_WS_URL.
 */
export default defineConfig(() => {
  return {
    base: './',
    plugins: [
      tailwindcss(),
      react(),
      // orgAlias makes the plugin's /services/data/.../graphql proxy resolve
      // the right org's auth (refresh-aware) so createDataSDK().graphql() works
      // in dev. Defaults to `si`; override with SKYWAVE_ORG.
      salesforce({ orgAlias: process.env.SKYWAVE_ORG || 'si' }),
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
