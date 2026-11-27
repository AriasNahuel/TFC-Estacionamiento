import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const publicKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY
// Vitest siempre usa el store aislado: los tests nunca deben contactar el proyecto remoto.
export const isSupabaseConfigured = import.meta.env.MODE !== 'test' && Boolean(url && publicKey)
const localHosts = new Set(['localhost', '127.0.0.1', '::1'])
export const isLocalSupabase = (() => {
  if (!isSupabaseConfigured || !url) return false
  try { return localHosts.has(new URL(url).hostname) } catch { return false }
})()
export const supabase = isSupabaseConfigured ? createClient(url, publicKey) : null
