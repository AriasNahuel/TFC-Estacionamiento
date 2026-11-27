# Seguridad y puesta en marcha de Supabase

El esquema desplegado parte de `202611200001_initial_schema.sql` y `202611210001_connected_simulation.sql`. La integración de terminales con el controlador simulado se entrega en `202611210002_simulated_terminal_controller.sql`; aplicala después de las dos anteriores. Esta guía no ejecuta migraciones remotas.

## Administrador inicial

1. En **Authentication → Settings**, desactivá los registros públicos.
2. Creá el usuario inicial desde **Authentication → Users → Add user**.
3. Desde **SQL Editor**, asignale el rol (reemplazá el correo):

```sql
insert into public.user_roles (user_id, role)
select id, 'admin'
from auth.users
where lower(email) = lower('admin@tu-dominio.com')
on conflict (user_id) do update set role = excluded.role;
```

4. Confirmá que la consulta afectó una fila. La tabla `user_roles` no admite lectura ni escritura directa desde la Data API. El administrador puede validar su acceso iniciando sesión en `/admin/login`; el cliente consulta `is_current_admin()` y cierra la sesión si no tiene el rol.

Para quitarlo, desde SQL Editor:

```sql
delete from public.user_roles
where user_id = (select id from auth.users where lower(email) = lower('admin@tu-dominio.com'));
```

## Tokens reservados

- El token tiene seis dígitos aleatorios. `private.reservation_token_fingerprints` almacena HMAC-SHA-256 con una clave aleatoria de 256 bits cifrada en Supabase Vault. Los ataques offline contra un dump no pueden validar conjeturas sin la clave.
- El HMAC y la clave Vault no están en un esquema expuesto ni tienen grants para `anon`, `authenticated` o `service_role`. La vista administrativa sólo publica metadatos y el sufijo de tres dígitos, nunca la huella.
- `create_reservation(date)` verifica el rol admin, serializa la cuota de la fecha, genera el token con muestreo sin sesgo y usa una restricción única global sobre la huella. Si hay colisión, vuelve a generar. El HMAC continúa siendo el verificador; una copia cifrada con clave aleatoria de Supabase Vault permite que `admin_reservation_tokens_for_date(date)` la recupere únicamente para administradores autenticados. El frontend la mantiene solo en memoria y no la persiste en navegador.
- Tokens históricos sin ciphertext no se reconstruyen desde el HMAC. `regenerate_reservation_token(uuid)` emite un valor nuevo para reservas vigentes, reemplaza la huella anterior dentro de la misma transacción y conserva la fecha/estado de la reserva. La interfaz requiere confirmación antes de regenerar.
- En Supabase local no hace falta una variable `VITE_*`: la migración genera una clave aleatoria de 256 bits en el servidor y la guarda mediante Supabase Vault. La clave nunca se entrega al frontend ni se escribe en la migración. Hay que conservar el volumen local de PostgreSQL/Vault y respaldarlo junto con sus secretos; perderlo impide descifrar los tokens guardados.
- La reserva se confirma en PostgreSQL al completar la transacción, también en modo hardware, porque las terminales validan el token contra esa misma base central. El ingreso físico sigue sujeto a heartbeat reciente de `esp8266-main`, capacidad disponible y confirmación del ciclo de sensores del firmware; crear una reserva no encola ni ejecuta un movimiento.
- La terminal presenta el token a `start_terminal_operation`; la función valida la huella dentro del servidor. Respuestas de token no válido, vencido, no disponible o limitado son indistinguibles para la interfaz.

## Terminales y límite de intentos

El administrador genera en **Panel → Componentes → Vincular terminal** una credencial aleatoria de 256 bits para `terminal-entry` o `terminal-exit`. Se devuelve una sola vez. Copiala y pegala en la terminal correspondiente; el navegador la conserva en IndexedDB cifrada con AES-GCM mediante una clave WebCrypto no exportable, independiente por origen de navegador. Si existe una credencial de una versión anterior en `sessionStorage`, se cifra en IndexedDB y se elimina del almacenamiento de sesión durante la primera carga nueva. Al iniciar se valida de nuevo contra Supabase. `terminal_credential_status` diferencia validez, credencial inválida/revocada y bloqueo temporal; las revocadas se borran del navegador y los bloqueos no destruyen la credencial. La base guarda SHA-256, se puede revocar aprovisionando otra y no se comparte una cuenta Auth entre terminales. El secreto descifrado existe en memoria mientras la aplicación lo usa; XSS en el mismo origen podría solicitar su uso, por lo que esta protección no reemplaza controles contra XSS.

