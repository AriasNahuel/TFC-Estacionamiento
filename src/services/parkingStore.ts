import { applyPassage, canStart, localDate, type Direction, type GateOperation, type ParkingState, type Reservation, type VehicleType } from '../domain/parking'
import { isSupabaseConfigured } from '../lib/supabase'
import { supabaseParking } from './supabaseParking'

type Listener = () => void
function generateToken() {
  const values = new Uint32Array(1)
  const limit = Math.floor(0x1_0000_0000 / 1_000_000) * 1_000_000
  do { crypto.getRandomValues(values) } while (values[0] >= limit)
  return String(values[0] % 1_000_000).padStart(6, '0')
}
const initial: ParkingState = {
  counts: { regular: 2, reserved: 1, temporary: 0 },
  operations: {}, gates: { entry: 'closed', exit: 'closed' }, sensors: { entry: false, exit: false },
  reservations: [], history: [], night: false, connected: false, physicalConnected: false,
  physicalLastHeartbeatAt: null, sensorUpdatedAt: null, lightingTelemetry: null, latestManualCommand: null, automatic: true, mode: 'simulation',
}
let state = initial
const listeners = new Set<Listener>()
function emit() { listeners.forEach((listener) => listener()) }
export const parkingStore = {
  get: () => isSupabaseConfigured ? supabaseParking.get() : state,
  subscribe(listener: Listener) { return isSupabaseConfigured ? supabaseParking.subscribe(listener) : (listeners.add(listener), () => listeners.delete(listener)) },
  set(patch: Partial<ParkingState>) {
    if (isSupabaseConfigured) {
      const current = supabaseParking.get()
      void supabaseParking.setSettings(patch.mode === undefined ? current.mode === 'simulation' : patch.mode === 'simulation', patch.automatic ?? current.automatic, patch.night ?? current.night, patch.connected ?? current.connected).catch((error: Error) => console.error(error.message))
      return
    }
    state = { ...state, ...patch }; emit()
  },
  async start(direction: Direction, vehicle: VehicleType, reservation?: Reservation, reservationAction: 'retain' | 'finish' = 'retain') {
    if (isSupabaseConfigured) return supabaseParking.start(direction, vehicle, reservation?.token ?? '', reservationAction)
    const error = canStart(state, direction, vehicle, reservation)
    if (error) throw new Error(error)
    const operation: GateOperation = { id: crypto.randomUUID(), direction, vehicle, status: 'waiting', createdAt: new Date().toISOString(), ...(reservation ? { reservationId: reservation.id } : {}), ...(direction === 'exit' && vehicle === 'reserved' ? { reservationAction } : {}) }
    state = { ...state, operations: { ...state.operations, [direction]: operation }, gates: { ...state.gates, [direction]: 'waiting' } }
    emit()
    if (state.automatic) {
      globalThis.setTimeout(() => this.detect(direction), 1300)
      globalThis.setTimeout(() => this.release(direction), 2600)
    }
    return operation
  },
  detect(direction: Direction) {
    if (isSupabaseConfigured) return supabaseParking.detect(direction)
    const operation = state.operations[direction]
    if (!operation) return
    state = { ...state, sensors: { ...state.sensors, [direction]: true }, gates: { ...state.gates, [direction]: 'detected' }, operations: { ...state.operations, [direction]: { ...operation, status: 'detected' } } }
    emit()
  },
  release(direction: Direction) {
    if (isSupabaseConfigured) return supabaseParking.release(direction)
    if (state.operations[direction]?.status !== 'detected' || !state.sensors[direction]) return
    state = { ...state, sensors: { ...state.sensors, [direction]: false } }
    emit()
    globalThis.setTimeout(() => {
      const operation = state.operations[direction]
      if (!operation || state.sensors[direction]) return
      state = applyPassage({ ...state, gates: { ...state.gates, [direction]: 'closing' } }, operation)
      emit()
    }, 500)
  },
  cancel(direction: Direction) {
    if (isSupabaseConfigured) {
      const operation = supabaseParking.get().operations[direction]
      if (operation) return supabaseParking.cancelOperation(operation.id)
      return Promise.resolve()
    }
    state = { ...state, operations: { ...state.operations, [direction]: undefined }, gates: { ...state.gates, [direction]: 'closed' }, sensors: { ...state.sensors, [direction]: false } }
    emit()
  },
  createReservation(date: string) {
    if (isSupabaseConfigured) return supabaseParking.createReservation(date)
    if (date < localDate()) throw new Error('La fecha no puede ser anterior a hoy.')
    const assigned = state.reservations.filter((reservation) => reservation.date === date && !['finalizada', 'revocada'].includes(reservation.state)).length
    if (assigned >= 3) throw new Error('Ya existen tres reservas asignadas para esta fecha.')
    let token = generateToken()
    while (state.reservations.some((reservation) => reservation.token === token)) token = generateToken()
    const reservation = { id: crypto.randomUUID(), token, date, state: 'disponible' as const }
    state = { ...state, reservations: [reservation, ...state.reservations] }
    emit()
    return reservation
  },
  findReservation(token: string) { return isSupabaseConfigured ? undefined : state.reservations.find((reservation) => reservation.token === token) },
  reset() {
    if (isSupabaseConfigured) return supabaseParking.reset()
    state = { ...state, counts: { regular: 0, reserved: 0, temporary: 0 }, operations: {}, gates: { entry: 'closed', exit: 'closed' }, sensors: { entry: false, exit: false }, reservations: state.reservations.map((r) => ['finalizada', 'revocada'].includes(r.state) ? r : { ...r, state: 'revocada' }), automatic: true, night: false }
    emit()
  },
}
