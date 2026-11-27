export type VehicleType = 'regular' | 'reserved' | 'temporary'
export type Direction = 'entry' | 'exit'
export type GateStatus = 'closed' | 'opening' | 'waiting' | 'detected' | 'closing' | 'error'

export const CAPACITY = { regular: 7, reserved: 3 } as const

export interface Counts {
  regular: number
  reserved: number
  temporary: number
}

export interface GateOperation {
  id: string
  direction: Direction
  vehicle: VehicleType
  status: 'waiting' | 'detected'
  createdAt: string
  /** Controlador que confirma sensores; distinto de quien solicitó el movimiento. */
  source?: 'simulation' | 'device' | 'admin'
  requestOrigin?: 'terminal' | 'admin'
  reservationId?: string
  reservationAction?: 'retain' | 'finish'
}

export interface Reservation {
  id: string
  token: string
  tokenSuffix?: string
  date: string
  state: 'disponible' | 'estacionado' | 'conservada' | 'finalizada' | 'revocada' | 'vencida'
}

export interface Movement {
  id: string
  at: string
  direction: Direction
  vehicle: VehicleType
  simulated: boolean
}

export interface ParkingState {
  counts: Counts
  operations: Partial<Record<Direction, GateOperation>>
  gates: Record<Direction, GateStatus>
  sensors: Record<Direction, boolean>
  reservations: Reservation[]
  history: Movement[]
  night: boolean
  connected: boolean
  physicalConnected: boolean
  physicalLastHeartbeatAt: string | null
  sensorUpdatedAt: string | null
  lightingTelemetry: { ldrNight: boolean; whiteLightsOn: boolean; rgbState: 'off' | 'red' | 'green'; manual: boolean } | null
  latestManualCommand: { id: string; action: string; target: string | null; status: string; result: Record<string, unknown> | null } | null
  automatic: boolean
  mode: 'simulation' | 'hardware'
}

export function canStart(state: ParkingState, direction: Direction, vehicle: VehicleType, reservation?: Reservation): string | null {
  if (state.operations[direction]) return 'Ya hay una operación en curso en esta barrera.'
  if (direction === 'entry') {
    if (vehicle === 'regular' && state.counts.regular + pending(state, 'entry', 'regular') >= CAPACITY.regular) return 'No hay plazas regulares disponibles.'
    if (vehicle === 'reserved') {
      if (!reservation) return 'Ingresá un token reservado válido.'
      if (reservation.date !== localDate()) return 'Este token no está vigente para la fecha actual.'
      if (!['disponible', 'conservada'].includes(reservation.state)) return 'Este token no está disponible para ingresar.'
      if (state.counts.reserved + pending(state, 'entry', 'reserved') >= CAPACITY.reserved) return 'No hay capacidad física reservada disponible.'
      if (state.operations.exit?.reservationId === reservation.id) return 'Este token ya está en uso.'
    }
    return null
  }
  if (vehicle === 'regular' && state.counts.regular <= 0) return 'No hay vehículos regulares registrados dentro del predio.'
  if (vehicle === 'temporary' && state.counts.temporary <= 0) return 'No hay vehículos temporales registrados dentro del predio.'
  if (vehicle === 'reserved') {
    if (!reservation || reservation.state !== 'estacionado') return 'No hay un vehículo estacionado asociado a este token.'
  }
  return null
}

function pending(state: ParkingState, direction: Direction, vehicle: VehicleType) {
  return state.operations[direction]?.vehicle === vehicle ? 1 : 0
}

export function localDate(date = new Date()) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Cordoba', year: 'numeric', month: '2-digit', day: '2-digit' }).format(date)
}

export function applyPassage(state: ParkingState, operation: GateOperation): ParkingState {
  if (!state.operations[operation.direction] || state.operations[operation.direction]?.id !== operation.id) return state
  const change = operation.direction === 'entry' ? 1 : -1
  const counts = { ...state.counts, [operation.vehicle]: state.counts[operation.vehicle] + change }
  if (counts[operation.vehicle] < 0 || counts.regular > CAPACITY.regular || counts.reserved > CAPACITY.reserved) return state
  const reservations = state.reservations.map((item) => item.id !== operation.reservationId ? item : {
    ...item, state: operation.direction === 'entry' ? 'estacionado' as const : (item.date === localDate() && operation.reservationAction !== 'finish' ? 'conservada' as const : 'finalizada' as const),
  })
  return {
    ...state,
    counts,
    reservations,
    operations: { ...state.operations, [operation.direction]: undefined },
    gates: { ...state.gates, [operation.direction]: 'closed' },
    sensors: { ...state.sensors, [operation.direction]: false },
    history: [{ id: operation.id, at: new Date().toISOString(), direction: operation.direction, vehicle: operation.vehicle, simulated: state.mode === 'simulation' }, ...state.history],
  }
}
