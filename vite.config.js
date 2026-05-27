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
