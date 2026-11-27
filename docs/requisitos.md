# Requisitos funcionales y de calidad

Este documento resume la especificación fuente recibida para el Sistema de Estacionamiento Automatizado. La especificación completa permanece en el texto de solicitud del proyecto.

## Capacidad y modalidades

- 7 plazas regulares, 3 reservadas y vehículos temporales sin plaza.
- Conteos separados; reservas asignadas no equivalen a ocupación física.
- No exceder capacidades ni permitir contadores negativos. Temporales no afectan plazas.
- Sólo confirmar un movimiento al detectar el vehículo y obtener sensor libre estable durante un intervalo configurable (inicialmente 500 ms).
- La barrera no se cierra antes de una detección válida. Una operación pendiente conserva temporalmente capacidad.

## Reservas

- Token numérico de seis dígitos creado aleatoriamente en backend.
- Máximo tres reservas asignadas por fecha; fechas actuales o futuras; zona `America/Argentina/Cordoba`.
- El token habilita varios ciclos de ingreso/salida durante su vigencia diaria. Conservar mantiene cupo; finalizar/revocar libera cupo. No expirar una ocupación física.
- Un vehículo reservado que pasa medianoche puede salir, pero no reingresar ni conservar la reserva.

## Interfaces

- Rutas `/entrada`, `/salida`, `/admin`, `/admin/login` y selección en `/`.
- Conductores seleccionan modalidad; las terminales no requieren inicio de sesión.
- Administrador autenticado gestiona reservas, sensores, actuadores, simulación, correcciones auditadas, historial y restablecimiento confirmado.
- La información compartida y sincronizada usa Supabase; no localStorage como fuente de verdad.

## Dispositivo y simulación

- Adaptadores intercambiables para simulación y futura ESP8266; sin firmware definitivo/pines en esta etapa.
- Simulación manual y automática, estado de conexión, sensores, día/noche, barreras, LEDs, semáforo y buzzer.
- Separar eventos simulados/reales y no emitir confirmaciones falsas cuando el dispositivo no responde.
- Firmware futuro: ESP8266 por HTTPS saliente, comandos idempotentes y autenticación específica.

## Seguridad y calidad

- Supabase Auth, RLS y RPC transaccionales; no confiar en validación de frontend.
- No publicar service role key ni credenciales del dispositivo.
- No exponer tokens en logs/historiales de terminal.
- SPA React/TypeScript/Vite/Tailwind, responsive y en español.
- README, decisiones, diagramas, migraciones y pruebas documentadas.
