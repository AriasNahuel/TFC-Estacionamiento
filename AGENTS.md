# Reglas del proyecto

- La especificación académica en español es la fuente de verdad. No cambies reglas funcionales confirmadas sin consultar.
- El microcontrolador objetivo es ESP8266. No desarrollar el firmware definitivo ni asignar pines antes de confirmar componentes y cableado.
- Mantener React + TypeScript estrictos, componentes pequeños y lógica de negocio fuera de las vistas.
- Las operaciones vehiculares se confirman únicamente al completar la secuencia de detección y liberación estable del sensor. La capacidad pendiente debe quedar reservada.
- Nunca confiar en validaciones del navegador para capacidad, tokens ni permisos. La implementación conectada debe usar RPC transaccionales y RLS en Supabase.
- No usar localStorage como fuente de verdad del estacionamiento ni publicar secretos. Tokens completos solo son visibles en la acción administrativa de creación/copia autorizada.
- Diferenciar eventos simulados de los reales. No permitir que una operación de simulación accione hardware real.
- Las migraciones ya aplicadas son inmutables: cualquier cambio posterior debe ser incremental y versionado.
- No ejecutar `supabase db push` remoto ni desplegar en Vercel salvo autorización explícita. Las credenciales `VITE_*` son públicas; nunca exponer `service_role`.
- El estado conectado usa Supabase como fuente de verdad; si no hay conexión, no degradar silenciosamente las operaciones a la store local.
- Las operaciones de terminal requieren credencial aleatoria aprovisionada y validación por RPC; no aceptar tokens de reserva desde consultas de lectura.
- Todo el producto se presenta en español (Argentina). Documentar decisiones y limitaciones junto con cada fase.
- Antes de finalizar cambios relevantes, ejecutar las verificaciones declaradas disponibles y reportar exactamente sus resultados.
