import { describe, expect, it } from 'vitest'
import { localResetFailureMessage } from '../lib/resetError'

describe('mensajes del restablecimiento local', () => {
  it('explica que se requiere un heartbeat reciente del controlador', () => {
    expect(localResetFailureMessage(new Error('el heartbeat del controlador físico está vencido')))
      .toMatch(/no envía un heartbeat reciente/i)
  })

  it('lee el mensaje de errores recibidos como objetos simples', () => {
    expect(localResetFailureMessage({ message: 'hay una operación vehicular en curso' }))
      .toMatch(/operación vehicular en curso/i)
  })

  it('explica el bloqueo por telemetría vieja o no libre', () => {
    expect(localResetFailureMessage({ message: 'la telemetría reciente debe confirmar libres ambos sensores físicos' }))
      .toMatch(/telemetría reciente/i)
  })

  it('preserva mensajes de error no mapeados y usa un fallback si faltan', () => {
    expect(localResetFailureMessage({ message: 'falló la llamada local' })).toBe('falló la llamada local')
    expect(localResetFailureMessage({ code: 'PGRST000' })).toMatch(/error inesperado/i)
  })
})
