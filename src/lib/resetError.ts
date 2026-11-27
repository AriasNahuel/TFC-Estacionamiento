function errorText(error: unknown): string {
  if (error instanceof Error) return error.message
  if (typeof error === 'string') return error
  if (typeof error === 'object' && error !== null && 'message' in error && typeof error.message === 'string') {
    return error.message
  }
  return ''
}

const resetReasons: Array<[string, string]> = [
  ['se requiere el rol de administrador', 'Tu sesión no tiene permisos de administrador. Volvé a ingresar con una cuenta administradora local.'],
  ['el restablecimiento de datos de prueba locales está deshabilitado', 'El restablecimiento está deshabilitado en esta base local.'],
  ['confirmá que el estacionamiento físico esté vacío', 'Confirmá que el estacionamiento físico esté vacío y que ambas barreras estén cerradas.'],
  ['las barreras deben estar cerradas y ambos sensores libres', 'Las dos barreras deben estar cerradas y ambos sensores deben estar libres.'],
  ['hay una operación vehicular en curso', 'Hay una operación vehicular en curso. Esperá a que finalice antes de restablecer.'],
  ['hay un comando físico pendiente o en ejecución', 'La ESP8266 tiene un comando pendiente o en ejecución. Esperá a que termine antes de restablecer.'],
  ['el controlador activo está desconectado', 'El controlador activo está desconectado. Reconectá la ESP8266 antes de restablecer.'],
  ['el heartbeat del controlador físico está vencido', 'La ESP8266 no envía un heartbeat reciente. Reconectala y esperá una actualización antes de volver a intentar.'],
  ['la telemetría reciente debe confirmar libres ambos sensores físicos', 'La ESP8266 debe informar telemetría reciente que confirme libres los dos sensores.'],
  ['la configuración del estacionamiento no está disponible', 'No se encontró la configuración del estacionamiento en Supabase local.'],
]

export function localResetFailureMessage(error: unknown): string {
  const message = errorText(error).trim()
  const normalized = message.toLocaleLowerCase()
  const reason = resetReasons.find(([needle]) => normalized.includes(needle))
  return (reason?.[1] ?? message) || 'Ocurrió un error inesperado al restablecer los datos locales.'
}
