import { describe, expect, it } from 'vitest'
import { applyPassage, canStart, localDate, type ParkingState } from '../domain/parking'
import { parkingStore } from '../services/parkingStore'

const base: ParkingState = {
  counts: { regular: 6, reserved: 0, temporary: 0 }, operations: {}, gates: { entry: 'closed', exit: 'closed' },
  sensors: { entry: false, exit: false }, reservations: [], history: [], night: false, connected: false,
  physicalConnected: false, physicalLastHeartbeatAt: null, sensorUpdatedAt: null, latestManualCommand: null,
  lightingTelemetry: null,
  automatic: false, mode: 'simulation',
}

describe('reglas del estacionamiento', () => {
  it('rechaza superar la capacidad y bloquea la barrera cuando hay una operación pendiente', () => {
    const operation = { id: 'op-pendiente', direction: 'entry' as const, vehicle: 'regular' as const, status: 'waiting' as const, createdAt: new Date().toISOString() }
    expect(canStart({ ...base, counts: { ...base.counts, regular: 7 } }, 'entry', 'regular')).toMatch(/No hay plazas/)
    expect(canStart({ ...base, operations: { entry: operation } }, 'entry', 'regular')).toMatch(/operación en curso/)
  })

  it('rechaza una salida temporal sin vehículos y la habilita cuando hay uno activo', () => {
    expect(canStart(base, 'exit', 'temporary')).toBe('No hay vehículos temporales registrados dentro del predio.')
    expect(canStart({ ...base, counts: { ...base.counts, temporary: 1 } }, 'exit', 'temporary')).toBeNull()
  })

  it('no cierra ni contabiliza una operación sin confirmación de paso', () => {
    const unchanged = applyPassage(base, { id: 'missing', direction: 'entry', vehicle: 'regular', status: 'waiting', createdAt: '' })
    expect(unchanged.counts.regular).toBe(6)
  })

  it('confirma sólo la operación activa una vez y mantiene separados los temporales', () => {
    const operation = { id: 'op-1', direction: 'entry' as const, vehicle: 'temporary' as const, status: 'detected' as const, createdAt: new Date().toISOString() }
    const started = { ...base, operations: { entry: operation } }
    const confirmed = applyPassage(started, operation)
    expect(confirmed.counts).toEqual({ regular: 6, reserved: 0, temporary: 1 })
    expect(applyPassage(confirmed, operation)).toBe(confirmed)
  })

  it('actualiza la ocupación sólo después de detección y 500 ms libre', async () => {
    parkingStore.set({ counts: { regular: 0, reserved: 0, temporary: 0 }, operations: {}, history: [], automatic: false, reservations: [] })
    const operation = await parkingStore.start('entry', 'regular')
    expect(parkingStore.get().counts.regular).toBe(0)
    parkingStore.detect('entry')
    expect(parkingStore.get().counts.regular).toBe(0)
    parkingStore.release('entry')
    await new Promise((resolve) => setTimeout(resolve, 510))
    expect(parkingStore.get().counts.regular).toBe(1)
    expect(parkingStore.get().history[0]?.id).toBe(operation.id)
  })

  it('admite como máximo tres reservas activas por fecha', () => {
    parkingStore.set({ counts: { regular: 0, reserved: 0, temporary: 0 }, operations: {}, history: [], reservations: [] })
    const date = localDate()
    parkingStore.createReservation(date)
    parkingStore.createReservation(date)
    parkingStore.createReservation(date)
    expect(() => parkingStore.createReservation(date)).toThrow(/tres reservas/)
  })

  it('libera el cupo administrativo al finalizar una reserva y permite emitir más durante el día', async () => {
    parkingStore.set({ counts: { regular: 0, reserved: 0, temporary: 0 }, operations: {}, history: [], reservations: [] })
    const date = localDate()
    parkingStore.createReservation(date)
    parkingStore.createReservation(date)
    parkingStore.createReservation(date)
    parkingStore.set({ reservations: parkingStore.get().reservations.map((item, index) => index === 0 ? { ...item, state: 'finalizada' as const } : item) })
    expect((await parkingStore.createReservation(date)).date).toBe(date)
    expect(parkingStore.get().reservations).toHaveLength(4)
  })

  it('mantiene ocupación hasta la salida de una reserva vencida y luego la finaliza', () => {
    const reservation = { id: 'res-vencida', token: '123456', date: '2020-01-01', state: 'estacionado' as const }
    const operation = { id: 'salida-vencida', direction: 'exit' as const, vehicle: 'reserved' as const, status: 'detected' as const, createdAt: '', reservationId: reservation.id, reservationAction: 'retain' as const }
    const current: ParkingState = { ...base, counts: { ...base.counts, reserved: 1 }, reservations: [reservation], operations: { exit: operation } }
    const completed = applyPassage(current, operation)
    expect(completed.counts.reserved).toBe(0)
    expect(completed.reservations[0]?.state).toBe('finalizada')
  })
})