En el mismo panel se puede generar una credencial independiente para `esp8266-main`. El firmware futuro usará esa identidad para heartbeat, reclamar comandos con vencimiento y reportar sensores. La credencial de dispositivo no se pega en las terminales; cada credencial es independiente. Para la simulación se usa la identidad `simulated-esp8266`, que no recibe secretos ni heartbeats físicos. `provision_device` sólo aprovisiona `esp8266-main`.

Las terminales sólo pueden llamar RPC con su identificador, credencial y carril. Las consultas de token y el inicio de operación tienen un límite de cinco intentos por minuto por terminal, aplicado en tablas privadas con bloqueo por fila. La migración no expone esas tablas ni los datos de operaciones/reservas a `anon`. El agregado de ocupación de `parking_state` sí tiene lectura pública y no incluye secretos ni reservas.

`vehicle_operations.source` indica quién controla la secuencia (`simulation` o `device`); `request_origin` distingue si la inició una terminal o el administrador. `start_terminal_operation` lee el modo explícito: en simulación requiere `simulation_mode=true` y `simulated-esp8266.connected=true`, registra `source='simulation'` y no emite `hardware_commands`. En modo hardware requiere un heartbeat reciente de `esp8266-main`, registra `source='device'` y encola la apertura. No cruza credenciales, estado conectado ni heartbeat entre los dos controladores.

Las terminales sólo solicitan y consultan sus operaciones. Nunca pueden ejecutar `simulate_sensor` ni confirmar con `complete_operation`. En simulación, un administrador autenticado controla `simulate_sensor` y `finish_simulated_operation`; el panel puede hacer la secuencia automáticamente o paso a paso. Para hardware, el dispositivo usa `report_device_sensor` y `finish_device_operation` con su propia credencial. El servidor exige detección, liberación con `p_clear_ms >= 500` y que hayan transcurrido realmente al menos 500 ms antes de actualizar contador, reserva e historial en una sola transacción. Las llamadas de finalización repetidas son idempotentes.

El panel refleja por separado modo, conexión simulada e identidad física. El historial/auditoría marca `source` y registra `controller` (`simulated-esp8266` o `esp8266-main`) junto con `request_origin`. El modo no se puede cambiar mientras haya una operación pendiente. Para conducir automáticamente operaciones iniciadas en `/entrada` o `/salida`, mantené abierta una sesión de administrador en `/admin`; la sincronización llega por Supabase Realtime. En modo manual, la sesión de administrador pulsa detección y liberación en Componentes.

## Reservas que cruzan medianoche

La fecha se calcula en `America/Argentina/Cordoba`. Una reserva con `vehicle_present=true` conserva la ocupación aunque venza. Su token no permite ingresar otra vez; el carril de salida admite validar esa reserva por vehículo presente y, al confirmar la salida, la marca `finished` en la misma transacción. Una reserva vencida no se conserva aunque la interfaz haya seleccionado “Conservar”.

La cuota administrativa considera sólo reservas activas de la fecha: al finalizar, revocar o vencer una reserva sin vehículo, se libera el cupo para emitir otra. Las huellas únicas abarcan fechas distintas y la generación serializa la cuota por fecha.

## GRANT, RLS y funciones

- `authenticated` obtiene lecturas administrativas explícitas filtradas por RLS y escritura sólo a través de RPC. `anon` sólo lee el agregado seguro y ejecuta las RPC de terminal, que exigen credencial aleatoria.
- La migración deja `auto_expose_new_tables = false` en `supabase/config.toml`, revoca permisos de terminales/huellas e incluye `GRANT` explícitos para cada objeto requerido.
- Las funciones `SECURITY DEFINER` usan `search_path = ''`, nombres calificados, revocan `EXECUTE` de `PUBLIC` y de roles de API que no lo necesitan. Cada RPC pública vuelve a comprobar rol admin o credencial de terminal.
- Las escrituras de contador, reserva, operación y auditoría se realizan dentro de la misma transacción. Las claves de idempotencia y el bloqueo de `parking_state` serializan las operaciones vehiculares.

## Aplicación y verificaciones

Revisá primero `supabase db push --remote --dry-run`. Aplicá la migración manualmente desde el mecanismo elegido sólo cuando el diff y las instrucciones estén revisados. Esta etapa no ejecutó `db push` ni hizo cambios en el proyecto remoto.

Para validar SQL con Supabase local se requiere Docker disponible:

```bash
supabase start
supabase migration up --local
supabase test db
supabase db lint --local
npm run lint
npm test
npm run build
```

La ausencia del entorno local no equivale a que la migración esté validada; registrá la salida antes de aplicarla en remoto.
