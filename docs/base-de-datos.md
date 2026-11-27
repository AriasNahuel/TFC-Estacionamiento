# Base de datos

El esquema versionado está en `supabase/migrations/`. La migración inicial crea configuración/ocupación, reservas, operaciones, eventos auditables, estado de dispositivos y comandos.

Las reservas no guardan la huella junto con los datos expuestos en `public`: `private.reservation_token_fingerprints` guarda HMAC-SHA-256 usando una clave aleatoria cifrada en Supabase Vault. La tabla no tiene grants para roles de API y su esquema no está expuesto por PostgREST. El HMAC sigue siendo la única huella usada para validar. `private.reservation_token_ciphertexts` guarda una copia cifrada con una clave aleatoria administrada por Vault; la clave no está en el frontend ni en migraciones. Sólo las RPC de administrador pueden descifrar tokens. Los registros previos sin ciphertext requieren regeneración administrativa, que invalida el HMAC anterior. La migración local crea la clave en Vault sin configuración `VITE_*`; preservar el volumen PostgreSQL/Vault es necesario para seguir descifrando los ciphertexts.

`public.user_roles` define quién es administrador. `private.is_admin()` comprueba el rol del `auth.uid()`; RLS usa esta función. La asignación inicial sólo se realiza desde SQL Editor. Ver [supabase-seguridad.md](supabase-seguridad.md).

`reservation_admin_view` calcula vencimientos con `America/Argentina/Cordoba`. Un vehículo que sigue presente conserva la ocupación al pasar medianoche y aparece como `expired_occupied`; el futuro flujo de egreso debe aceptar el token vencido sólo para esa salida y terminar la reserva en la transacción de confirmación.

Las restricciones/grants se declaran explícitamente para proyectos con concesión automática de tablas deshabilitada. Las funciones `SECURITY DEFINER` usan `search_path = ''`, revocan ejecución de `PUBLIC` y conceden sólo lo necesario. Las funciones futuras deben seguir el mismo patrón.

La migración incremental `202611210001_connected_simulation.sql` agrega estado compartido versionado, Realtime, metadatos de terminal y hashes de credenciales privados, RPC de aprovisionamiento, operaciones simuladas/terminales, límites de intentos, confirmación con 500 ms de sensor libre, auditoría, configuración y reset.

El RPC confirma la reserva en la transacción de PostgreSQL, tanto en simulación como en modo hardware: ambas terminales consultan la misma base central. El ingreso en modo físico exige heartbeat reciente de `esp8266-main` antes de crear la operación; no se confirma ocupación hasta que el firmware reporte la secuencia de sensor estable. La cola offline del ESP y su reconciliación siguen fuera de alcance. No se debe confundir `device_state` simulado con el dispositivo físico. Los clientes no pueden escribir directamente en las tablas.

`VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` son públicas por diseño. Nunca incluir `service_role` en Vite.
