# Decisiones técnicas

1. Una sola SPA con rutas separadas permite compartir componentes, dominio y canales Realtime sin duplicar reglas.
2. Supabase Postgres + RPC es el punto de serialización para evitar sobreocupación en operaciones simultáneas.
3. El frontend nunca es autoridad final para tokens o permisos. Terminales y ESP8266 tienen credenciales aleatorias independientes; únicamente la placa informa sensores.
4. La simulación sin Supabase es local y efímera; no se presenta como compartida entre computadoras.
5. Las RPC y órdenes necesarias para el canal ESP están preparadas, pero no se implementa firmware ni se fija pinout antes de confirmar componentes/cableado.
6. Tailwind y Lucide se usan sólo para presentación; el dominio permanece independiente.
7. La telemetría de sensores se agrega al JSON de `device_state` existente y reutiliza su heartbeat; las actualizaciones se emiten al arranque, ante cambios y cada 10 segundos. Realtime distribuye esa fila al dashboard. El estado se considera sin comunicación tras 30 segundos.
8. El mantenimiento físico reutiliza `hardware_commands` con `operation_id = NULL` y ACK del dispositivo. Una orden manual no crea operaciones vehiculares ni afecta contadores. Supabase exige administrador, conexión y ausencia de operación activa; la placa vuelve a comprobar localmente los sensores antes de cerrar.
9. Las órdenes manuales requieren telemetría fresca de ambos sensores. Si no llega durante 30 segundos, el dashboard muestra “Sin comunicación” y Supabase rechaza comandos. Un interlock transaccional impide solapar órdenes manuales y operaciones físicas.
