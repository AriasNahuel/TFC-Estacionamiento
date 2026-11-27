import { useSyncExternalStore } from 'react'
import { parkingStore } from '../services/parkingStore'
import { isSupabaseConfigured } from '../lib/supabase'
import { supabaseParking } from '../services/supabaseParking'
import { useEffect } from 'react'

export function useParking() {
  const store = isSupabaseConfigured ? supabaseParking : parkingStore
  const state = useSyncExternalStore(store.subscribe, store.get, store.get)
  useEffect(() => {
    if (!isSupabaseConfigured) return
    void supabaseParking.connect()
    return () => supabaseParking.disconnect()
  }, [])
  return state
}
