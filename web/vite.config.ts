/// <reference types="vitest/config" />
import { fileURLToPath, URL } from 'node:url';
import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    port: 5173,
  },
  build: {
    target: 'es2022',
    sourcemap: true,
    rollupOptions: {
      output: {
        // Long-lived vendor chunks so feature deploys don't bust them. Heavy
        // libraries (FullCalendar, Recharts, signature_pad) are NOT listed:
        // they stay inside the lazily loaded feature chunks that import them.
        manualChunks(id) {
          if (!id.includes('/node_modules/')) return undefined;
          if (
            /\/node_modules\/(react|react-dom|scheduler|react-router|cookie|set-cookie-parser)\//.test(
              id,
            )
          ) {
            return 'react';
          }
          if (/\/node_modules\/(@tanstack|@supabase)\//.test(id)) return 'data';
          if (/\/node_modules\/(zod|react-hook-form|@hookform)\//.test(id)) return 'forms';
          return undefined;
        },
      },
    },
  },
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    testTimeout: 15_000,
    hookTimeout: 15_000,
    css: false,
    restoreMocks: true,
    env: {
      // Run in a zone no test shop uses, so "browser zone ≠ shop zone" is always exercised.
      TZ: 'Pacific/Honolulu',
      // Tests never talk to a real backend; lib/supabase is mocked where used.
      VITE_SUPABASE_URL: 'https://unit-test.supabase.co',
      VITE_SUPABASE_ANON_KEY: 'unit-test-anon-key',
    },
  },
});
