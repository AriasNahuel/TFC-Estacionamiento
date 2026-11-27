import type { RealtimeChannel } from '@supabase/supabase-js'
import { supabase } from '../lib/supabase'
import type { Direction, GateOperation, Movement, ParkingState, Reservation, VehicleType } from '../domain/parking'
import { readTerminalCredential, terminalCredentialStorage, type TerminalCredentialStatus } from './terminalCredentials'

type DbRow = Record<string, unknown>
export interface TerminalOperationProgress {
  operation_id: string
  direction: Direction
  vehicle_type: VehicleType
  operation_status: 'pending' | 'detected' | 'confirmed' | 'cancelled' | 'failed'
  source?: 'simulation' | 'device' | 'admin'
  command_status: 'pending' | 'received' | 'running' | 'confirmed' | 'failed' | 'cancelled' | null
  command_result: Record<string, unknown> | null
}
const initial: ParkingState = {
  counts: { regular: 0, reserved: 0, temporary: 0 }, operations: {},
  gates: { entry: 'closed', exit: 'closed' }, sensors: { entry: false, exit: false },
  reservations: [], history: [], night: false, connected: false, physicalConnected: false,
  physicalLastHeartbeatAt: null, sensorUpdatedAt: null, lightingTelemetry: null, latestManualCommand: null, automatic: true, mode: 'simulation',
}
let snapshot = initial
let channel: RealtimeChannel | null = null
let listener: (() => void) | null = null
let generation = 0
let refreshCurrent: (() => Promise<void>) | null = null
const mapVehicle = (value: unknown) => value === 'reserved' || value === 'temporary' ? value : 'regular'

function emit(next: ParkingState) { snapshot = next; listener?.() }
function mapReservation(row: DbRow): Reservation {
  const states: Record<string, Reservation['state']> = { available: 'disponible', scheduled: 'disponible', parked: 'estacionado', retained: 'conservada', expired_occupied: 'estacionado', finished: 'finalizada', expired: 'vencida', revoked: 'revocada' }
  return { id: String(row.id), token: '', tokenSuffix: String(row.token_suffix ?? ''), date: String(row.reserved_for), state: states[String(row.effective_state ?? row.state)] ?? 'disponible' }
}
function mapOperation(row: DbRow): GateOperation {
  return { id: String(row.id), direction: row.direction as Direction, vehicle: mapVehicle(row.vehicle_type), status: row.status === 'detected' ? 'detected' : 'waiting', createdAt: String(row.created_at), source: row.source as GateOperation['source'], requestOrigin: row.request_origin as GateOperation['requestOrigin'], ...(row.reservation_id ? { reservationId: String(row.reservation_id) } : {}), ...(row.reservation_action ? { reservationAction: row.reservation_action as 'retain' | 'finish' } : {}) }
}

