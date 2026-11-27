# Preparación para Vercel

En Vercel, configurá estas variables para los entornos que vayas a usar (Production, Preview y/o Development):

| Variable | Valor |
| --- | --- |
| `VITE_SUPABASE_URL` | URL pública del proyecto Supabase (`https://<project-ref>.supabase.co`) |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | Publishable key pública del proyecto (`sb_publishable_...`) |

Vite incorpora las variables `VITE_*` al bundle durante la compilación. La aplicación prefiere `VITE_SUPABASE_PUBLISHABLE_KEY` y conserva compatibilidad local con `VITE_SUPABASE_ANON_KEY` legacy.

No configures `service_role`, una Secret key ni el secreto de `esp8266-main` en Vercel. Esas credenciales no pertenecen al frontend.

`vercel.json` contiene la reescritura SPA hacia `/index.html`, necesaria para abrir directamente `/entrada`, `/salida`, `/admin/login` y `/admin`. El proyecto se construye con `npm run build`.

Antes de publicar la interfaz que muestra el progreso detallado, aplicá manualmente y en orden las migraciones incrementales `202611240001_cancel_running_device_commands.sql`, `202611240002_terminal_operation_progress.sql` y `202611240003_fail_expired_gate_operation.sql`. No se ejecutan automáticamente desde Vercel.
