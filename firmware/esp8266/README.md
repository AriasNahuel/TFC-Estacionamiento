# Firmware NodeMCU ESP8266 — TFC Estacionamiento

Sketch para NodeMCU Amica que conserva WiFi, hora NTP, TLS verificado y la comunicación existente con Supabase. En operación normal usa `esp8266-main`, recibe `open_gate`, acciona el servo correspondiente con PCA9685, reporta sensores y solicita la finalización. Supabase sigue siendo la única fuente de verdad de los contadores.

## Dependencias y configuración

- Arduino IDE 2.x.
- Core **ESP8266 by ESP8266 Community**, versión 3.1.2 o compatible; placa **NodeMCU 1.0 (ESP-12E Module)**.
- Biblioteca **ArduinoJson 7.x**.
- `Wire`, WiFi, HTTPClient y BearSSL se incluyen con el core. El acceso al PCA9685 usa registros I²C directamente, sin biblioteca adicional.
- Mantener los archivos locales actuales `Config.h` y `TrustAnchor.h`; no compartirlos ni reemplazarlos. `Config.h` debe definir `WIFI_SSID`, `WIFI_PASSWORD`, `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` y `ESP_DEVICE_SECRET`. El trust anchor DER debe definir `SUPABASE_ROOT_CA_DER`.
- La Publishable key se envía solo como `apikey`; no se manda como bearer JWT. El secreto de dispositivo viaja solo en el JSON de las RPC autenticadas. El firmware nunca usa `service_role`.

La validación de servidor requiere reloj NTP válido. Si TLS falla, revisar hora y certificado de confianza; el sketch no desactiva validación TLS.

WiFi: el arranque usa `WiFi.begin` y deja terminar la asociación y DHCP. La reconexión automática del SDK permanece habilitada; el respaldo manual espera 30 s desde el inicio o la última desconexión y solo actúa en estados de fallo/inactividad, nunca mientras hay asociación en curso. Monitor Serie informa estado SDK, motivo numérico de desconexión, asociación, IP y RSSI sin credenciales. Para verificarlo, iniciar primero sin alimentación externa de servos, ejecutar `diag on`, `status`, `sensors on` y `led test entry`; apagar y volver a encender el hotspot y comprobar recuperación de IP. Luego repetir con alimentación externa conectada y comparar motivos y reinicios. La influencia de esa alimentación requiere prueba física.

## Cableado reconocido por el sketch

| Componente | Conexión |
|---|---|
| PCA9685 SCL/SDA | D1 / D2, dirección I²C `0x40` |
| Servo de entrada / salida | PCA9685 canales 0 / 1 |
| Semáforo rojo / verde | canales 2 / 3, cátodo común |
| 7 luces blancas | canales 4 a 10 |
| RGB rojo / verde común ánodo | canales 11 / 12, activo LOW |
| Sensor IR entrada / salida | D5 / D6, activo LOW; INPUT_PULLUP |
| Buzzer | D7, activación HIGH asumida |
| KY-018 | A0, conservar el divisor ya verificado (9,7 kΩ, 100 kΩ y 33 kΩ) |

Servos: fuente externa de 5 V con masa común a la NodeMCU/PCA9685. No alimentar los servos desde el pin 3V3 de la placa. Confirmar niveles, resistencias y alimentación del PCA9685 antes de conectar.

Los pulsos de servo se configuran en `esp8266.ino`: `ENTRY_CLOSED_US`, `ENTRY_OPEN_US`, `EXIT_CLOSED_US` y `EXIT_OPEN_US` (inicialmente 1000/2000 µs). Son valores de partida, no ángulos comprobados. Ajustarlos primero con el servo desacoplado de la barrera, en pasos pequeños y observando límites mecánicos.

El inicio configura las salidas PCA a apagado y deja los canales servo sin pulsos; no mueve la barrera. El semáforo queda rojo, RGB rojo, luces blancas apagadas y buzzer apagado.

## Compilar y cargar

