# Plan de trabajo

## Estado inicial — 20/11/2026

La carpeta del proyecto estaba vacía. No se encontraron archivos de aplicación, configuraciones ni historial local que conservar.

## Fases

| Fase | Alcance | Estado |
|---|---|---|
| A | Inicialización, dependencias, estructura, diseño base y navegación | Completada |
| B | Terminales, teclado, login y dashboard | Prototipo local; login ahora exige rol admin en Supabase |
| C | Supabase, esquema, Auth, RLS, RPC transaccionales, reservas y movimientos | Migración incremental y adaptador conectados localmente; falta aplicar migración y verificar con Supabase |
| D | Máquinas de estados y adaptadores de simulación/ESP8266 | Simulación local automática/manual básica implementada; adaptador físico pendiente |
| E | Historial, administración, recuperación y pruebas de aceptación | RPC de auditoría, reset, revocación y simulador central; faltan pruebas SQL/e2e |
| F | Revisión, documentación, Vercel e integración futura | Configuración inicial; verificación con servicios y preparación física pendiente |

## Decisiones de implementación

- Una SPA React con React Router y tres áreas independientes.
- TypeScript estricto y Vite.
- El adaptador de hardware y el servicio de persistencia se mantienen independientes.
- Supabase es la fuente compartida cuando está configurado y la migración incremental se aplicó. La simulación local sin credenciales no se presenta como sincronización remota.
- Las terminales conectadas reciben credenciales aleatorias y validan reservas por RPC. No se habilita como control físico hasta que el firmware pueda reportar sensores y estado de barrera.
- La zona horaria funcional es `America/Argentina/Cordoba`; no se incluyen datos personales en las reservas.

## Dependencias externas pendientes

- Proyecto Supabase (URL y clave pública anon/publishable); creación del primer administrador por Supabase Auth.
- Dominio/proyecto Vercel para despliegue (no se crea ni publica automáticamente).
- ESP8266, credenciales de dispositivo y confirmación del cableado para integración física futura.

## Avance previo

- Creada SPA responsive con rutas requeridas, pantalla de selección, terminales, login, dashboard, reservas locales, historial y controles básicos de simulación.
- Creado esquema Supabase inicial con RLS, eventos, operaciones, comandos y RPC autenticada para generar hasta tres tokens por fecha.
- Simulación local conserva ocupación hasta detección y sensor libre estable por 500 ms; el usuario puede operar sensores manualmente.
- Ejecutados lint, Vitest y build con resultado satisfactorio en la última pasada.
- Ese estado fue reemplazado por la integración incremental documentada abajo; las pruebas conectadas aún están pendientes.

## Revisión de seguridad de la migración — 20/11/2026

- Antes de aplicarse, se reemplazó la lectura genérica `authenticated` por autorización basada en `public.user_roles` y `private.is_admin()`.
- Se movió la huella del token a un esquema no expuesto y se cambió SHA-256 simple por HMAC-SHA-256 con clave aleatoria gestionada en Supabase Vault.
- Se agregaron reintentos acotados ante colisiones concurrentes entre fechas y unicidad global de huellas.
- Se añadió `expired_occupied` como estado derivado en una vista según la fecha Cordoba y la ocupación persistente, sin liberar ni invalidar una salida vencida.
- Se especificaron grants/ejecuciones explícitas y una prueba pgTAP de permisos. No se ejecutó `db push`; las pruebas SQL locales no pudieron conectar porque Docker no está iniciado.

## Integración central y terminales — 21/11/2026

- Nueva migración `202611210001_connected_simulation.sql`, sin modificar la inicial: contadores/versiones, simulador compartido, RPC de movimiento idempotentes, sensor estable, auditoría, revocación, reset, terminales y publicación Realtime.
- La SPA usa Supabase para leer el agregado, reservas administrativas e historial; las operaciones del panel pasan por RPC. Los tests fuerzan el modo local para no contactar Supabase.
- Las terminales guardan su credencial aleatoria en `sessionStorage`, validan tokens por RPC y consultan sólo el estado de su operación. Los intentos se limitan por terminal. No muestran la huella.
- Sin firmware, una operación terminal queda pendiente y la interfaz avisa que la barrera no se abrirá hasta recibir la confirmación ESP8266. Las reservas se marcan confirmadas sólo en el simulador central; no existe todavía confirmación física de sincronización.
- `npm run lint`, `npm test` y `npm run build` pasan. `supabase db lint --local` y `supabase test db` no conectan: no hay servidor local en `127.0.0.1:54322` (requiere Docker). No se ejecutó comando remoto ni se desplegó.
