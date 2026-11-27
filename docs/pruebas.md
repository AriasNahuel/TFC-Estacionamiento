# Plan de pruebas y verificación

Los casos de aceptación completos se detallan en la especificación original, sección 25. Vitest cubre reglas locales: capacidad, estados de reserva, idempotencia de aplicación y liberación estable del sensor. Los contratos SQL y permisos están en `supabase/tests/security.sql`; deben ejecutarse contra Supabase local después de aplicar todas las migraciones. La ausencia de Docker se reporta como validación pendiente, no como aprobación SQL.

Verificación local del cliente: `npm run lint`, `npm run test`, `npm run build`. El modo de test desactiva deliberadamente el cliente remoto para impedir que Vitest contacte el proyecto Supabase configurado en `.env.local`.