1. Abrir `esp8266.ino` con Arduino IDE y dejar junto a él los `Config.h` y `TrustAnchor.h` locales.
2. Elegir **NodeMCU 1.0 (ESP-12E Module)**, puerto USB y velocidad serie 115200.
3. Verificar/compilar y cargar. Abrir Monitor Serie a **115200 baudios** y enviar comandos terminados en nueva línea.
4. `status` muestra conectividad, estado PCA, sensores y LDR, sin mostrar claves.

## Diagnóstico aislado por Monitor Serie

Primero, desde `/admin`, poner el sistema en modo simulación y dejar sin operaciones pendientes. Luego enviar `diag on`. Ese modo local pausa `claim_device_commands`; no crea operaciones vehiculares, no llama RPC de sensores ni finaliza operaciones. Heartbeats del controlador físico continúan para observar conectividad. Al terminar, enviar `diag off` para volver a sondear Supabase. No dejar activa una operación física al cambiar modos.

| Comando | Acción |
|---|---|
| `help` | Lista de comandos |
| `status` | WiFi, NTP, PCA9685, modo, sensores y lectura A0 |
| `wifi scan` | Escaneo puntual 2,4 GHz, disponible en ambos modos. Busca el SSID configurado y muestra RSSI, canal, seguridad y último motivo de desconexión, sin imprimir credenciales. |
| `diag on` / `diag off` | Activar / terminar diagnóstico local |
| `servo entry open` / `servo entry close` | Mover solo servo de entrada |
| `servo exit open` / `servo exit close` | Mover solo servo de salida |
| `sensor entry` / `sensor exit` | Leer un sensor; LOW significa obstáculo |
| `sensors on` / `sensors off` | Mostrar sensores periódicamente |
| `traffic red` / `traffic green` | Probar semáforo |
| `white on` / `white off` | Probar los siete blancos |
| `rgb red` / `rgb green` | Probar las ramas roja/verde de los tres RGB |
| `ldr` | Leer A0 y mostrar umbrales |
| `buzzer` o `buzzer 500` | Sonar por 120 ms o por el tiempo indicado (20–2000 ms) |
| `led test entry` / `led test exit` | Prueba no bloqueante del LED integrado (2 / 3 destellos); nunca informa apertura |

Prueba componente por componente: activar diagnóstico; comprobar I²C con `status`; probar `sensor entry` y `sensor exit` tapando cada sensor; probar luces, RGB, semáforo, LDR y buzzer; con la barrera desacoplada probar y calibrar servos; probar LED integrado; apagar diagnóstico. Ante error PCA, no se acciona ninguna operación Supabase como si la apertura hubiera sido exitosa.

## Operación con Supabase

Para diagnosticar el hotspot, enviar `diag on` y luego `wifi scan` a 115200 baudios, sin operaciones pendientes. No solicitar movimientos desde las terminales hasta que termine. El comando también está disponible fuera de diagnóstico, con las mismas condiciones de inactividad. Se comprueba modo STA y se suspende temporalmente la reconexión automática y manual; se desconecta la asociación usando el SDK, sin borrar credenciales. Se ejecuta un único escaneo asíncrono del SDK y se conserva su STATUS real: el wrapper del core 3.1.2 convierte errores en cero redes, por lo que ya no se usa para este diagnóstico. Solo STATUS=OK sin interrupción permite informar cero redes. Fallo de inicio, fallo de callback, asociación concurrente y timeout se informan por separado. Se registran modo radio, estados WiFi/SDK, heap, PHY, sleep, último motivo y contexto normal/escaneo. SDK=0 significa estación inactiva, no radio apagada: para eso observar modo=1 (STA). Al finalizar o fallar se restaura la reconexión previa y se ejecuta `WiFi.mode(WIFI_STA)` → `WiFi.begin` con las credenciales existentes. Un timeout de escaneo es 30 s; no cambia los intervalos de conexión. Si falta el callback, no se permite otro escaneo hasta recibirlo. Confirmar después asociación, IP, NTP y heartbeat. Compartir las líneas `[wifi scan]` y `[WiFi]`; no contienen SSID ni contraseñas. Estos cambios corrigen el diagnóstico y la restauración: todavía requieren prueba en la placa para establecer la causa del fallo inicial del hotspot.

