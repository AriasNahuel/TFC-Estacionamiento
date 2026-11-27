# TFC - Estacionamiento

Sistema académico de estacionamiento automatizado para una maqueta con **ESP8266**. Esta aplicación React reúne una terminal de entrada, una terminal de salida y un panel administrativo. La fase actual incluye una demostración local del flujo de barreras y sensores; no controla una placa física.

## Tecnologías

React 19, TypeScript, Vite, Tailwind CSS 4, Lucide, React Router, Supabase JS, PostgreSQL/Supabase Auth, Vitest y Vercel.

## Requisitos previos

- Node.js 20.19+ o 22.12+ y npm.
- Para persistencia compartida/autenticación: proyecto Supabase propio.

## Instalación y ejecución

```bash
npm install
cp .env.example .env.local
npm run dev
```

Abrí `/` para elegir interfaz, o `/entrada`, `/salida` y `/admin/login`. Sin configuración externa, el cliente muestra el modo de simulación local, efímero y limitado al navegador actual. En desarrollo se puede ingresar al panel mediante el acceso local de demostración del login. No se ofrece una cuenta demo en producción.

## Supabase

1. Creá un proyecto Supabase.
2. Copiá Project URL y anon/publishable key a `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` en `.env.local`.
3. Aplicá las migraciones versionadas en `supabase/migrations/` con Supabase CLI o el editor SQL.
4. En Auth, desactivá el registro público, creá el usuario administrador inicial y asignale el rol `admin` mediante SQL Editor, siguiendo [la guía de seguridad y bootstrap](docs/supabase-seguridad.md).
5. Reiniciá Vite luego de cambiar variables.

Las claves `VITE_*` son visibles en el navegador y nunca deben incluir `service_role`. La migración inicial define autorización administrativa con roles, huellas HMAC privadas para tokens y reservas vencidas con vehículo presente. La migración incremental `202611210001_connected_simulation.sql` agrega el simulador compartido, RPC transaccionales, credenciales de terminal, límites de intentos, auditoría y Realtime. La persistencia central queda habilitada sólo después de aplicar esa migración; no se aplicó desde este entorno.

## Pruebas y verificaciones

```bash
npm run lint
npm run test
npm run build
```

## Simulación

Sin Supabase, el panel de desarrollo usa simulación local en memoria. Con Supabase configurado y las migraciones aplicadas, el panel usa RPC y estado compartido por Realtime. Los contadores cambian sólo luego de detectar el vehículo y confirmar la liberación estable durante al menos 500 ms. Las operaciones de terminal quedan pendientes hasta que el controlador reporte el ciclo del sensor; todavía no hay firmware para completar esa comunicación.

## Despliegue Vercel

Importá el repositorio, usá los valores por defecto de Vite y configurá `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` en el proyecto de Vercel. `vercel.json` reescribe las rutas SPA a `index.html`. No se publica el sitio automáticamente.

## Documentación

- [Plan persistente](docs/plan-trabajo.md)
- [Arquitectura](docs/arquitectura.md)
- [Reglas de negocio](docs/reglas-de-negocio.md)
- [Esquema de datos](docs/base-de-datos.md)
- [Máquinas de estados](docs/maquinas-de-estados.md)
- [Contrato ESP8266](docs/comunicacion-esp8266.md)
- [Plan de pruebas](docs/pruebas.md)
- [Decisiones técnicas](docs/decisiones-tecnicas.md)

## Limitaciones actuales y siguientes pasos

- La sincronización entre interfaces depende de aplicar la migración incremental y de permisos Auth/RLS correctos. No se hizo una prueba contra el proyecto remoto desde esta fase.
- El panel conectado exige Supabase Auth y el rol `admin`. El acceso de demo sólo aparece en el entorno `development` de Vite y sin variables Supabase.
- Falta probar en Supabase local/remoto las RPC, la recepción de eventos de terminal/controlador y una sincronización de extremo a extremo.
- El adaptador físico, protocolo ejecutable y firmware no están implementados. No se fijaron pines ni características eléctricas.
- Vercel/Supabase requieren cuentas y valores del usuario; no se creó cuenta, servicio pago ni despliegue.

Para ejecutar contra Supabase local sin tocar `.env.local`, seguí [la guía de desarrollo local](docs/desarrollo-local.md) y usá `npm run dev:local`.
