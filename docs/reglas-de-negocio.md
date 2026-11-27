# Reglas de negocio

- Capacidades máximas: 7 regulares y 3 reservadas. Los vehículos temporales no ocupan plaza.
- Total presente = regular + reservado + temporal. Plazas físicamente ocupadas = regular + reservado.
- El semáforo automático sólo refleja disponibilidad regular; las reservas y temporales no lo cambian.
- Una modalidad de salida sólo decrementa su propio contador y exige ocupación de esa modalidad.
- Los movimientos se aplican tras detección válida seguida de sensor libre estable (500 ms configurable). Un flujo sin detección queda abierto y pendiente.
- Como máximo hay tres reservas activas por fecha. Las finalizadas, revocadas o vencidas sin vehículo liberan el cupo administrativo para emitir otro token; una reserva conservada sigue ocupándolo.
- Las reservas se confirman al persistirse en la base central local y pueden emitirse tanto en simulación como en modo hardware. En modo físico, el ingreso reservado sigue requiriendo token vigente, capacidad y heartbeat reciente de la ESP8266; la ocupación sólo se confirma con la secuencia de sensor estable.
- La vigencia de fecha comprende desde medianoche local hasta la medianoche siguiente (fin exclusivo), en `America/Argentina/Cordoba`.
- Al vencer con vehículo presente, se permite identificar su salida, se libera ocupación y se cancela definitivamente la reserva.
- El ingreso reservado requiere token vigente y capacidad física. El egreso requiere token asociado a vehículo presente aunque esté vencido.
- Las acciones administrativas que alteren estado deben quedar auditadas. El restablecimiento conserva historial y requiere confirmación.
