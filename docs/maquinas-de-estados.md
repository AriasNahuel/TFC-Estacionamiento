# Máquinas de estados

```mermaid
stateDiagram-v2
  [*] --> CLOSED
  CLOSED --> OPENING: autorización
  OPENING --> WAITING_FOR_VEHICLE: actuador confirma abierta
  WAITING_FOR_VEHICLE --> VEHICLE_DETECTED: sensor detecta
  VEHICLE_DETECTED --> VEHICLE_DETECTED: sigue detectando
  VEHICLE_DETECTED --> PASSAGE_CONFIRMED: libre estable 500 ms
  PASSAGE_CONFIRMED --> CLOSING: aplicar movimiento una vez
  CLOSING --> CLOSED: actuador confirma cerrada
  WAITING_FOR_VEHICLE --> WAITING_FOR_VEHICLE: sin detección (permanece abierta)
  OPENING --> ERROR: error dispositivo
  WAITING_FOR_VEHICLE --> ERROR: resolución administrativa
```

La entrada y salida poseen estados independientes. Apertura manual no contabiliza. Cierre manual requiere sensor libre y ausencia de operación de paso insegura. El simulador debe ejercitar la misma secuencia y evitar confirmaciones duplicadas.