export const supabaseParking = {
  get: () => snapshot,
  subscribe(callback: () => void) { listener = callback; return () => { if (listener === callback) listener = null } },
  async connect() {
    if (!supabase) return
    const id = ++generation
    const refresh = async () => {
      const client = supabase
      if (!client) return
      const { data: auth } = await client.auth.getSession()
      const isAuthenticated = Boolean(auth.session)
      const [stateResult, opsResult, reservationResult, historyResult, deviceResult, physicalResult, manualResult] = await Promise.all([
        client.from('parking_state').select('*').eq('id', 1).maybeSingle(),
        isAuthenticated ? client.from('vehicle_operations').select('*').in('status', ['pending', 'detected']) : Promise.resolve({ data: [], error: null }),
        isAuthenticated ? client.from('reservation_admin_view').select('*').order('created_at', { ascending: false }).limit(100) : Promise.resolve({ data: [], error: null }),
        isAuthenticated ? client.from('audit_events').select('*').in('event_type', ['vehicle_entered', 'vehicle_exited']).order('created_at', { ascending: false }).limit(100) : Promise.resolve({ data: [], error: null }),
        isAuthenticated ? client.from('device_state').select('connected').eq('device_id', 'simulated-esp8266').maybeSingle() : Promise.resolve({ data: null, error: null }),
        isAuthenticated ? client.from('device_state').select('connected,last_heartbeat,state').eq('device_id', 'esp8266-main').maybeSingle() : Promise.resolve({ data: null, error: null }),
        isAuthenticated ? client.from('hardware_commands').select('id,payload,status,result,issued_at').eq('device_id', 'esp8266-main').eq('command_type', 'manual_control').order('issued_at', { ascending: false }).limit(1).maybeSingle() : Promise.resolve({ data: null, error: null }),
      ])
      if (id !== generation) return
      const row = (stateResult.data ?? {}) as DbRow
      const ops = (opsResult.data ?? []) as DbRow[]
      const operations: ParkingState['operations'] = {}
      for (const operation of ops) operations[operation.direction as Direction] = mapOperation(operation)
      const history: Movement[] = ((historyResult.data ?? []) as DbRow[]).map((event) => ({ id: String(event.operation_id ?? event.id), at: String(event.created_at), direction: event.event_type === 'vehicle_entered' ? 'entry' : 'exit', vehicle: mapVehicle(event.vehicle_type), simulated: event.source === 'simulation' }))
      const device = (physicalResult.data ?? {}) as DbRow
      const deviceState = (device.state ?? {}) as DbRow
      const sensorTelemetry = (deviceState.sensor_telemetry ?? {}) as DbRow
      const rgb = sensorTelemetry.rgb_state
      const lightingTelemetry = typeof sensorTelemetry.ldr_night === 'boolean' && typeof sensorTelemetry.white_lights_on === 'boolean' && typeof sensorTelemetry.lighting_manual === 'boolean' && (rgb === 'off' || rgb === 'red' || rgb === 'green')
        ? { ldrNight: sensorTelemetry.ldr_night, whiteLightsOn: sensorTelemetry.white_lights_on, rgbState: rgb as 'off' | 'red' | 'green', manual: sensorTelemetry.lighting_manual }
        : null
      const manual = manualResult.data as DbRow | null
      const manualPayload = (manual?.payload ?? {}) as DbRow
      const state: ParkingState = {
        counts: { regular: Number(row.regular_count ?? 0), reserved: Number(row.reserved_count ?? 0), temporary: Number(row.temporary_count ?? 0) },
        operations,
        gates: { entry: String(row.entry_gate ?? 'closed') as ParkingState['gates']['entry'], exit: String(row.exit_gate ?? 'closed') as ParkingState['gates']['exit'] },
        sensors: {
          entry: row.simulation_mode === false ? Boolean(sensorTelemetry.entry_detected) : Boolean(row.entry_sensor),
          exit: row.simulation_mode === false ? Boolean(sensorTelemetry.exit_detected) : Boolean(row.exit_sensor),
        },
        reservations: ((reservationResult.data ?? []) as DbRow[]).map(mapReservation), history,
        night: Boolean(row.night_mode), connected: row.simulation_mode === false ? Boolean(device.connected) : Boolean(deviceResult.data?.connected),
        physicalConnected: Boolean(device.connected), physicalLastHeartbeatAt: typeof device.last_heartbeat === 'string' ? device.last_heartbeat : null,
        sensorUpdatedAt: typeof sensorTelemetry.updated_at === 'string' ? sensorTelemetry.updated_at : null,
        lightingTelemetry,
        latestManualCommand: manual ? { id: String(manual.id), action: String(manualPayload.action ?? ''), target: typeof manualPayload.target === 'string' ? manualPayload.target : null, status: String(manual.status), result: manual.result && typeof manual.result === 'object' ? manual.result as Record<string, unknown> : null } : null,
        automatic: Boolean(row.automatic_simulation), mode: row.simulation_mode === false ? 'hardware' : 'simulation',
      }
      emit(state)
      const errors = [stateResult.error, opsResult.error, reservationResult.error, historyResult.error, deviceResult.error, physicalResult.error, manualResult.error].filter(Boolean)
      if (errors.length) console.error('No se pudo sincronizar el estado de Supabase.', errors)
    }
    refreshCurrent = refresh
    await refresh()
    if (!channel) channel = supabase.channel('parking-central-state')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'parking_state' }, () => void refreshCurrent?.())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'vehicle_operations' }, () => void refreshCurrent?.())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'reservations' }, () => void refreshCurrent?.())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'audit_events' }, () => void refreshCurrent?.())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'device_state' }, () => void refreshCurrent?.())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'hardware_commands' }, () => void refreshCurrent?.())
      .subscribe((status) => { if (status === 'SUBSCRIBED') void refreshCurrent?.() })
  },
  disconnect() { generation++; refreshCurrent = null; if (channel && supabase) void supabase.removeChannel(channel); channel = null },
  async createReservation(date: string) {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { data, error } = await supabase.rpc('create_reservation', { p_reserved_for: date }).single()
    if (error) throw error
    const row = data as { reservation_id: string; access_token: string; reserved_for: string }
    await this.connect()
    return { id: row.reservation_id, token: row.access_token, date: row.reserved_for, state: 'disponible' as const }
  },
  async getReservationTokens(date: string) {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { data, error } = await supabase.rpc('admin_reservation_tokens_for_date', { p_reserved_for: date })
    if (error) throw error
    return ((data ?? []) as DbRow[]).map((row) => ({ id: String(row.reservation_id), token: typeof row.access_token === 'string' ? row.access_token : null }))
  },
  async regenerateReservationToken(id: string) {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { data, error } = await supabase.rpc('regenerate_reservation_token', { p_reservation_id: id }).single()
    if (error) throw error
    const row = data as { reservation_id: string; access_token: string }
    return { id: row.reservation_id, token: row.access_token }
  },
  async revokeReservation(id: string) {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { error } = await supabase.rpc('revoke_reservation', { p_reservation_id: id })
    if (error) throw error
    await this.connect()
  },
  async start(direction: Direction, vehicle: VehicleType, token = '', action: 'retain' | 'finish' = 'retain') {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { error } = await supabase.rpc('start_simulated_operation', { p_direction: direction, p_vehicle: vehicle, p_reservation_token: token || null, p_action: action, p_idempotency_key: crypto.randomUUID() })
    if (error) throw error
    await this.connect()
    if (snapshot.automatic) {
      window.setTimeout(() => void this.detect(direction), 1300)
      window.setTimeout(() => void this.release(direction), 2600)
    }
    const operation = snapshot.operations[direction]
    if (!operation) throw new Error('La operación no apareció en el estado compartido.')
    return operation
  },
  async startTerminal(direction: Direction, vehicle: VehicleType, token: string, action: 'retain' | 'finish') {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const terminalId = `terminal-${direction}`
    const secret = await readTerminalCredential(direction, terminalCredentialStorage)
    if (!secret) throw new Error('Esta terminal no está vinculada. Solicitá al administrador la credencial de terminal.')
    const { data, error } = await supabase.rpc('start_terminal_operation', {
      p_terminal_id: terminalId, p_terminal_secret: secret, p_direction: direction, p_vehicle: vehicle,
      p_reservation_token: vehicle === 'reserved' ? token : null, p_action: action, p_idempotency_key: crypto.randomUUID(),
    })
    if (error) throw error
    if (!data) {
      if (vehicle === 'reserved') throw new Error('Token inválido, vencido, no sincronizado o intentos temporalmente limitados.')
      if (direction === 'exit' && vehicle === 'temporary') {
        const { data: availability, error: availabilityError } = await supabase.from('parking_state').select('temporary_count').eq('id', 1).maybeSingle()
        if (!availabilityError && Number((availability as DbRow | null)?.temporary_count ?? 0) <= 0)
          throw new Error('No hay vehículos temporales para retirar.')
        throw new Error('No se pudo autorizar la salida temporal. Verificá el estado del vehículo y la conexión de la terminal.')
      }
      if (direction === 'exit' && vehicle === 'regular')
        throw new Error('No se pudo autorizar la salida regular. Verificá que haya vehículos registrados y que la terminal esté conectada.')
      throw new Error('No se pudo autorizar la operación. Verificá la conexión de la terminal e intentá nuevamente.')
    }
    return String(data)
  },
  async validateTerminalCredential(direction: Direction, secret: string) {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { data, error } = await supabase.rpc('validate_terminal_credential', {
      p_terminal_id: `terminal-${direction}`, p_terminal_secret: secret, p_lane: direction,
    })
    if (error) throw error
    return data === true
  },
  async getTerminalCredentialStatus(direction: Direction, secret: string): Promise<TerminalCredentialStatus> {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { data, error } = await supabase.rpc('terminal_credential_status', {
      p_terminal_id: `terminal-${direction}`, p_terminal_secret: secret, p_lane: direction,
    })
    if (error) throw error
    if (data === 'valid' || data === 'invalid' || data === 'revoked' || data === 'blocked') return data
    throw new Error('Supabase devolvió un estado de credencial desconocido.')
  },
  async getTerminalOperation(direction: Direction, operationId: string) {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const terminalId = `terminal-${direction}`
    const secret = await readTerminalCredential(direction, terminalCredentialStorage)
    if (!secret) throw new Error('Credencial de terminal no disponible.')
    const { data, error } = await supabase.rpc('get_terminal_operation_progress', { p_terminal_id: terminalId, p_terminal_secret: secret, p_operation_id: operationId }).single()
    if (!error) return data as TerminalOperationProgress
    if (error.code !== 'PGRST202') throw error
    const fallback = await supabase.rpc('get_terminal_operation', { p_terminal_id: terminalId, p_terminal_secret: secret, p_operation_id: operationId }).single()
    if (fallback.error) throw fallback.error
    const operation = fallback.data as { operation_id: string; direction: Direction; vehicle_type: VehicleType; status: TerminalOperationProgress['operation_status'] }
    return {
      operation_id: operation.operation_id,
      direction: operation.direction,
      vehicle_type: operation.vehicle_type,
      operation_status: operation.status,
      command_status: null,
      command_result: null,
    }
  },
  async getActiveTerminalOperation(direction: Direction) {
    if (!supabase) return null
    const terminalId = `terminal-${direction}`
    const secret = await readTerminalCredential(direction, terminalCredentialStorage)
    if (!secret) return null
    const { data, error } = await supabase.rpc('get_active_terminal_operation', { p_terminal_id: terminalId, p_terminal_secret: secret }).maybeSingle()
    if (error) throw error
    return data as { operation_id: string; status: string } | null
  },
  async detect(direction: Direction) {
    const operation = snapshot.operations[direction]
    if (!supabase || !operation) return
    const { error } = await supabase.rpc('simulate_sensor', { p_operation_id: operation.id, p_detected: true, p_clear_ms: 0 })
    if (error) throw error
    await this.connect()
  },
  async release(direction: Direction) {
    const operation = snapshot.operations[direction]
    if (!supabase || !operation || operation.status !== 'detected') return
    const { error } = await supabase.rpc('simulate_sensor', { p_operation_id: operation.id, p_detected: false, p_clear_ms: 500 })
    if (error) throw error
    await this.connect()
    window.setTimeout(async () => {
      const result = await supabase?.rpc('finish_simulated_operation', { p_operation_id: operation.id })
      if (result?.error) console.error('No se pudo confirmar la operación simulada.', result.error)
      await this.connect()
    }, 650)
  },
  async runAutomaticTerminalSimulation(operationId: string) {
    if (!supabase) return
    const pause = (ms: number) => new Promise((resolve) => window.setTimeout(resolve, ms))
    await pause(900)
    const detected = await supabase.rpc('simulate_sensor', { p_operation_id: operationId, p_detected: true, p_clear_ms: 0 })
    if (detected.error) throw detected.error
    await pause(900)
    const released = await supabase.rpc('simulate_sensor', { p_operation_id: operationId, p_detected: false, p_clear_ms: 500 })
    if (released.error) throw released.error
    await pause(650)
    const finished = await supabase.rpc('finish_simulated_operation', { p_operation_id: operationId })
    if (finished.error) throw finished.error
    await this.connect()
  },
  async setSettings(simulationMode: boolean, automatic: boolean, night: boolean, connected: boolean) {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { error } = await supabase.rpc('set_simulation_settings', { p_simulation_mode: simulationMode, p_automatic: automatic, p_night: night, p_device_connected: connected })
    if (error) throw error
    await this.connect()
  },
  async queueManualHardwareCommand(action: string, target: Direction | null) {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { data, error } = await supabase.rpc('queue_manual_hardware_command', { p_action: action, p_target: target, p_request_id: crypto.randomUUID() })
    if (error) throw error
    await this.connect()
    return String(data)
  },
  async isLocalTestDataResetEnabled() {
    if (!supabase) return false
    const { data, error } = await supabase.rpc('local_test_data_reset_enabled')
    if (error) throw error
    return data === true
  },
  async resetLocalTestData(confirmPhysicalEmpty: boolean) {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { data, error } = await supabase.rpc('reset_local_test_data', { p_confirm_physical_empty: confirmPhysicalEmpty })
    if (error) throw error
    await this.connect()
    return data as {
      reservations_deleted: number
      tokens_hmac_deleted: number
      tokens_encrypted_deleted: number
      operations_deleted: number
      commands_deleted: number
      audit_events_deleted: number
      token_attempt_windows_deleted: number
      regular_count: number
      reserved_count: number
      temporary_count: number
      reserved_contingency_count: number
    }
  },
  async reset() {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { error } = await supabase.rpc('reset_parking_demo')
    if (error) throw error
    await this.connect()
  },
  async cancelOperation(id: string) {
    if (!supabase) throw new Error('Supabase no está configurado.')
    const { error } = await supabase.rpc('cancel_operation', { p_operation_id: id })
    if (error) throw error
    await this.connect()
  },
}

