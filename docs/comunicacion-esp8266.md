# Contrato Supabase–ESP8266

La integración utiliza la cola RPC existente. La telemetría y los controles físicos descritos abajo están implementados; la secuencia física de validación queda pendiente de carga autorizada del firmware. No asumir sensores individuales de plaza.

## Identidad y ciclo de conexión

- Hay dos identidades separadas: `simulated-esp8266` para probar la secuencia central y `esp8266-main` reservada al controlador físico futuro. Un administrador genera la credencial sólo para `esp8266-main`; PostgreSQL conserva SHA-256 del secreto. Nunca se copia esa credencial a una terminal ni al simulador.
- El firmware LOCAL llama `report_device_sensor_state` con el nivel activo-bajo de entrada y salida al iniciar, cuando cambia cualquiera de los estados y cada 10 segundos. Esa RPC actualiza `device_state.state.sensor_telemetry`, su fecha y el heartbeat autenticado. Terminales y controles requieren heartbeat de menos de 30 segundos.
- La placa reclama órdenes mediante `claim_device_commands`. Cada orden tiene vencimiento; la placa informa `running`, `confirmed` o `failed` con `ack_device_command`.
- Los comandos se identifican con `operation_id` y existe como máximo una orden `open_gate` por operación.

## Confirmación física

`report_device_sensor` acepta únicamente la credencial física, una operación con `source='device'` y una orden `open_gate` confirmada. Tras detección y liberación estable, `finish_device_operation` confirma con la misma credencial. El servidor comprueba que pasaron 500 ms reales desde la liberación; sólo entonces actualiza contadores, reserva e historial de forma idempotente.

En modo de simulación, `/entrada` y `/salida` crean operaciones con `source='simulation'` y `request_origin='terminal'`; no se crea comando físico y no se toca el heartbeat de `esp8266-main`. El panel admin conduce el sensor simulado mediante `simulate_sensor` y confirma con `finish_simulated_operation`. Este contrato deja las reglas transaccionales comunes a ambos controladores.

La terminal no recibe la credencial ESP8266 y no puede reportar eventos del sensor. No se implementó una Edge Function ni se probó aún este ciclo con el dispositivo. La configuración HTTPS `setInsecure()` de pruebas físicas previas no debe usarse como validación TLS de producción.

## Limitaciones

- Si Supabase se pierde, estas RPC no reemplazan el almacenamiento offline del ESP. La cola local duradera, conciliación, recuperación horaria y modo router/AP deben diseñarse y probarse aparte.
- El protocolo SQL no identifica por sí solo WiFi vs. Internet ni reinicios; se necesitan eventos explícitos del firmware.
- No se confirma un movimiento por una orden de abrir, sólo por la secuencia física estable reportada.

## Telemetría y mantenimiento físico local

- `device_state` ya pertenece a `supabase_realtime`; la RPC de telemetría ahora incluye el estado efectivo de histéresis del LDR, luces blancas, RGB y override manual. El dashboard escucha sus cambios y marca sensores/iluminación como “Sin comunicación” si la lectura supera 30 segundos. No se hacen RPC cada 200 ms: ese intervalo se conserva sólo para leer el LDR localmente. Se reporta al arrancar, ante cambios y en el heartbeat de 10 segundos.
- `hardware_commands` se agregó a Realtime. `queue_manual_hardware_command` crea exclusivamente `manual_control`, autenticado por rol admin, con idempotencia por request UUID y sin `operation_id`. El ACK registra el estado y resultado físico en esa fila.
- La cola permite barreras entrada/salida (`barrier_open`, `barrier_close`), luces blancas y RGB, además de `lighting_auto`. La placa mantiene las posiciones/canales físicos existentes. Durante un cierre vuelve a abrir si detecta el obstáculo; el backend requiere que el sensor esté libre según lectura reciente.
- La creación se rechaza durante una operación física activa. Un trigger transaccional comparte el bloqueo de `parking_state` y evita una carrera entre orden manual pendiente y nueva operación. Otro trigger rechaza cualquier orden manual hasta que ambas lecturas estén frescas; esto mantiene incompatibles placas con firmware anterior.
- Las pruebas ejecutadas son SQL, frontend y compilación local. No se cargó firmware ni se movieron barreras; por eso el estado de sensores seguirá como “Sin comunicación” hasta que el firmware LOCAL compilado informe su primera lectura.
