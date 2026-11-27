# Perfiles LOCAL y CLOUD

El sketch conserva CLOUD como perfil predeterminado: `Config.h` y `TrustAnchor.h`
no se modifican y las solicitudes HTTPS usan BearSSL con la raíz configurada.

Para compilar LOCAL, complete el archivo ignorado `Config.local.h` con SSID, contraseña
WiFi, clave publicable local y secreto aleatorio provisionado por RPC para `esp8266-main`.
No reutilice secretos de Cloud. La URL local usa la IP LAN actual de la Mac; actualícela
si el hotspot la cambia. LOCAL usa HTTP sin TLS y debe limitarse a una red privada aislada.

La validación absoluta de `expires_at` sigue siendo obligatoria y fail-closed. Ambos
perfiles requieren que NTP establezca hora válida antes de hacer RPC. LOCAL prioriza
la fuente NTP LAN declarada; confirme que el router/hotspot realmente la ofrece o instale
una fuente NTP confiable en la LAN. Sin ella, no se reclaman ni ejecutan órdenes.

`serviceOperation()` y la lectura de LDR se atienden antes de heartbeats y consultas de
ocupación. Estas consultas solo se intentan en reposo, sin movimiento, cola ni flanco IR
pendiente. HTTP sigue siendo síncrono: las RPC críticas pueden bloquear el loop hasta el
timeout configurado, por lo que la frecuencia efectiva del LDR puede exceder 200 ms
durante una solicitud. Para garantizar muestreo estricto en todo momento haría falta
convertir el transporte a asíncrono o usar un coprocesador; este cambio mantiene la
lectura cada 200 ms cuando el loop está disponible y no altera los controles existentes.

Compilar sin cargar (Arduino IDE CLI incluido):

```sh
ARDUINO_CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
"$ARDUINO_CLI" compile --fqbn esp8266:esp8266:nodemcuv2 firmware/esp8266
"$ARDUINO_CLI" compile --fqbn esp8266:esp8266:nodemcuv2 --build-property 'compiler.cpp.extra_flags=-DTFC_PROFILE_LOCAL' firmware/esp8266
```

No usar `upload` hasta verificar la conectividad LAN, sincronización horaria, aprovisionamiento
local de terminales y autorización expresa de la prueba física.