1. Salir de diagnóstico (`diag off`), habilitar modo hardware en `/admin` y verificar heartbeat de `esp8266-main` reciente.
2. Mantener la placa conectada y sincronizada por NTP. `heartbeat_device` se llama cada 10 s y `claim_device_commands` cada 1 s cuando no hay movimiento en curso.
3. `/entrada` o `/salida` crea la operación con `start_terminal_operation`. La placa reclama el comando, comprueba expiración, envía ACK `running` antes de mover el servo, acciona solo el canal solicitado y envía `confirmed` solamente si termina la escritura I²C.
4. El firmware informa LOW mediante `report_device_sensor(p_device_id,p_device_secret,p_operation_id,p_detected,p_clear_ms)`. Informa HIGH estable durante 500 ms con `p_detected=false,p_clear_ms=500`; espera 5 s antes del cierre, interrumpiendo/reabriendo si reaparece un obstáculo; después llama `finish_device_operation(p_device_id,p_device_secret,p_operation_id)`. Las RPC mantienen el conteo y las validaciones. No se envían parámetros adicionales.
5. Una desconexión de WiFi no confirma movimientos. La placa retiene la operación y la barrera; revisar el estado y cancelar desde administración si la orden venció o requiere recuperación. No reiniciar con una barrera/operación en una situación física incierta.

El semáforo consulta `parking_state` cada 5 s mientras no hay operación. Verde indica que `regular_count + reserved_contingency_count < regular_capacity`; rojo, capacidad usada. Si la lectura falla, conserva el último estado. El KY-018 medido entrega valores más altos al oscurecer: el LDR se lee cada 200 ms, enciende las luces blancas desde 160 y las apaga al bajar a 110. El RGB queda apagado de día y rojo de noche; durante toda operación es rojo, salvo ingreso reservado autorizado por Supabase, que mantiene verde hasta finalizar. El modo nocturno del dashboard corresponde al simulador; en hardware las luces blancas obedecen únicamente al LDR. `ldr` muestra la lectura y los umbrales configurados. No se modifica la red de resistencias.

## Limitaciones SQL identificadas (no aplicar desde este sketch)

Las funciones existentes fueron revisadas en las migraciones locales. `start_terminal_operation` inserta `open_gate` con vencimiento de **15 segundos** y payload que solo contiene `direction`. La consulta de la placa ahora es cada 1 s y se salta el sondeo del semáforo si hay órdenes, pero las llamadas HTTPS son síncronas: un retraso de red aún puede agotar el TTL antes del ACK. Antes de la prueba física integrada se recomienda una migración incremental que aumente la vigencia a 45–60 s y revise que `ack_device_command` acepte la etapa confirmada bajo el mismo vencimiento.

No se presupone que las migraciones locales recientes estén en remoto. Antes de ensayar una orden que pueda quedar abierta, confirmar que esté desplegada la migración `202611240001_cancel_running_device_commands.sql` para recuperación administrativa y `202611240003_fail_expired_gate_operation.sql` para registrar expiraciones; `202611240002_terminal_operation_progress.sql` corresponde al progreso que ve la terminal. No se aplicó ninguna migración desde esta tarea.

La migración incremental `202611260008_authorized_vehicle_type_command.sql` agrega `vehicle_type` al payload del comando físico después de que `start_terminal_operation` valida y autoriza la operación. No cambia las reglas ni los argumentos de la RPC. El sketch solo usa verde si recibe explícitamente `reserved` en esa orden emitida por el backend.

También debe verificarse en el SQL remoto que la política SELECT segura de `parking_state` y el `GRANT SELECT` a `anon` sigan disponibles para la lectura REST. El semáforo físico muestra ocupación confirmada y contingencia reservada; para reflejar además la capacidad pendiente retenida por operaciones aún no confirmadas, haría falta exponer desde Supabase un agregado seguro de lugares disponibles. El estado de disponibilidad siempre lo decide Supabase, nunca el firmware.

No se probó físicamente esta placa ni sus periféricos en esta implementación. La compilación confirma el firmware, no el funcionamiento del cableado.
