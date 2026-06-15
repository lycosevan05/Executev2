import path from 'node:path'
import { fileURLToPath } from 'node:url'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
  ],
  build: {
    // Pin the build entry to the root index.html so Rollup/Vite's scanner can
    // never crawl into ios/ (DerivedData, or the iOS-bundled copy of the app in
    // ios/App/App/public). server.fs.deny below is dev-server only and does NOT
    // apply to `vite build`, so without this the build can walk thousands of
    // native/build-output files and take minutes.
    rollupOptions: {
      input: path.resolve(__dirname, 'index.html'),
    },
    // Bundle all CSS into a single stylesheet loaded upfront from index.html
    // instead of per-async-chunk CSS. Capacitor's WKWebView (capacitor://
    // scheme) sometimes never fires the `load` event on dynamically injected
    // <link rel="stylesheet"> elements, which makes Vite's preload helper hang
    // forever — freezing any dynamic import() whose chunk carries a CSS dep
    // (e.g. @revenuecat/purchases-capacitor's web paywall CSS). Disabling CSS
    // code-splitting removes the CSS dep from async chunks so imports resolve.
    cssCodeSplit: false,
  },
  resolve: {
    alias: [
      { find: '@', replacement: path.resolve(__dirname, './src') },
      { find: /^lucide-react$/, replacement: path.resolve(__dirname, './src/lib/lucide-react.js') },
      { find: /^recharts$/, replacement: path.resolve(__dirname, './src/lib/recharts.js') },
    ],
  },
  // Prevent Vite from picking up the iOS-bundled copy of dist as a second entry.
  optimizeDeps: {
    entries: ['index.html'],
    include: [
      '@hello-pangea/dnd',
      'react-redux',
      'use-sync-external-store/with-selector.js',
    ],
    noDiscovery: false,
    holdUntilCrawlEnd: false,
  },
  server: {
    host: true,
    watch: {
      ignored: ['**/ios/**', '**/dist/**'],
    },
    fs: {
      deny: ['**/ios/**'],
    },
  },
});
