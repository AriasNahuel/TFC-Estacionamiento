import { defineConfig } from 'vitest/config'

// La suite actual prueba reglas y servicios, sin montar componentes.
// Node evita inicializar JSDOM; un worker thread basta para estos tests.
export default defineConfig({
  test: {
    environment: 'node',
    globals: true,
    pool: 'threads',
    maxWorkers: 1,
  },
})
