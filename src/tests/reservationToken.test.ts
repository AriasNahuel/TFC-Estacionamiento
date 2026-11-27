import { describe, expect, it } from 'vitest'
import { normalizeReservationTokenInput } from '../domain/reservationToken'

describe('entrada de token reservado', () => {
  it('conserva ceros iniciales al escribir o pegar el token', () => {
    expect(normalizeReservationTokenInput('001234')).toBe('001234')
  })

  it('elimina separadores y caracteres que no sean dígitos', () => {
    expect(normalizeReservationTokenInput(' 00-12 34 ')).toBe('001234')
  })

  it('limita el valor a los seis dígitos del token', () => {
    expect(normalizeReservationTokenInput('123456789')).toBe('123456')
  })
})
