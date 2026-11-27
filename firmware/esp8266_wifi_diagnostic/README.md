# Aislamiento WiFi por etapas — NodeMCU ESP8266

Este sketch no usa TLS, Supabase, tokens de terminal ni RPC y no envía heartbeats. No cambia el firmware principal. No escribe en Config.h. Solo consume WIFI_SSID y WIFI_PASSWORD del archivo existente mediante una ruta de inclusión del compilador. No imprime SSID, contraseñas ni secretos. Al cargarlo se reemplaza el programa de la placa; luego hay que volver a cargar el principal.

## Compilación y carga

Desde ~/Developer/TFC-Estacionamiento, con core ESP8266 3.1.2:

```sh
"/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli" compile --jobs 1 --fqbn esp8266:esp8266:nodemcu --output-dir /tmp/tfc-wifi-diagnostic --build-property "compiler.cpp.extra_flags=-I$PWD/firmware/esp8266" firmware/esp8266_wifi_diagnostic
```

Se usa el mismo FQBN de las compilaciones anteriores del principal para mantener constante la comparación. Usar las mismas opciones de placa, frecuencia y flash que el sketch básico funcional en todas las pruebas. Si ese sketch se cargó con otro FQBN, usar ese en ambos firmwares al comparar. No cambiar parámetros de placa entre etapas.

Para cargar por CLI, identificar el puerto con `arduino-cli board list` y ejecutar `arduino-cli upload --fqbn esp8266:esp8266:nodemcu --port PUERTO --input-dir /tmp/tfc-wifi-diagnostic firmware/esp8266_wifi_diagnostic` después de compilar con el comando anterior. Abrir Monitor Serie a 115200, nueva línea. No cargar mientras exista una operación vehicular pendiente; este sketch no confirma ni cancela operaciones. Los binarios incluyen las credenciales utilizadas: no publicarlos.

## Comparación reproducible

Mantener hotspot, distancia, USB, alimentación, cableado y core constantes. Reiniciar o desconectar/reconectar la placa entre pruebas. Si el PCA sigue alimentado al reiniciar la NodeMCU, puede conservar sus salidas anteriores: cortar también su alimentación entre etapas para comenzar con condiciones comparables. El sketch no mueve servos: B/C deshabilitan sus pulsos.

1. **A**: reiniciar, enviar `A`. Solo ejecuta WiFi.mode(WIFI_STA) y WiFi.begin con las credenciales existentes, eventos y registro cada 5 s. No inicializa Wire, GPIO de periféricos ni interrupciones. Esperar unos 30 s y guardar el registro; si conecta, observar estabilidad durante un minuto. Luego enviar `wifi scan` una sola vez y observar la restauración de IP.
2. **B**: reiniciar, enviar `B`. Agrega antes de WiFi la inicialización real del PCA9685: D2/SDA, D1/SCL, 100 kHz, dirección 0x40, 50 Hz, todos los canales apagados. Mantener la misma secuencia de observación y escaneo.
3. **C**: reiniciar, enviar `C`. Agrega GPIO D5/D6 INPUT_PULLUP, interrupciones FALLING, D7 apagado y LED integrado apagado; luego inicializa PCA y semáforo/RGB rojos. El loop lee A0 y los sensores y cambia blancos solo al cruzar la histéresis 100/150, como el principal. No genera pulsos de servo ni eventos vehiculares.
4. Si C falla y B funciona, repetir C después de reiniciar con `irq off` y luego `C`. Repetir otra vez con `tasks off` y luego `C` (IRQ queda ON por defecto). Solo si hace falta, repetir con ambas opciones OFF. Esto separa interrupciones, lectura repetida de A0/I²C y mera configuración/alimentación de GPIO.
5. Para evaluar sleep, repetir la primera etapa que falle desde un reinicio, enviar `sleep off` y luego su letra. Comparar contra otro reinicio con `sleep default` y la misma etapa. No cambiar ninguna otra opción.
6. Volver a cargar exactamente el sketch básico conocido y repetir A con el diagnóstico en las mismas condiciones si A también falla. El básico no está disponible en el repositorio: la comparación inicial se basa en las dos llamadas WiFi informadas por el usuario.

Opciones solo antes de elegir etapa. No se cambia de etapa en caliente: reiniciar para eliminar estados residuales. Comandos posteriores: `status`, `wifi scan`, `help`.

El escaneo pausa autoReconnect, desconecta la asociación sin borrar credenciales, verifica STA y usa el callback SDK directamente. Conserva el STATUS: solo OK sin asociación concurrente cuenta como éxito. Informa número total de redes y datos de las coincidencias exactas del SSID configurado (RSSI, canal y seguridad). No publica las redes vecinas. Distingue inicio rechazado, fallo, interrupción y timeout (30 s); restaura WiFi.begin y la política anterior. No hay escaneo automático ni temporizador manual de reconexión. Una desconexión etiquetada como escaneo controlado es esperada.

## Interpretación

| Resultado | Qué permite concluir |
|---|---|
| A conecta y B falla repetidamente | El cambio relevante está en inicialización I²C/PCA o su estado/carga; todavía no determina si es software o eléctrico. |
| B conecta y C falla | Aislar GPIO/IRQ/tareas con las variantes de C. |
| C funciona con irq off | Investigar ruido/frecuencia de flancos. IRQ muestra contadores acumulados; comparar su crecimiento cada 5 s. |
| C funciona con tasks off | Investigar actividad del loop, A0 y escrituras I²C de luces. |
| Solo funciona con sleep off | Evidencia de una interacción con ahorro de energía bajo esas condiciones; repetir antes de cambiar el principal. |
| A/B/C funcionan, principal falla | La causa queda fuera del subconjunto reproducido: instrumentar después gestión de reconexión, inicialización de memoria/certificado y demás tareas del principal. |
| A falla y el básico vuelve a funcionar | Comparar core/FQBN/flash y código exacto del básico. No atribuir el fallo al PCA ni a credenciales. |
| Escaneo OK con cero redes también en A | Se reproduce con periféricos no inicializados; no prueba por sí solo la causa RF, eléctrica o de configuración de placa. |

El registro incluye etapa, modo radio, SDK, WiFi, motivo, heap, sleep, PHY, IP, RSSI, vueltas del loop y flancos IRQ. SDK=3/reason=201 indican que la estación no encontró el AP en ese intento; no explican por qué. sleep=2 corresponde a WIFI_MODEM_SLEEP en el core instalado; no significa radio permanentemente apagada. El arranque del principal inicializa GPIO/IRQ, certificado y PCA antes de WiFi; aquí se introducen periféricos por etapas, sin carga de certificado.

Las llamadas HTTPS/RPC del principal solo se ejecutan tras conexión y hora válida, por lo que no son llamadas activas durante su fallo inicial de asociación. La inicialización del certificado y el uso de memoria antes de WiFi sí quedan fuera de A/B/C. No se modifica el principal ni se concluye causa definitiva hasta obtener los registros físicos.
