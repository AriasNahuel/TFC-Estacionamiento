# Desarrollo local con Supabase

## Estado verificado

- Reutiliza el stack Docker existente `estacionamiento-automatizado`; no se inició una segunda instancia ni se reseteó la base.
- Proyecto CLI: `estacionamiento-automatizado`; API REST `http://127.0.0.1:54321`, PostgreSQL `127.0.0.1:54322`, Studio `http://127.0.0.1:54323`.
- La base existente ya registra `202611250001_command_expiry_60_seconds.sql`; se copió el archivo fuente al repositorio principal sin volver a aplicarlo.
- Las migraciones `202611240001`–`202611240003` estaban pendientes y se aplicaron localmente con `--include-all`, porque `202611250001` ya constaba en el historial. No se duplicó ni reejecutó la migración 60s.
- Se creó una cuenta Auth local y se asignó `admin`; el login y `is_current_admin()` se verificaron contra el stack local. No se copiaron cuentas Cloud.
- El frontend y el firmware no fueron probados físicamente en esta etapa. No se modificó `firmware/esp8266`.
- Docker publica la API (`54321`) y PostgreSQL (`54322`) en todas las interfaces (`0.0.0.0`). Restringí el acceso en el firewall a una red privada confiable; no expongas PostgreSQL ni HTTP a una red pública.

## Variables LOCAL y CLOUD

`npm run dev:local` activa el modo `localdev`, que selecciona exclusivamente `config/env/local/.env`; no hereda el `.env.local` de la raíz. Ese archivo contiene solo la URL y la clave pública local y está ignorado por Git. El `.env.local` raíz permanece intacto y `npm run dev:cloud` lo sigue utilizando.

Si necesitás recrear el archivo local, copiá `config/env/local/.env.example` a `config/env/local/.env` y completá la clave pública con `PUBLISHABLE_KEY` que muestra `supabase status`:

```dotenv
VITE_SUPABASE_URL=http://127.0.0.1:54321
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

No uses `SECRET_KEY` ni `SERVICE_ROLE_KEY` en Vite, ni copies credenciales del firmware al frontend.

## Inicio y parada

Docker Desktop debe estar iniciado. La API local ya está en ejecución; verificá su estado sin crear otra instancia:

```bash
./node_modules/.bin/supabase status
```

Para iniciar React contra Supabase local:

```bash
npm run dev:local
```

Abrí `http://127.0.0.1:5174`; las rutas `/entrada`, `/salida` y `/admin` siguen disponibles. `dev:local` fija host y puerto y falla si 5174 está ocupado, para conservar el mismo origen y el almacén cifrado de las terminales. Para compilar explícitamente con variables locales usá `npm run build:local`. Para usar la configuración Cloud existente:

```bash
npm run dev:cloud
```

Para detener únicamente el stack existente y conservar sus datos:

```bash
./node_modules/.bin/supabase stop
```

No ejecutes `supabase db reset`. Aplicá migraciones faltantes de forma incremental y solo contra el stack local:

```bash
./node_modules/.bin/supabase migration up --local
```

## Migraciones y RPC

Después de aplicar migraciones, confirmá el estado con:

```bash
./node_modules/.bin/supabase migration list --local
./node_modules/.bin/supabase test db supabase/tests/security.sql
```

La operación física reserva capacidad mediante RPC; el comando de apertura vence a los 60 segundos. Las migraciones `202611240001`–`202611240003` cancelan comandos en curso, exponen el progreso acotado a la terminal y fallan operaciones con comandos rechazados o vencidos. Conservá RLS y las credenciales de dispositivo existentes.

## Restablecer datos de prueba locales

La migración `202611260017_local_test_data_reset.sql` agrega una RPC transaccional de administrador. Queda **deshabilitada por defecto**. Su guardia está en `private.local_test_data_reset_guard`, sin permisos para los roles de la API. La habilitación se hace manualmente solo en la base local, desde Studio local → SQL Editor, conectado a `127.0.0.1:54322`:

```sql
update private.local_test_data_reset_guard set enabled = true where id = 1;
```

Para volver a deshabilitarla:

```sql
update private.local_test_data_reset_guard set enabled = false where id = 1;
```

No ejecutes estos comandos en Supabase Cloud. El menú **Mantenimiento** aparece únicamente cuando el frontend apunta a `localhost`, `127.0.0.1` o `::1`; aun así, la RPC vuelve a validar administrador, guardia local, controlador conectado, telemetría reciente y libre, barreras cerradas y ausencia de operaciones activas. Las órdenes `received`/`running` y las `pending` aún vigentes bloquean la acción. Una orden `pending` vencida se marca fallida dentro de la transacción: el RPC de la ESP8266 solo reclama pendientes con `expires_at > now()`. En la pantalla hay que confirmar explícitamente que el predio está vacío; luego aparece una segunda confirmación irreversible. El restablecimiento no emite órdenes ni cambia firmware, credenciales, vinculaciones, configuración, capacidad o modo.

La prueba `supabase/tests/local_test_data_reset.sql` ejecuta la RPC con fixtures dentro de una transacción que termina en `ROLLBACK`. No uses la RPC para la prueba automatizada ni cambies el contenido de la base local fuera de esa transacción.

## Administrador local

1. Abrí Studio en `http://127.0.0.1:54323`.
2. En **Authentication → Users**, creá una cuenta de prueba con contraseña exclusiva de desarrollo.
3. En **SQL Editor**, asigná el rol admin (cambiá el correo):

```sql
insert into public.user_roles (user_id, role)
select id, 'admin'
from auth.users
where lower(email) = lower('admin-local@example.invalid')
on conflict (user_id) do update set role = excluded.role;
```

Confirmá que la consulta afectó una fila. No reutilices en Cloud usuarios o contraseñas locales.

## ESP8266 y rendimiento

La ESP8266 debe continuar comunicándose por WiFi. Cuando se autorice esa etapa, la API se configurará con la IP LAN del Mac (nunca `localhost` dentro de la placa), después de comprobar que la red no aísle clientes. No se modificaron `firmware/esp8266/esp8266.ino`, `Config.h` ni credenciales.

Medí por separado la orden web, ACK `running`, apertura, detección/liberación, cierre y actualización de ocupación. El stack local está listo para esas mediciones, pero todavía no se midió la latencia del ciclo físico ni se validó la reapertura ante obstáculos.
