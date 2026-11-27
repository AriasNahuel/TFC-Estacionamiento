import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig(({ mode }) => ({
  // El modo local usa variables aisladas y nunca hereda el .env.local raíz de Cloud.
  envDir: mode === 'localdev' ? './config/env/local' : '.',
  // Origen estable para que Auth y el almacén cifrado IndexedDB no cambien de puerto.
  server: mode === 'localdev' ? { host: '127.0.0.1', port: 5174, strictPort: true } : undefined,
  plugins: [react()],
}))
