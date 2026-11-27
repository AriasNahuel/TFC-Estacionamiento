#include <Arduino.h>
#include <ArduinoJson.h>
#include <ESP8266HTTPClient.h>
#include <ESP8266WiFi.h>
#include <Wire.h>
#include "SafetyLogic.h"
#if !defined(TFC_PROFILE_LOCAL)
#include <WiFiClientSecureBearSSL.h>
#endif
#include <time.h>
extern "C" {
#include <user_interface.h>
}

#if defined(TFC_PROFILE_LOCAL) && defined(TFC_PROFILE_CLOUD)
#error "Seleccione un solo perfil: LOCAL o CLOUD"
#endif

#if defined(TFC_PROFILE_LOCAL)
#include "Config.local.h"
#else
// Perfil predeterminado para conservar el comportamiento histórico CLOUD.
#include "Config.h"
#include "TrustAnchor.h"
#endif

namespace {

// Hardware confirmado para NodeMCU Amica. No cambiar sin revisar el cableado.
constexpr uint8_t PIN_I2C_SCL = D1;
constexpr uint8_t PIN_I2C_SDA = D2;
constexpr uint8_t PIN_ENTRY_IR = D5;
constexpr uint8_t PIN_EXIT_IR = D6;
constexpr uint8_t PIN_BUZZER = D7;
constexpr uint8_t PCA9685_ADDRESS = 0x40;
constexpr uint8_t PCA_SERVO_ENTRY = 0;
constexpr uint8_t PCA_SERVO_EXIT = 1;
constexpr uint8_t PCA_TRAFFIC_RED = 2;
constexpr uint8_t PCA_TRAFFIC_GREEN = 3;
constexpr uint8_t PCA_WHITE_FIRST = 4;
constexpr uint8_t PCA_WHITE_LAST = 10;
constexpr uint8_t PCA_RGB_RED = 11;
constexpr uint8_t PCA_RGB_GREEN = 12;
// Los módulos RGB conectados a estos canales son de ánodo común (entrada activa LOW).
constexpr bool PCA_RGB_ACTIVE_LOW = true;

constexpr char DEVICE_ID[] = "esp8266-main";
#if defined(TFC_PROFILE_LOCAL)
constexpr char NTP_SERVER_1[] = TFC_NTP_SERVER_1;
constexpr char NTP_SERVER_2[] = TFC_NTP_SERVER_2;
#else
constexpr char NTP_SERVER_1[] = "pool.ntp.org";
constexpr char NTP_SERVER_2[] = "time.cloudflare.com";
#endif
constexpr uint32_t HEARTBEAT_INTERVAL_MS = 10000;
constexpr uint32_t SENSOR_REPORT_RETRY_MS = 1000;
constexpr uint32_t CLAIM_INTERVAL_MS = 1000;
constexpr uint32_t PARKING_POLL_INTERVAL_MS = 5000;
constexpr uint32_t WIFI_RETRY_INTERVAL_MS = 30000;
constexpr uint32_t OPERATION_RPC_RETRY_MS = 1000;
constexpr uint32_t RECOVERY_STATUS_INTERVAL_MS = 2000;
constexpr uint32_t RECOVERY_NOTICE_INTERVAL_MS = 5000;
#if defined(TFC_PROFILE_LOCAL)
constexpr uint32_t HTTP_TIMEOUT_MS = 1200;
#else
constexpr uint32_t HTTP_TIMEOUT_MS = 1800;
#endif
constexpr uint32_t SENSOR_CLEAR_MS = 500;
constexpr uint32_t PASSAGE_COUNTDOWN_MS = 5000;
constexpr uint32_t SERVO_STEP_MS = 20;
// Courtesy period replaces the former 5 s normal wait; the separate 5 s
// PASSAGE_COUNTDOWN_MS remains reserved for Failed-state recovery.
constexpr uint32_t COURTESY_COUNTDOWN_MS = 3000;
constexpr uint32_t COURTESY_BEEP_INTERVAL_MS = 1000;
constexpr uint16_t COURTESY_BEEP_MS = 150;
constexpr uint16_t AUTOMATIC_BUZZER_FREQUENCY_HZ = 4000;
constexpr uint16_t DIAGNOSTIC_BUZZER_FREQUENCY_HZ = 2000;
constexpr uint16_t DIAGNOSTIC_BUZZER_MIN_FREQUENCY_HZ = 500;
constexpr uint16_t DIAGNOSTIC_BUZZER_MAX_FREQUENCY_HZ = 5000;
constexpr uint8_t MAX_QUEUED_COMMANDS = 6;
constexpr uint8_t LED_ACTIVE_LOW = 1;
// KY-018 medido: claridad ~15, ambiente ~96 y oscuro ~220.
// La histéresis enciende al oscurecer y apaga al aclarar.
constexpr bool LDR_DARK_WHEN_LOW = false;
constexpr int LDR_NIGHT_THRESHOLD = 110;
constexpr int LDR_DAY_THRESHOLD = 160;

// Calibrar con diag servo antes de usar el paso vehicular. Valores PCA9685 en us.
constexpr uint16_t ENTRY_CLOSED_US = 1000;
constexpr uint16_t ENTRY_OPEN_US = 2000;
constexpr uint16_t EXIT_CLOSED_US = 1000;
constexpr uint16_t EXIT_OPEN_US = 2000;

constexpr uint8_t REG_MODE1 = 0x00;
constexpr uint8_t REG_LED0_ON_L = 0x06;
constexpr uint8_t REG_PRESCALE = 0xFE;

#if !defined(TFC_PROFILE_LOCAL)
BearSSL::X509List trustAnchors;
#endif

struct RpcResponse { int status; String body; };
struct DeviceCommand {
  String id;
  String operationId;
  String commandType;
  String direction;
  String vehicleType;
  String manualAction;
  String manualTarget;
  String requestId;
  int64_t expiresAt = 0;
};

enum class OperationStage : uint8_t {
  Idle, AckRunning, Opening, AckConfirmed, WaitDetect, WaitStableClear,
  Countdown, Closing, Reopening, ReportDetect, ReportClear, Finish,
  Failed, RecoveryClosing, RecoveryOpening, ManualAckRunning, ManualMoving,
  ManualReopening, ManualAckConfirmed, ManualAckFailed
};
enum class RgbColor : uint8_t { Off, Red, Green };

struct ServoMotion {
  bool active = false;
  uint8_t channel = 0;
  uint16_t startUs = 0;
  uint16_t targetUs = 0;
  uint16_t currentUs = 0;
  uint32_t nextStepAt = 0;
};

TfcSafety::FixedQueue<DeviceCommand, MAX_QUEUED_COMMANDS> queueCommands;
DeviceCommand activeCommand;
OperationStage operationStage = OperationStage::Idle;
ServoMotion servoMotion;
uint16_t servoPositions[2] = {0, 0};

bool pcaReady = false;
bool servoFault = false;
bool diagnosticMode = false;
bool diagSensorStream = false;
bool wifiWasConnected = false;
bool wifiAssociated = false;
bool wifiScanActive = false;
int lastWifiDisconnectReason = -1;
WiFiEventHandler wifiConnectedHandler;
WiFiEventHandler wifiDisconnectedHandler;
WiFiEventHandler wifiGotIpHandler;
bool reservedIndicatorActive = false;
bool manualWhiteOverride = false;
bool manualRgbOverride = false;
RgbColor rgbColor = RgbColor::Off;
bool ldrNight = false;
bool whiteLightsOn = false;
bool parkingKnown = false;
bool trafficHasSpace = true;
bool builtinLedOn = false;
uint32_t countdownStartedAt = 0;
uint32_t clearStartedAt = 0;
uint32_t buzzerUntil = 0;
uint32_t diagnosticToneUntil = 0;
uint32_t nextBuzzerAt = 0;
uint8_t courtesyBeepCount = 0;
uint32_t nextHeartbeatAt = 0;
uint32_t nextClaimAt = 0;
uint32_t nextParkingPollAt = 0;
uint32_t nextWifiAttemptAt = 0;
uint32_t nextDiagSensorAt = 0;
uint32_t nextOperationRpcAt = 0;
uint32_t nextRecoveryStatusAt = 0;
uint32_t recoveryClearStartedAt = 0;
uint32_t nextRecoveryNoticeAt = 0;
uint32_t nextSensorReportRetryAt = 0;
uint32_t lastClockNoticeAt = 0;
bool recoveryBackendTerminal = false;
bool recoveryClearTracking = false;
uint16_t activeSensorEdgeGeneration = 0;
bool sensorTelemetryInitialized = false;
bool lastReportedEntryDetected = false;
bool lastReportedExitDetected = false;
bool lastReportedLdrNight = false;
bool lastReportedWhiteLightsOn = false;
bool lastReportedLightingManual = false;
RgbColor lastReportedRgbColor = RgbColor::Off;
String manualFailureEvent;
String manualFailureReason;
uint8_t ledTestRemaining = 0;
bool ledTestEntry = false;
uint32_t ledTestNextAt = 0;
String serialLine;
volatile uint8_t sensorLowLatch = 0;
volatile uint16_t sensorEdgeGeneration[2] = {0, 0};
TfcSafety::SensorClearTracker sensorClearTrackers[2];

bool due(uint32_t now, uint32_t target) { return static_cast<int32_t>(now - target) >= 0; }
bool clockIsValid() { return time(nullptr) > 1700000000; }
bool hasPlaceholder(const char *value) {
  return value == nullptr || value[0] == '\0' || strstr(value, "COMPLETAR") != nullptr;
}

void IRAM_ATTR entrySensorEdge() { sensorLowLatch |= 0x01; ++sensorEdgeGeneration[0]; }
void IRAM_ATTR exitSensorEdge() { sensorLowLatch |= 0x02; ++sensorEdgeGeneration[1]; }

bool pcaWrite(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(PCA9685_ADDRESS);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

bool pcaRead(uint8_t reg, uint8_t &value) {
  Wire.beginTransmission(PCA9685_ADDRESS);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0 || Wire.requestFrom(PCA9685_ADDRESS, static_cast<uint8_t>(1)) != 1) return false;
  value = Wire.read();
  return true;
}

bool pcaSetOff(uint8_t channel) {
  const uint8_t base = REG_LED0_ON_L + 4 * channel;
  return pcaWrite(base, 0) && pcaWrite(base + 1, 0) && pcaWrite(base + 2, 0) && pcaWrite(base + 3, 0x10);
}

bool pcaSetOn(uint8_t channel) {
  const uint8_t base = REG_LED0_ON_L + 4 * channel;
  return pcaWrite(base, 0) && pcaWrite(base + 1, 0x10) && pcaWrite(base + 2, 0) && pcaWrite(base + 3, 0);
}

bool pcaSetRgbChannel(uint8_t channel, bool ledOn) {
  // En el PCA, FULL_ON mantiene la salida HIGH y FULL_OFF la lleva LOW.
  // Para ánodo común: LOW enciende el LED y HIGH lo apaga.
  const bool outputHigh = PCA_RGB_ACTIVE_LOW ? !ledOn : ledOn;
  return outputHigh ? pcaSetOn(channel) : pcaSetOff(channel);
}

bool pcaSetPulseUs(uint8_t channel, uint16_t pulseUs) {
  const uint16_t ticks = static_cast<uint16_t>((static_cast<uint32_t>(pulseUs) * 4096UL * 50UL) / 1000000UL);
  const uint8_t base = REG_LED0_ON_L + 4 * channel;
  return pcaWrite(base, 0) && pcaWrite(base + 1, 0) &&
         pcaWrite(base + 2, static_cast<uint8_t>(ticks & 0xFF)) &&
         pcaWrite(base + 3, static_cast<uint8_t>((ticks >> 8) & 0x0F));
}

bool pcaBegin() {
  uint8_t mode = 0;
  if (!pcaRead(REG_MODE1, mode)) return false;
  const uint8_t sleepMode = static_cast<uint8_t>((mode & 0x7F) | 0x10);
  if (!pcaWrite(REG_MODE1, sleepMode) || !pcaWrite(REG_PRESCALE, 121) ||
      !pcaWrite(REG_MODE1, static_cast<uint8_t>(mode & ~0x10))) return false;
  delay(5); // Tiempo de arranque requerido tras salir de SLEEP; no es espera de operación.
  if (!pcaWrite(REG_MODE1, static_cast<uint8_t>((mode & ~0x10) | 0xA0))) return false;
  // Servos quedan sin pulsos; RGB se inicializa usando su polaridad física.
  for (uint8_t channel = 0; channel < 16; ++channel) {
    const bool isRgb = channel == PCA_RGB_RED || channel == PCA_RGB_GREEN;
    if (isRgb ? !pcaSetRgbChannel(channel, false) : !pcaSetOff(channel)) return false;
  }
  return true;
}

void setBuiltinLed(bool on) {
  builtinLedOn = on;
  digitalWrite(LED_BUILTIN, (on == (LED_ACTIVE_LOW != 0)) ? LOW : HIGH);
}

void stopBuzzerOutput() {
  noTone(PIN_BUZZER);
  digitalWrite(PIN_BUZZER, LOW);
  buzzerUntil = 0;
  diagnosticToneUntil = 0;
}

void startOperationTone() {
  stopBuzzerOutput();
  tone(PIN_BUZZER, AUTOMATIC_BUZZER_FREQUENCY_HZ);
}

void startCourtesyBeep(uint32_t now) {
  stopBuzzerOutput();
  tone(PIN_BUZZER, AUTOMATIC_BUZZER_FREQUENCY_HZ);
  buzzerUntil = now + COURTESY_BEEP_MS;
}

void startDiagnosticTone(uint16_t durationMs, uint16_t frequencyHz) {
  stopBuzzerOutput();
  tone(PIN_BUZZER, frequencyHz);
  diagnosticToneUntil = millis() + durationMs;
  Serial.printf("[buzzer] Tono %u Hz durante %u ms en D7/GPIO13.\n",
                frequencyHz, durationMs);
}

void stopDiagnosticTone() {
  stopBuzzerOutput();
}

void serviceBuzzer(uint32_t now) {
  if (buzzerUntil && due(now, buzzerUntil)) {
    stopBuzzerOutput();
  }
  if (diagnosticToneUntil && due(now, diagnosticToneUntil)) {
    stopBuzzerOutput();
    Serial.println("[buzzer] Tono detenido; salida apagada.");
  }
  if (operationStage == OperationStage::Countdown && courtesyBeepCount < 3 && due(now, nextBuzzerAt)) {
    startCourtesyBeep(now);
    courtesyBeepCount++;
    nextBuzzerAt = now + COURTESY_BEEP_INTERVAL_MS;
  }
}

String projectUrl(const String &path) {
  String base = SUPABASE_URL;
  while (base.endsWith("/")) base.remove(base.length() - 1);
  return base + path;
}

RpcResponse request(const String &url, const char *method, JsonDocument *payload = nullptr) {
  RpcResponse response{-1, String()};
  if (WiFi.status() != WL_CONNECTED || !clockIsValid()) return response;
  const uint32_t requestStartedAt = millis();
  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
#if defined(TFC_PROFILE_LOCAL)
  WiFiClient localClient;
  localClient.setTimeout(HTTP_TIMEOUT_MS);
  if (!http.begin(localClient, url)) return response;
#else
  BearSSL::WiFiClientSecure tls;
  tls.setTrustAnchors(&trustAnchors);
  tls.setTimeout(HTTP_TIMEOUT_MS);
  if (!http.begin(tls, url)) return response;
#endif
  http.addHeader("apikey", SUPABASE_PUBLISHABLE_KEY);
  http.addHeader("Accept", "application/json");
  if (payload != nullptr) {
    http.addHeader("Content-Type", "application/json");
    String body;
    serializeJson(*payload, body);
    response.status = http.POST(reinterpret_cast<const uint8_t *>(body.c_str()), body.length());
  } else if (strcmp(method, "GET") == 0) {
    response.status = http.GET();
  }
  if (response.status > 0) response.body = http.getString();
  else {
#if defined(TFC_PROFILE_LOCAL)
    Serial.printf("[HTTP LOCAL] Solicitud fallida: HTTP %d; WiFi=%d RSSI=%d dBm heap=%u\n",
#else
    Serial.printf("[HTTPS] Solicitud fallida: HTTP %d; WiFi=%d RSSI=%d dBm heap=%u\n",
#endif
                  response.status, static_cast<int>(WiFi.status()), WiFi.RSSI(), ESP.getFreeHeap());
  }
  http.end();

const String endpoint = url.substring(url.lastIndexOf('/') + 1);

Serial.printf(
#if defined(TFC_PROFILE_LOCAL)
  "[HTTP LOCAL TIEMPO] %s: %lu ms - HTTP %d\n",
#else
  "[HTTPS TIEMPO] %s: %lu ms - HTTP %d\n",
#endif
  endpoint.c_str(),
  static_cast<unsigned long>(millis() - requestStartedAt),
  response.status
);

return response;
}

RpcResponse postRpc(const char *name, JsonDocument &payload) {
  return request(projectUrl(String("/rest/v1/rpc/") + name), "POST", &payload);
}

bool parseBoolean(const String &body, bool &value) {
  JsonDocument doc;
  if (deserializeJson(doc, body) != DeserializationError::Ok || !doc.is<bool>()) return false;
  value = doc.as<bool>();
  return true;
}

bool rpcSucceeded(const RpcResponse &response) { return response.status >= 200 && response.status < 300; }

bool sendHeartbeat() {
  JsonDocument payload;
  payload["p_device_id"] = DEVICE_ID;
  payload["p_device_secret"] = ESP_DEVICE_SECRET;
  RpcResponse response = postRpc("heartbeat_device", payload);
  bool accepted = false;
  if (response.status != 200 || !parseBoolean(response.body, accepted) || !accepted) {
    Serial.printf("[heartbeat] No confirmado (HTTP %d).\n", response.status);
    return false;
  }
  Serial.println("[heartbeat] esp8266-main activo; modo hardware.");
  return true;
}

bool sendSensorTelemetry() {
  const bool entryDetected = digitalRead(PIN_ENTRY_IR) == LOW;
  const bool exitDetected = digitalRead(PIN_EXIT_IR) == LOW;
  JsonDocument payload;
  payload["p_device_id"] = DEVICE_ID;
  payload["p_device_secret"] = ESP_DEVICE_SECRET;
  payload["p_entry_detected"] = entryDetected;
  payload["p_exit_detected"] = exitDetected;
  payload["p_ldr_night"] = ldrNight;
  payload["p_white_lights_on"] = whiteLightsOn;
  payload["p_rgb_state"] = rgbColor == RgbColor::Red ? "red" : rgbColor == RgbColor::Green ? "green" : "off";
  payload["p_lighting_manual"] = manualWhiteOverride || manualRgbOverride;
  RpcResponse response = postRpc("report_device_sensor_state", payload);
  bool accepted = false;
  if (response.status != 200 || !parseBoolean(response.body, accepted) || !accepted) {
    Serial.printf("[sensores] Telemetría no confirmada (HTTP %d).\n", response.status);
    return false;
  }
  lastReportedEntryDetected = entryDetected;
  lastReportedExitDetected = exitDetected;
  lastReportedLdrNight = ldrNight;
  lastReportedWhiteLightsOn = whiteLightsOn;
  lastReportedRgbColor = rgbColor;
  lastReportedLightingManual = manualWhiteOverride || manualRgbOverride;
  sensorTelemetryInitialized = true;
  Serial.printf("[sensores] entrada=%s salida=%s.\n", entryDetected ? "detectando" : "libre", exitDetected ? "detectando" : "libre");
  return true;
}

bool acknowledge(const DeviceCommand &command, const char *status, const char *event, const char *reason = nullptr) {
  JsonDocument payload;
  payload["p_device_id"] = DEVICE_ID;
  payload["p_device_secret"] = ESP_DEVICE_SECRET;
  payload["p_command_id"] = command.id;
  payload["p_status"] = status;
  JsonObject result = payload["p_result"].to<JsonObject>();
  result["event"] = event;
  if (!command.operationId.isEmpty()) result["operation_id"] = command.operationId;
  if (!command.direction.isEmpty()) result["direction"] = command.direction;
  if (reason) result["reason"] = reason;
  if (strcmp(status, "confirmed") == 0) {
    if (command.commandType == "open_gate") {
      result["barrier_actuated"] = true;
      result["servo_channel"] = command.direction == "entry" ? PCA_SERVO_ENTRY : PCA_SERVO_EXIT;
    } else {
      result["manual_action"] = command.manualAction;
      result["manual_target"] = command.manualTarget;
      result["hardware_write_succeeded"] = true;
    }
  }
  RpcResponse response = postRpc("ack_device_command", payload);
  bool accepted = false;
  const bool parsed = parseBoolean(response.body, accepted);
  Serial.printf("[ack] %s, HTTP %d, aceptado=%s, vencimiento en %ld s\n", status,
                response.status, parsed && accepted ? "sí" : "no",
                static_cast<long>(command.expiresAt - (int64_t)time(nullptr)));
  return response.status == 200 && parsed && accepted;
}

bool enqueue(const DeviceCommand &command) {
  return queueCommands.push(command);
}

struct DeviceCommandStatus {
  String commandStatus;
  String operationStatus;
};

bool getDeviceCommandStatus(const DeviceCommand &command, DeviceCommandStatus &status) {
  JsonDocument payload;
  payload["p_device_id"] = DEVICE_ID;
  payload["p_device_secret"] = ESP_DEVICE_SECRET;
  payload["p_command_id"] = command.id;
  RpcResponse response = postRpc("get_device_command_status", payload);
  if (!rpcSucceeded(response)) return false;
  JsonDocument doc;
  if (deserializeJson(doc, response.body) != DeserializationError::Ok ||
      !doc.is<JsonArray>() || doc.as<JsonArray>().size() == 0) return false;
  JsonObject row = doc[0].as<JsonObject>();
  status.commandStatus = row["command_status"] | "";
  status.operationStatus = row["operation_status"] | "";
  return !status.commandStatus.isEmpty() && !status.operationStatus.isEmpty();
}

bool terminalStatus(const String &status) {
  return status == "confirmed" || status == "failed" || status == "cancelled";
}

int64_t daysFromCivil(int year, unsigned month, unsigned day) {
  year -= month <= 2;
  const int era = (year >= 0 ? year : year - 399) / 400;
  const unsigned yearOfEra = static_cast<unsigned>(year - era * 400);
  const unsigned adjustedMonth = month > 2 ? month - 3 : month + 9;
  const unsigned dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1;
  const unsigned dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
  return static_cast<int64_t>(era) * 146097 + dayOfEra - 719468;
}

bool parseTimestamp(const char *value, int64_t &epochSeconds) {
  if (!value) return false;
  int year=0, month=0, day=0, hour=0, minute=0, second=0, consumed=0;
  if (sscanf(value, "%d-%d-%dT%d:%d:%d%n", &year,&month,&day,&hour,&minute,&second,&consumed) != 6) return false;
  if (month<1 || month>12 || day<1 || day>31 || hour>23 || minute>59 || second>60) return false;
  const char *zone = value + consumed;
  if (*zone == '.') { ++zone; while (*zone >= '0' && *zone <= '9') ++zone; }
  int offset = 0;
  if (*zone == '+' || *zone == '-') {
    int oh=0, om=0;
    if (sscanf(zone+1, "%d:%d", &oh,&om) != 2 || oh>23 || om>59) return false;
    offset = (*zone == '+' ? 1 : -1) * (oh*3600 + om*60);
  } else if (*zone != 'Z' && *zone != '\0') return false;
  epochSeconds = daysFromCivil(year, static_cast<unsigned>(month), static_cast<unsigned>(day))*86400 + hour*3600 + minute*60 + second - offset;
  return true;
}

void claimCommands() {
  JsonDocument payload;
  payload["p_device_id"] = DEVICE_ID;
  payload["p_device_secret"] = ESP_DEVICE_SECRET;
  RpcResponse response = postRpc("claim_device_commands", payload);
  if (response.status != 200) {
    if (response.status > 0) Serial.printf("[comandos] HTTP %d\n", response.status);
    return;
  }
  JsonDocument doc;
  if (deserializeJson(doc, response.body) != DeserializationError::Ok || !doc.is<JsonArray>()) {
    Serial.println("[comandos] Respuesta JSON inválida.");
    return;
  }
  for (JsonObject row : doc.as<JsonArray>()) {
    DeviceCommand command;
    command.id = row["command_id"] | "";
    command.operationId = row["operation_id"] | "";
    command.commandType = row["command_type"] | "open_gate";
    command.manualAction = row["payload"]["action"] | "";
    command.manualTarget = row["payload"]["target"] | "";
    command.requestId = row["payload"]["request_id"] | "";
    command.direction = row["payload"]["direction"] | "";
    command.vehicleType = row["payload"]["vehicle_type"] | "";
    
const char *expiry = row["expires_at"].as<const char*>();
const bool expiryOk = parseTimestamp(expiry, command.expiresAt);

Serial.printf(
  "[CMD DIAG] expires_at='%s' parse=%s epoch=%ld id=%s operation=%s direction='%s'\n",
  expiry ? expiry : "(null)",
  expiryOk ? "SI" : "NO",
  static_cast<long>(command.expiresAt),
  command.id.isEmpty() ? "VACIO" : "OK",
  command.operationId.isEmpty() ? "VACIO" : "OK",
  command.direction.c_str()
);

const bool vehicleTypeOk = command.vehicleType == "regular" ||
                           command.vehicleType == "reserved" ||
                           command.vehicleType == "temporary";
const bool manualActionOk = command.manualAction == "barrier_open" || command.manualAction == "barrier_close" ||
                            command.manualAction == "white_on" || command.manualAction == "white_off" ||
                            command.manualAction == "rgb_red" || command.manualAction == "rgb_green" ||
                            command.manualAction == "rgb_off" || command.manualAction == "lighting_auto";
const bool manualTargetOk = command.manualAction == "barrier_open" || command.manualAction == "barrier_close"
                              ? (command.manualTarget == "entry" || command.manualTarget == "exit")
                              : command.manualTarget.isEmpty();
const bool manualCommand = command.commandType == "manual_control";
if (!expiryOk || command.id.isEmpty() ||
    (manualCommand ? (!manualActionOk || !manualTargetOk || command.requestId.isEmpty() || !command.operationId.isEmpty()) :
      (command.commandType != "open_gate" || command.operationId.isEmpty() || !vehicleTypeOk ||
       (command.direction != "entry" && command.direction != "exit")))) {

      Serial.println("[comandos] Orden inválida/expirada; no se acciona hardware.");
      if (!command.id.isEmpty()) acknowledge(command, "failed", "invalid_or_expired", "orden inválida o sin hora válida");
      continue;
    }
    if (command.expiresAt <= static_cast<int64_t>(time(nullptr))) {
      Serial.printf("[comandos] Orden vencida para %s; no se acciona.\n", command.direction.c_str());
      acknowledge(command, "failed", "expired", "orden vencida antes de ejecutarse");
      continue;
    }
    if (!enqueue(command)) {
      Serial.println("[comandos] Cola local llena; orden rechazada.");
      acknowledge(command, "failed", "queue_full", "cola local llena");
      continue;
    }
    if (manualCommand) Serial.printf("[comandos] mantenimiento recibido: %s %s\n", command.manualAction.c_str(), command.manualTarget.c_str());
    else Serial.printf("[comandos] open_gate recibido: %s%s\n", command.direction.c_str(),
                       command.vehicleType == "reserved" ? " (reservado)" : "");
  }
}

void startServoMove(uint8_t channel, uint16_t targetUs) {
  uint16_t current = targetUs;
  const uint16_t closed = channel == PCA_SERVO_ENTRY ? ENTRY_CLOSED_US : EXIT_CLOSED_US;
  const uint16_t opened = channel == PCA_SERVO_ENTRY ? ENTRY_OPEN_US : EXIT_OPEN_US;
  if (servoMotion.active) {
  if (servoMotion.channel == channel) {
    // Invertir el movimiento desde la posición actual.
    servoMotion.startUs = servoMotion.currentUs;
    servoMotion.targetUs = targetUs;
    servoMotion.nextStepAt = millis();

    Serial.println("[servo] Cambio de dirección durante movimiento.");
  }
  return;
}
  servoFault = false;
  // Track each servo's last commanded position; setup deliberately starts OFF.
  if (servoPositions[channel] == 0) servoPositions[channel] = targetUs == opened ? closed : opened;
  current = servoPositions[channel];
  servoMotion.active = true;
  servoMotion.channel = channel;
  servoMotion.startUs = current;
  servoMotion.currentUs = current;
  servoMotion.targetUs = targetUs;
  servoMotion.nextStepAt = millis();
  Serial.printf("[servo] canal %u: %u -> %u us\n", channel, current, targetUs);
}

bool serviceServo(uint32_t now) {
  if (!servoMotion.active || !due(now, servoMotion.nextStepAt)) return false;
  const int16_t delta = static_cast<int16_t>(servoMotion.targetUs) - static_cast<int16_t>(servoMotion.currentUs);
  if (delta == 0) {
    servoMotion.active = false;
    return true;
  }
  const int16_t step = delta > 0 ? min<int16_t>(delta, 12) : max<int16_t>(delta, -12);
  const uint16_t next = static_cast<uint16_t>(static_cast<int16_t>(servoMotion.currentUs) + step);
  if (!pcaSetPulseUs(servoMotion.channel, next)) {
    pcaReady = false;
    servoFault = true;
    servoMotion.active = false;
    Serial.println("[PCA9685] Error I2C durante movimiento; posición no confirmada.");
    return true;
  }
  servoMotion.currentUs = next;
  servoMotion.nextStepAt = now + SERVO_STEP_MS;
  if (next == servoMotion.targetUs) {
    servoMotion.active = false;
    servoPositions[servoMotion.channel] = next;
    return true;
  }
  return false;
}

int8_t sensorIndexForDirection(const String &direction) {
  if (direction == "entry") return 0;
  if (direction == "exit") return 1;
  return -1;
}

uint8_t sensorPinForIndex(uint8_t index) { return index == 0 ? PIN_ENTRY_IR : PIN_EXIT_IR; }
uint8_t sensorMaskForIndex(uint8_t index) { return index == 0 ? 0x01 : 0x02; }
uint8_t activeSensorPin() { return activeCommand.direction == "entry" ? PIN_ENTRY_IR : PIN_EXIT_IR; }

uint16_t readSensorEdgeGeneration(uint8_t index) {
  noInterrupts();
  const uint16_t generation = sensorEdgeGeneration[index];
  interrupts();
  return generation;
}

bool sensorReadyForBarrier(const String &direction, uint32_t now) {
  const int8_t index = sensorIndexForDirection(direction);
  if (index < 0) return false;
  const uint8_t lane = static_cast<uint8_t>(index);
  const uint8_t pin = sensorPinForIndex(lane);
  const uint16_t generation = readSensorEdgeGeneration(lane);
  const bool high = digitalRead(pin) != LOW;
  const bool stable = sensorClearTrackers[lane].update(high, generation, now, SENSOR_CLEAR_MS);
  if (!stable) return false;

  noInterrupts();
  const bool stillHigh = digitalRead(pin) != LOW;
  const bool unchanged = sensorEdgeGeneration[lane] == generation;
  if (stillHigh && unchanged)
    sensorLowLatch &= static_cast<uint8_t>(~sensorMaskForIndex(lane));
  const bool pending = (sensorLowLatch & sensorMaskForIndex(lane)) != 0;
  interrupts();
  return stillHigh && unchanged && !pending;
}

void serviceSensorLatches(uint32_t now) {
  sensorReadyForBarrier("entry", now);
  sensorReadyForBarrier("exit", now);
}

bool operationObstaclePresent() {
  const int8_t index = sensorIndexForDirection(activeCommand.direction);
  if (index < 0) return true;
  const uint8_t lane = static_cast<uint8_t>(index);
  const uint16_t generation = readSensorEdgeGeneration(lane);
  const bool newEdge = generation != activeSensorEdgeGeneration;
  if (newEdge) activeSensorEdgeGeneration = generation;
  return digitalRead(sensorPinForIndex(lane)) == LOW || newEdge;
}

bool dequeueReadyCommand(DeviceCommand &command, uint32_t now) {
  for (size_t offset = 0; offset < queueCommands.size(); ++offset) {
    DeviceCommand candidate;
    if (!queueCommands.peek(offset, candidate)) continue;
    const bool expired = candidate.expiresAt <= static_cast<int64_t>(time(nullptr));
    const bool manual = candidate.commandType == "manual_control";
    const bool closeNeedsClear = candidate.manualAction == "barrier_close";
    const bool ready = manual ? (!closeNeedsClear || sensorReadyForBarrier(candidate.manualTarget, now))
                              : sensorReadyForBarrier(candidate.direction, now);
    if (expired || ready)
      return queueCommands.remove(offset, command);
  }
  return false;
}
uint8_t servoForDirection(const String &direction) { return direction == "entry" ? PCA_SERVO_ENTRY : PCA_SERVO_EXIT; }
uint16_t servoOpenUs(const String &direction) { return direction == "entry" ? ENTRY_OPEN_US : EXIT_OPEN_US; }
uint16_t servoClosedUs(const String &direction) { return direction == "entry" ? ENTRY_CLOSED_US : EXIT_CLOSED_US; }

bool sendSensorReport(bool detected, uint32_t clearMs = 0) {
  JsonDocument payload;
  payload["p_device_id"] = DEVICE_ID;
  payload["p_device_secret"] = ESP_DEVICE_SECRET;
  payload["p_operation_id"] = activeCommand.operationId;
  payload["p_detected"] = detected;
  payload["p_clear_ms"] = clearMs;
  RpcResponse response = postRpc("report_device_sensor", payload);
  Serial.printf("[sensor RPC] %s HTTP %d\n", detected ? "detectado" : "liberado 500ms", response.status);
  return rpcSucceeded(response);
}

bool finishOperation() {
  JsonDocument payload;
  payload["p_device_id"] = DEVICE_ID;
  payload["p_device_secret"] = ESP_DEVICE_SECRET;
  payload["p_operation_id"] = activeCommand.operationId;
  RpcResponse response = postRpc("finish_device_operation", payload);
  Serial.printf("[finish] HTTP %d; Supabase confirma y contabiliza el movimiento.\n", response.status);
  return rpcSucceeded(response);
}

void setSemaphore(bool hasSpace) {
  if (!pcaReady) return;
  const bool ok = hasSpace ? (pcaSetOff(PCA_TRAFFIC_RED) && pcaSetOn(PCA_TRAFFIC_GREEN))
                           : (pcaSetOn(PCA_TRAFFIC_RED) && pcaSetOff(PCA_TRAFFIC_GREEN));
  if (ok) { trafficHasSpace = hasSpace; parkingKnown = true; }
}

bool setRgb(RgbColor color) {
  if (!pcaReady) return false;
  const bool redOn = color == RgbColor::Red;
  const bool greenOn = color == RgbColor::Green;
  const bool ok = pcaSetRgbChannel(PCA_RGB_RED, redOn) &&
                  pcaSetRgbChannel(PCA_RGB_GREEN, greenOn);
  if (!ok) Serial.println("[PCA9685] Falló actualización de RGB.");
  else rgbColor = color;
  return ok;
}

bool restoreIdleRgb() {
  if (manualRgbOverride) return true;
  return setRgb(ldrNight ? RgbColor::Red : RgbColor::Off);
}

void clearActiveOperation() {
  stopBuzzerOutput();
  operationStage = OperationStage::Idle;
  activeCommand = DeviceCommand();
  reservedIndicatorActive = false;
  clearStartedAt = 0;
  countdownStartedAt = 0;
  nextBuzzerAt = 0;
  courtesyBeepCount = 0;
  nextOperationRpcAt = 0;
  nextRecoveryStatusAt = 0;
  recoveryClearStartedAt = 0;
  recoveryClearTracking = false;
  recoveryBackendTerminal = false;
  if (queueCommands.empty() && activeCommand.commandType != "manual_control") restoreIdleRgb();
}

bool setWhiteLights(bool on) {
  if (!pcaReady) return false;
  bool ok = true;
  for (uint8_t channel=PCA_WHITE_FIRST; channel<=PCA_WHITE_LAST; ++channel)
    ok = (on ? pcaSetOn(channel) : pcaSetOff(channel)) && ok;
  if (!ok) Serial.println("[PCA9685] Falló actualización de luces blancas.");
  else whiteLightsOn = on;
  return ok;
}

void pollParkingState() {
  RpcResponse response = request(projectUrl("/rest/v1/parking_state?select=regular_count,regular_capacity,reserved_contingency_count&id=eq.1"), "GET");
  if (!rpcSucceeded(response)) {
    Serial.printf("[parking_state] Lectura no disponible (HTTP %d); se conserva semáforo.\n", response.status);
    return;
  }
  JsonDocument doc;
  if (deserializeJson(doc, response.body) != DeserializationError::Ok || !doc.is<JsonArray>() || doc.as<JsonArray>().size() == 0) return;
  const JsonObject row = doc[0];
  const int count = row["regular_count"] | -1;
  const int capacity = row["regular_capacity"] | -1;
  const int reservedContingency = row["reserved_contingency_count"] | 0;
  if (count < 0 || capacity <= 0) return;
  const bool hasSpace = count + reservedContingency < capacity;
  setSemaphore(hasSpace);
  Serial.printf("[parking_state] usados %d+%d/%d, semáforo %s.\n", count, reservedContingency, capacity, hasSpace ? "verde" : "rojo");
}


void serviceLdr() {
  static uint32_t lastReadAt = 0;
  const uint32_t now = millis();

  // Leer el LDR como máximo una vez cada 200 ms.
  if (now - lastReadAt < 200) return;

  lastReadAt = now;

  const int reading = analogRead(A0);
  if (LDR_DARK_WHEN_LOW) {
    if (!ldrNight && reading <= LDR_NIGHT_THRESHOLD) ldrNight = true;
    else if (ldrNight && reading >= LDR_DAY_THRESHOLD) ldrNight = false;
  } else {
    if (!ldrNight && reading >= LDR_DAY_THRESHOLD) ldrNight = true;
    else if (ldrNight && reading <= LDR_NIGHT_THRESHOLD) ldrNight = false;
  }
  if (diagnosticMode) return;
  if (!manualWhiteOverride && ldrNight != whiteLightsOn) {
    setWhiteLights(ldrNight);
    if (!manualRgbOverride && operationStage == OperationStage::Idle && queueCommands.empty() && !reservedIndicatorActive)
      restoreIdleRgb();
  }
}

void enterFailedState(const char *reason) {
  stopBuzzerOutput();
  courtesyBeepCount = 0;
  nextBuzzerAt = 0;
  countdownStartedAt = 0;
  operationStage = OperationStage::Failed;
  recoveryBackendTerminal = false;
  recoveryClearTracking = false;
  recoveryClearStartedAt = 0;
  nextRecoveryStatusAt = 0;
  Serial.printf("[recuperación] Operación retenida en Failed: %s. No se libera hasta reconciliar Supabase y la barrera.\n", reason);
}

void beginOperation(uint32_t now) {
  if (operationStage != OperationStage::Idle || queueCommands.empty() || diagnosticMode) return;
  DeviceCommand next;
  if (!dequeueReadyCommand(next, now)) return;
  activeCommand = next;
  if (activeCommand.commandType == "manual_control") {
    operationStage = OperationStage::ManualAckRunning;
    nextOperationRpcAt = now;
    if (activeCommand.manualTarget == "entry" || activeCommand.manualTarget == "exit")
      activeSensorEdgeGeneration = readSensorEdgeGeneration(static_cast<uint8_t>(sensorIndexForDirection(activeCommand.manualTarget)));
    return;
  }
  manualWhiteOverride = false;
  manualRgbOverride = false;
  activeSensorEdgeGeneration = readSensorEdgeGeneration(static_cast<uint8_t>(sensorIndexForDirection(activeCommand.direction)));
  operationStage = OperationStage::AckRunning;
  nextOperationRpcAt = now;
  Serial.printf("[operación] Comando seleccionado: %s %s; interlock del sensor listo.\n",
                activeCommand.direction.c_str(), activeCommand.vehicleType.c_str());
}

void serviceRunningAcknowledgement(uint32_t now) {
  if (activeCommand.id.isEmpty() || activeCommand.operationId.isEmpty()) {
    enterFailedState("referencia de comando incompleta");
    return;
  }
  if (activeCommand.expiresAt <= static_cast<int64_t>(time(nullptr))) {
    acknowledge(activeCommand, "failed", "expired_before_actuation", "venció antes de mover el servo");
    enterFailedState("orden vencida antes de actuar");
    return;
  }
  if (!sensorReadyForBarrier(activeCommand.direction, now) || servoMotion.active) return;
  if (!pcaReady || servoFault) {
    acknowledge(activeCommand, "failed", "pca9685_unavailable", "no se confirmó el controlador del servo");
    enterFailedState("PCA9685 no disponible antes de abrir");
    return;
  }
  if (!due(now, nextOperationRpcAt)) return;
  nextOperationRpcAt = now + OPERATION_RPC_RETRY_MS;
  if (!acknowledge(activeCommand, "running", "barrier_opening")) {
    DeviceCommandStatus remote;
    if (getDeviceCommandStatus(activeCommand, remote) &&
        terminalStatus(remote.commandStatus) && terminalStatus(remote.operationStatus)) {
      enterFailedState("Supabase cerró el comando antes del ACK running");
    }
    return;
  }
  if (!sensorReadyForBarrier(activeCommand.direction, millis())) {
    acknowledge(activeCommand, "failed", "sensor_interlock", "sensor activo antes de accionar el servo");
    enterFailedState("el sensor se activó durante el ACK running");
    return;
  }
  activeSensorEdgeGeneration = readSensorEdgeGeneration(static_cast<uint8_t>(sensorIndexForDirection(activeCommand.direction)));
  if (activeCommand.vehicleType == "reserved" && activeCommand.direction == "entry") {
    setRgb(RgbColor::Green);
    reservedIndicatorActive = true;
  } else {
    setRgb(RgbColor::Red);
  }
  startOperationTone();
  startServoMove(servoForDirection(activeCommand.direction), servoOpenUs(activeCommand.direction));
  operationStage = OperationStage::Opening;
}

void serviceManualCommand(uint32_t now) {
  if (activeCommand.id.isEmpty() || activeCommand.commandType != "manual_control") {
    clearActiveOperation();
    return;
  }
  if (operationStage == OperationStage::ManualMoving) {
    if (activeCommand.manualAction == "barrier_close" &&
        digitalRead(sensorPinForIndex(static_cast<uint8_t>(sensorIndexForDirection(activeCommand.manualTarget)))) == LOW) {
      startServoMove(servoForDirection(activeCommand.manualTarget), servoOpenUs(activeCommand.manualTarget));
      manualFailureEvent = "sensor_interlock_reopened";
      manualFailureReason = "se detectó obstáculo durante el cierre; se reabrió la barrera";
      operationStage = OperationStage::ManualReopening;
      return;
    }
    if (!serviceServo(now)) return;
    if (servoFault || !pcaReady) {
      manualFailureEvent = "pca9685_write_failed";
      manualFailureReason = "falló escritura I2C durante movimiento manual";
      operationStage = OperationStage::ManualAckFailed;
      nextOperationRpcAt = now;
      return;
    }
    if (activeCommand.manualAction == "barrier_close" &&
        digitalRead(sensorPinForIndex(static_cast<uint8_t>(sensorIndexForDirection(activeCommand.manualTarget)))) == LOW) {
      startServoMove(servoForDirection(activeCommand.manualTarget), servoOpenUs(activeCommand.manualTarget));
      manualFailureEvent = "sensor_interlock_reopened";
      manualFailureReason = "se detectó obstáculo durante el cierre; se reabrió la barrera";
      operationStage = OperationStage::ManualReopening;
      return;
    }
    operationStage = OperationStage::ManualAckConfirmed;
    nextOperationRpcAt = now;
    return;
  }
  if (operationStage == OperationStage::ManualReopening) {
    if (!serviceServo(now)) return;
    operationStage = OperationStage::ManualAckFailed;
    nextOperationRpcAt = now;
    return;
  }
  if (operationStage == OperationStage::ManualAckFailed) {
    if (!due(now, nextOperationRpcAt)) return;
    nextOperationRpcAt = now + OPERATION_RPC_RETRY_MS;
    if (acknowledge(activeCommand, "failed", manualFailureEvent.c_str(), manualFailureReason.c_str())) clearActiveOperation();
    return;
  }
  if (operationStage == OperationStage::ManualAckConfirmed) {
    if (!due(now, nextOperationRpcAt)) return;
    nextOperationRpcAt = now + OPERATION_RPC_RETRY_MS;
    if (acknowledge(activeCommand, "confirmed", "manual_barrier_position_reached")) clearActiveOperation();
    return;
  }
  if (operationStage != OperationStage::ManualAckRunning) return;
  if (activeCommand.expiresAt <= static_cast<int64_t>(time(nullptr))) {
    acknowledge(activeCommand, "failed", "expired_before_actuation", "venció antes de ejecutar mantenimiento");
    clearActiveOperation();
    return;
  }
  if (!due(now, nextOperationRpcAt) || servoMotion.active) return;
  nextOperationRpcAt = now + OPERATION_RPC_RETRY_MS;

  if (operationStage == OperationStage::ManualAckRunning) {
    if (activeCommand.manualAction == "barrier_close" &&
        (!sensorReadyForBarrier(activeCommand.manualTarget, now) ||
         digitalRead(sensorPinForIndex(static_cast<uint8_t>(sensorIndexForDirection(activeCommand.manualTarget)))) == LOW)) {
      acknowledge(activeCommand, "failed", "sensor_interlock", "sensor activo o no libre de forma estable");
      clearActiveOperation();
      return;
    }
    if (activeCommand.manualAction == "barrier_open" || activeCommand.manualAction == "barrier_close") {
      if (!pcaReady || servoFault || !acknowledge(activeCommand, "running", "manual_barrier_moving")) return;
      const bool opening = activeCommand.manualAction == "barrier_open";
      startServoMove(servoForDirection(activeCommand.manualTarget), opening ? servoOpenUs(activeCommand.manualTarget) : servoClosedUs(activeCommand.manualTarget));
      operationStage = OperationStage::ManualMoving;
      return;
    }
    if (!acknowledge(activeCommand, "running", "manual_output_updating")) return;
    bool ok = pcaReady;
    if (activeCommand.manualAction == "white_on" || activeCommand.manualAction == "white_off") {
      manualWhiteOverride = true;
      const bool on = activeCommand.manualAction == "white_on";
      if (ok) ok = setWhiteLights(on);
    } else if (activeCommand.manualAction == "rgb_red" || activeCommand.manualAction == "rgb_green" || activeCommand.manualAction == "rgb_off") {
      manualRgbOverride = true;
      const RgbColor color = activeCommand.manualAction == "rgb_red" ? RgbColor::Red : activeCommand.manualAction == "rgb_green" ? RgbColor::Green : RgbColor::Off;
      if (ok) ok = setRgb(color);
    } else if (activeCommand.manualAction == "lighting_auto") {
      manualWhiteOverride = false;
      manualRgbOverride = false;
      if (ok) ok = setWhiteLights(ldrNight) && restoreIdleRgb();
    } else ok = false;
    acknowledge(activeCommand, ok ? "confirmed" : "failed", ok ? "manual_lighting_applied" : "pca9685_write_failed", ok ? nullptr : "falló la escritura del controlador");
    clearActiveOperation();
    return;
  }

}

TfcSafety::BarrierPosition trackedBarrierPosition(uint8_t channel) {
  const uint16_t position = servoPositions[channel];
  if (position == 0) return TfcSafety::BarrierPosition::Unknown;
  if (position == servoClosedUs(channel == PCA_SERVO_ENTRY ? "entry" : "exit"))
    return TfcSafety::BarrierPosition::Closed;
  if (position == servoOpenUs(channel == PCA_SERVO_ENTRY ? "entry" : "exit"))
    return TfcSafety::BarrierPosition::Open;
  return TfcSafety::BarrierPosition::Unknown;
}

void serviceFailedRecovery(uint32_t now) {
  if (activeCommand.id.isEmpty() || activeCommand.operationId.isEmpty()) {
    if (due(now, nextRecoveryNoticeAt)) {
      nextRecoveryNoticeAt = now + RECOVERY_NOTICE_INTERVAL_MS;
      Serial.println("[recuperación] Sin referencia de comando; requiere inspección física y administrativa.");
    }
    return;
  }
  if (!recoveryBackendTerminal && due(now, nextRecoveryStatusAt)) {
    nextRecoveryStatusAt = now + RECOVERY_STATUS_INTERVAL_MS;
    DeviceCommandStatus remote;
    if (getDeviceCommandStatus(activeCommand, remote) &&
        terminalStatus(remote.commandStatus) && terminalStatus(remote.operationStatus)) {
      recoveryBackendTerminal = true;
      Serial.printf("[recuperación] Estado remoto terminal: comando=%s operación=%s.\n",
                    remote.commandStatus.c_str(), remote.operationStatus.c_str());
    }
  }
  if (!recoveryBackendTerminal) return;

  const bool sensorClear = sensorReadyForBarrier(activeCommand.direction, now);
  if (!sensorClear) {
    recoveryClearTracking = false;
    return;
  }
  if (!pcaReady || servoFault || servoMotion.active) {
    if (due(now, nextRecoveryNoticeAt)) {
      nextRecoveryNoticeAt = now + RECOVERY_NOTICE_INTERVAL_MS;
      Serial.println("[recuperación] Backend terminal, pero el actuador no permite confirmar/cerrar la barrera; requiere intervención física.");
    }
    return;
  }
  if (!recoveryClearTracking) {
    recoveryClearStartedAt = now;
    recoveryClearTracking = true;
  }

  const uint8_t channel = servoForDirection(activeCommand.direction);
  const TfcSafety::RecoveryAction action = TfcSafety::recoveryAction(
      TfcSafety::RemoteOperationState::Terminal, sensorClear, true, trackedBarrierPosition(channel));
  if (action == TfcSafety::RecoveryAction::ReleaseLocalState) {
    Serial.println("[recuperación] Supabase terminal, sensor estable libre y barrera confirmada cerrada; se libera estado local.");
    clearActiveOperation();
    return;
  }
  if (action == TfcSafety::RecoveryAction::Wait) {
    if (due(now, nextRecoveryNoticeAt)) {
      nextRecoveryNoticeAt = now + RECOVERY_NOTICE_INTERVAL_MS;
      Serial.println("[recuperación] Posición de barrera desconocida; no se fuerza Idle. Inspección física requerida.");
    }
    return;
  }
  if (now - recoveryClearStartedAt < PASSAGE_COUNTDOWN_MS) return;
  if (!sensorReadyForBarrier(activeCommand.direction, millis())) {
    recoveryClearTracking = false;
    return;
  }
  startServoMove(channel, servoClosedUs(activeCommand.direction));
  operationStage = OperationStage::RecoveryClosing;
  Serial.println("[recuperación] Operación remota terminal y sensor libre; cierre seguro de recuperación iniciado.");
}

void serviceRecoveryClosing(uint32_t now) {
  if (operationObstaclePresent()) {
    startServoMove(servoForDirection(activeCommand.direction), servoOpenUs(activeCommand.direction));
    operationStage = OperationStage::RecoveryOpening;
    recoveryClearTracking = false;
    Serial.println("[recuperación] Sensor activado durante cierre; se reabre y se conserva Failed.");
    return;
  }
  if (!serviceServo(now)) return;
  if (servoFault || !pcaReady) {
    enterFailedState("falló el cierre de recuperación");
    return;
  }
  if (operationObstaclePresent()) {
    startServoMove(servoForDirection(activeCommand.direction), servoOpenUs(activeCommand.direction));
    operationStage = OperationStage::RecoveryOpening;
    recoveryClearTracking = false;
    Serial.println("[recuperación] Sensor activado al completar cierre; se reabre.");
    return;
  }
  if (trackedBarrierPosition(servoForDirection(activeCommand.direction)) != TfcSafety::BarrierPosition::Closed) {
    enterFailedState("no se pudo confirmar posición cerrada");
    return;
  }
  Serial.println("[recuperación] Barrera cerrada y sensor libre; se libera el estado local.");
  clearActiveOperation();
}

void serviceRecoveryOpening(uint32_t now) {
  if (!serviceServo(now)) return;
  if (servoFault || !pcaReady) {
    enterFailedState("falló la reapertura de recuperación");
    return;
  }
  activeSensorEdgeGeneration = readSensorEdgeGeneration(static_cast<uint8_t>(sensorIndexForDirection(activeCommand.direction)));
  recoveryClearTracking = false;
  operationStage = OperationStage::Failed;
  Serial.println("[recuperación] Barrera abierta; se mantiene Failed hasta despejar sensor y reconciliar nuevamente.");
}

void serviceOperation(uint32_t now) {
  if (operationStage == OperationStage::Idle) { beginOperation(now); return; }
  if (activeCommand.commandType == "manual_control") { serviceManualCommand(now); return; }
  if (operationStage == OperationStage::AckRunning) { serviceRunningAcknowledgement(now); return; }
  if (operationStage == OperationStage::Failed) { serviceFailedRecovery(now); return; }
  if (operationStage == OperationStage::RecoveryClosing) { serviceRecoveryClosing(now); return; }
  if (operationStage == OperationStage::RecoveryOpening) { serviceRecoveryOpening(now); return; }

  if (operationStage == OperationStage::Opening) {
    if (!serviceServo(now)) return;
    if (servoFault) {
      acknowledge(activeCommand, "failed", "pca9685_write_failed", "falló escritura I2C durante apertura");
      enterFailedState("falló el movimiento de apertura");
      return;
    }
    stopBuzzerOutput();
    operationStage = OperationStage::AckConfirmed;
  }
  if (operationStage == OperationStage::AckConfirmed) {
    if (!acknowledge(activeCommand, "confirmed", "barrier_actuated")) {
      Serial.println("[operación] ACK confirmed rechazado. Se reconcilia Supabase antes de intentar recuperación.");
      enterFailedState("ACK confirmed sin respuesta aceptada");
      return;
    }
    Serial.println("[operación] Barrera abierta; esperando sensor activo LOW.");
    operationStage = OperationStage::WaitDetect;
  }
  if (operationStage == OperationStage::WaitDetect) {
    if (operationObstaclePresent()) operationStage = OperationStage::ReportDetect;
    return;
  }
  if (operationStage == OperationStage::ReportDetect) {
    if (!due(now, nextOperationRpcAt)) return;
    nextOperationRpcAt = now + OPERATION_RPC_RETRY_MS;
    if (!sendSensorReport(true)) return;
    activeSensorEdgeGeneration = readSensorEdgeGeneration(static_cast<uint8_t>(sensorIndexForDirection(activeCommand.direction)));
    clearStartedAt = 0;
    operationStage = OperationStage::WaitStableClear;
  }
  if (operationStage == OperationStage::WaitStableClear) {
    const uint8_t pin = activeSensorPin();
    const uint16_t generation = readSensorEdgeGeneration(static_cast<uint8_t>(sensorIndexForDirection(activeCommand.direction)));
    if (digitalRead(pin) == LOW || generation != activeSensorEdgeGeneration) {
      activeSensorEdgeGeneration = generation;
      clearStartedAt = 0;
      return;
    }
    if (clearStartedAt == 0) clearStartedAt = now;
    if (now - clearStartedAt >= SENSOR_CLEAR_MS) operationStage = OperationStage::ReportClear;
    return;
  }
  if (operationStage == OperationStage::ReportClear) {
    if (operationObstaclePresent()) { clearStartedAt = 0; operationStage = OperationStage::ReportDetect; return; }
    if (!due(now, nextOperationRpcAt)) return;
    nextOperationRpcAt = now + OPERATION_RPC_RETRY_MS;
    if (!sendSensorReport(false, SENSOR_CLEAR_MS)) return;
    if (operationObstaclePresent()) { clearStartedAt = 0; operationStage = OperationStage::ReportDetect; return; }
    countdownStartedAt = millis();
    nextBuzzerAt = countdownStartedAt;
    courtesyBeepCount = 0;
    operationStage = OperationStage::Countdown;
    Serial.println("[operación] Sensor libre 500ms; cortesía de 3s con tres pitidos.");
  }
  if (operationStage == OperationStage::Countdown) {
    if (operationObstaclePresent()) {
      stopBuzzerOutput();
      courtesyBeepCount = 0;
      nextBuzzerAt = 0;
      countdownStartedAt = 0;
      Serial.println("[operación] Obstáculo reapareció; cortesía reiniciada y barrera permanece abierta.");
      operationStage = OperationStage::ReportDetect;
      return;
    }
    if (now - countdownStartedAt >= COURTESY_COUNTDOWN_MS && courtesyBeepCount == 3 && !buzzerUntil) {
      if (operationObstaclePresent()) { operationStage = OperationStage::ReportDetect; return; }
      startOperationTone();
      startServoMove(servoForDirection(activeCommand.direction), servoClosedUs(activeCommand.direction));
      operationStage = OperationStage::Closing;
      Serial.println("[operación] Cortesía finalizada; cerrando barrera.");
    }
    return;
  }
  if (operationStage == OperationStage::Closing) {
    if (operationObstaclePresent()) {
      Serial.println("[seguridad] Obstáculo durante cierre; reabriendo.");
      startOperationTone();
      startServoMove(servoForDirection(activeCommand.direction), servoOpenUs(activeCommand.direction));
      operationStage = OperationStage::Reopening;
      return;
    }
    if (serviceServo(now)) {
      if (servoFault) { enterFailedState("falló el cierre normal"); return; }
      stopBuzzerOutput();
      if (operationObstaclePresent()) { startOperationTone(); startServoMove(servoForDirection(activeCommand.direction), servoOpenUs(activeCommand.direction)); operationStage = OperationStage::Reopening; }
      else operationStage = OperationStage::Finish;
    }
    return;
  }
  if (operationStage == OperationStage::Reopening) {
    if (!serviceServo(now)) return;
    if (servoFault) { enterFailedState("falló la reapertura normal"); return; }
    stopBuzzerOutput();
    if (operationObstaclePresent()) operationStage = OperationStage::ReportDetect;
    else { clearStartedAt = 0; operationStage = OperationStage::WaitStableClear; }
    return;
  }
  if (operationStage == OperationStage::Finish) {
    if (operationObstaclePresent()) { startOperationTone(); startServoMove(servoForDirection(activeCommand.direction), servoOpenUs(activeCommand.direction)); operationStage = OperationStage::Reopening; return; }
    if (!due(now, nextOperationRpcAt)) return;
    nextOperationRpcAt = now + OPERATION_RPC_RETRY_MS;
    if (!finishOperation()) {
      Serial.println("[finish] No confirmado. No se repite cierre; se mantiene la operación para reintento.");
      return;
    }
    Serial.println("[operación] Finalizada en Supabase; los contadores se actualizan allí.");
    clearActiveOperation();
  }
}

void allDiagnosticsOff() {
  stopDiagnosticTone();
  buzzerUntil = 0;
  if (!pcaReady) return;
  for (uint8_t channel=2; channel<=12; ++channel) {
    const bool isRgb = channel == PCA_RGB_RED || channel == PCA_RGB_GREEN;
    if (isRgb) pcaSetRgbChannel(channel, false);
    else pcaSetOff(channel);
  }
  restoreIdleRgb();
  setSemaphore(false); // rojo mientras el modo diagnóstico está activo.
  setWhiteLights(ldrNight);
}

struct ScanMatch { int rssi; int channel; int security; };
ScanMatch scanMatches[8];
unsigned scanTotal = 0, scanMatchCount = 0;
bool scanPending = false, scanDone = false, scanInterrupted = false;
bool scanPreviousAutoReconnect = true;
int scanSdkResult = -1;
uint32_t scanStartedAt = 0;

void printWifiScanStatus() {
  Serial.printf("[wifi scan] modo=%u (1=STA), WiFi=%d, SDK=%u, último motivo=%d; heap=%u, PHY=%u, sleep=%u\n",
                static_cast<unsigned>(WiFi.getMode()), static_cast<int>(WiFi.status()),
                wifi_station_get_connect_status(), lastWifiDisconnectReason, ESP.getFreeHeap(),
                static_cast<unsigned>(WiFi.getPhyMode()), static_cast<unsigned>(WiFi.getSleepMode()));
}

const char *wifiSecurityName(int security) {
  switch (security) {
    case AUTH_OPEN: return "abierta";
    case AUTH_WEP: return "WEP";
    case AUTH_WPA_PSK: return "WPA/PSK";
    case AUTH_WPA2_PSK: return "WPA2/PSK";
    case AUTH_WPA_WPA2_PSK: return "WPA/WPA2 mixto";
    default: return "desconocida";
  }
}

// El wrapper scanNetworks del core 3.1.2 convierte errores SDK en cero redes.
// Conservar STATUS directamente; copiar solo datos de diagnóstico durante el callback.
void wifiScanFinished(void *result, STATUS status) {
  scanSdkResult = static_cast<int>(status);
  scanTotal = 0;
  scanMatchCount = 0;
  if (status == OK) {
    for (const bss_info *ap = static_cast<bss_info *>(result); ap; ap = STAILQ_NEXT(ap, next)) {
      ++scanTotal;
      if (ap->ssid_len != strlen(WIFI_SSID) || memcmp(ap->ssid, WIFI_SSID, ap->ssid_len) != 0) continue;
      if (scanMatchCount < 8) scanMatches[scanMatchCount] = {ap->rssi, ap->channel, static_cast<int>(ap->authmode)};
      ++scanMatchCount;
    }
  }
  scanDone = true;
}

void restoreWifiAfterScan() {
  printWifiScanStatus();
  // La operación local sigue bloqueada durante la restauración.
  const bool modeOk = WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(scanPreviousAutoReconnect);
  nextWifiAttemptAt = millis() + WIFI_RETRY_INTERVAL_MS;
  const int beginStatus = modeOk ? static_cast<int>(WiFi.begin(WIFI_SSID,WIFI_PASSWORD)) : -1;
  Serial.printf("[wifi scan] Restauración: STA=%s, begin=%d, autoReconnect=%s. Esperando evento de IP.\n",
                modeOk ? "OK" : "ERROR", beginStatus, scanPreviousAutoReconnect ? "sí" : "no");
  wifiScanActive = false;
}

void serviceWifiScan() {
  if (!wifiScanActive) {
    // Tras timeout, no reutilizar el callback de un escaneo anterior.
    if (scanPending && scanDone) {
      Serial.printf("[wifi scan] Callback tardío: STATUS=%d; descartado.\n", scanSdkResult);
      scanPending = false;
    }
    return;
  }
  if (!scanDone) {
    if (millis() - scanStartedAt < 30000) return;
    Serial.println("[wifi scan] TIMEOUT: no llegó callback SDK; resultado indeterminado, no equivale a cero redes.");
    restoreWifiAfterScan();
    return;
  }
  scanPending = false;
  if (scanSdkResult != OK || scanInterrupted || WiFi.getMode() != WIFI_STA) {
    Serial.printf("[wifi scan] FALLIDO/INTERRUMPIDO: STATUS=%d, asociación durante escaneo=%s. No interpretar como cero redes.\n",
                  scanSdkResult, scanInterrupted ? "sí" : "no");
  } else {
    Serial.printf("[wifi scan] ÉXITO SDK: STATUS=%d, redes 2,4 GHz=%u, coincidencias del SSID configurado=%u.\n",
                  scanSdkResult, scanTotal, scanMatchCount);
    for (unsigned i=0; i<scanMatchCount && i<8; ++i)
      Serial.printf("[wifi scan] Coincidencia %u: RSSI=%d dBm, canal=%d, seguridad=%s (SDK=%d).\n",
                    i+1, scanMatches[i].rssi, scanMatches[i].channel,
                    wifiSecurityName(scanMatches[i].security), scanMatches[i].security);
    if (scanTotal == 0) Serial.println("[wifi scan] Escaneo exitoso sin redes visibles; no es un error SDK.");
    else if (scanMatchCount == 0) Serial.println("[wifi scan] Hay redes, pero ninguna anuncia el SSID configurado; considerar SSID oculto.");
    if (scanMatchCount > 8) Serial.println("[wifi scan] Se muestran las primeras 8 coincidencias.");
  }
  restoreWifiAfterScan();
}

void startWifiScan() {
  if (wifiScanActive || scanPending) { Serial.println("[wifi scan] Escaneo anterior aún en curso; no se inicia otro."); return; }
  if (operationStage != OperationStage::Idle || !queueCommands.empty() || servoMotion.active) {
    Serial.println("[wifi scan] Rechazado: hay operación, comandos reclamados o movimiento de servo.");
    return;
  }
  printWifiScanStatus();
  wifiScanActive = true;
  scanDone = false;
  scanInterrupted = false;
  scanPreviousAutoReconnect = WiFi.getAutoReconnect();
  WiFi.setAutoReconnect(false);
  // No usar WiFi.disconnect(): su valor por defecto puede borrar credenciales.
  const bool disconnected = wifi_station_disconnect();
  wifiAssociated = false;
  wifiWasConnected = false;
  const bool modeOk = WiFi.mode(WIFI_STA) && WiFi.getMode() == WIFI_STA;
  Serial.printf("[wifi scan] Pausa controlada: disconnect=%s, STA=%s; reintentos suspendidos.\n",
                disconnected ? "OK" : "ERROR", modeOk ? "OK" : "ERROR");
  if (!disconnected || !modeOk) {
    Serial.println("[wifi scan] Preparación fallida; no se realizó escaneo.");
    restoreWifiAfterScan();
    return;
  }
  static scan_config config;
  memset(&config, 0, sizeof(config));
  config.show_hidden = true;
  scanStartedAt = millis();
  scanPending = true;
  if (!wifi_station_scan(&config, wifiScanFinished)) {
    scanPending = false;
    Serial.println("[wifi scan] SDK rechazó iniciar el escaneo; no equivale a cero redes.");
    restoreWifiAfterScan();
  }
}

void printHelp() {
  Serial.println("wifi scan: escaneo puntual de la red configurada (sin operación activa).");
  Serial.println("Comandos serie (115200): help | status | diag on|off");
  Serial.println("servo entry|exit open|close | sensor entry|exit | sensors on|off");
  Serial.println("traffic red|green | white on|off | rgb red|green | ldr | buzzer [duración_ms [frecuencia_hz]] | led test entry|exit");
}

void handleSerialCommand(String line) {
  line.trim(); line.toLowerCase();
  if (line.isEmpty()) return;
  if (line == "help") { printHelp(); return; }
  if (line == "wifi scan") { startWifiScan(); return; }
  if (line == "status") {
    Serial.printf("WiFi=%s RSSI=%d dBm hora=%s PCA=%s modo=%s operación=%u cola=%u entryIR=%s exitIR=%s LDR=%d\n",
      WiFi.status()==WL_CONNECTED ? "conectado":"desconectado", WiFi.RSSI(), clockIsValid()?"sincronizada":"no sincronizada",
      pcaReady?"OK":"error", diagnosticMode?"diagnóstico":"Supabase", static_cast<unsigned>(operationStage), static_cast<unsigned>(queueCommands.size()),
      digitalRead(PIN_ENTRY_IR)==LOW?"obstáculo":"libre", digitalRead(PIN_EXIT_IR)==LOW?"obstáculo":"libre", analogRead(A0));
    return;
  }
  if (line == "diag on") {
    if (operationStage != OperationStage::Idle || !queueCommands.empty()) { Serial.println("No se activa diagnóstico con operación activa o comandos ya reclamados."); return; }
    diagnosticMode = true;
    allDiagnosticsOff();
    Serial.println("Modo diagnóstico local activo; no se reclaman comandos ni se crean operaciones.");
    return;
  }
  if (line == "diag off") {
    stopDiagnosticTone();
    buzzerUntil = 0;
    diagnosticMode = false;
    restoreIdleRgb();
    setWhiteLights(ldrNight);
    Serial.println("Diagnóstico apagado; se reanuda sondeo Supabase.");
    return;
  }
  if (!diagnosticMode) { Serial.println("Activá primero diag on. Los comandos de diagnóstico no funcionan en modo Supabase."); return; }
  if (!pcaReady && (line.startsWith("traffic ") || line.startsWith("white ") || line.startsWith("rgb ") || line.startsWith("servo "))) {
    Serial.println("PCA9685 no responde; revisar alimentación, GND, SDA/SCL.");
    return;
  }

  if (line == "sensor entry" || line == "sensor exit") {
    const uint8_t pin = line.endsWith("entry") ? PIN_ENTRY_IR : PIN_EXIT_IR;
    Serial.printf("Sensor %s: %s (LOW=obstáculo, HIGH=libre).\n", line.endsWith("entry")?"entrada":"salida", digitalRead(pin)==LOW?"LOW/obstáculo":"HIGH/libre");
  } else if (line == "sensors on") { diagSensorStream=true; nextDiagSensorAt=0; Serial.println("Lectura periódica de sensores activa."); }
  else if (line == "sensors off") { diagSensorStream=false; Serial.println("Lectura periódica detenida."); }
  else if (line == "traffic red") { pcaSetOn(PCA_TRAFFIC_RED); pcaSetOff(PCA_TRAFFIC_GREEN); }
  else if (line == "traffic green") { pcaSetOff(PCA_TRAFFIC_RED); pcaSetOn(PCA_TRAFFIC_GREEN); }
  else if (line == "white on") setWhiteLights(true);
  else if (line == "white off") setWhiteLights(false);
  else if (line == "rgb red") setRgb(RgbColor::Red);
  else if (line == "rgb green") setRgb(RgbColor::Green);
  else if (line == "ldr") Serial.printf("A0=%d (umbral bajo=%d / alto=%d; polaridad oscura %s).\n", analogRead(A0), LDR_NIGHT_THRESHOLD, LDR_DAY_THRESHOLD, LDR_DARK_WHEN_LOW?"LOW":"HIGH");
  else if (line == "buzzer" || line.startsWith("buzzer ")) {
    int duration = 120;
    uint16_t frequency = DIAGNOSTIC_BUZZER_FREQUENCY_HZ;
    String args = line.substring(6);
    args.trim();
    if (!args.isEmpty()) {
      const int separator = args.indexOf(' ');
      if (separator < 0) {
        duration = constrain(args.toInt(), 20, 2000);
      } else {
        const String durationArg = args.substring(0, separator);
        String frequencyArg = args.substring(separator + 1);
        frequencyArg.trim();
        if (durationArg.isEmpty() || frequencyArg.isEmpty() || frequencyArg.indexOf(' ') >= 0) {
          Serial.println("Usá buzzer [duración_ms [frecuencia_hz]].");
          return;
        }

        bool frequencyIsInteger = true;
        for (size_t i = 0; i < frequencyArg.length(); ++i) {
          if (!isDigit(frequencyArg[i])) { frequencyIsInteger = false; break; }
        }
        const long parsedFrequency = frequencyArg.toInt();
        if (!frequencyIsInteger || parsedFrequency < DIAGNOSTIC_BUZZER_MIN_FREQUENCY_HZ
            || parsedFrequency > DIAGNOSTIC_BUZZER_MAX_FREQUENCY_HZ) {
          Serial.printf("Frecuencia inválida; usá entre %u y %u Hz.\n",
                        DIAGNOSTIC_BUZZER_MIN_FREQUENCY_HZ, DIAGNOSTIC_BUZZER_MAX_FREQUENCY_HZ);
          return;
        }
        duration = constrain(durationArg.toInt(), 20, 2000);
        frequency = static_cast<uint16_t>(parsedFrequency);
      }
    }
    startDiagnosticTone(static_cast<uint16_t>(duration), frequency);
  } else if (line == "led test entry" || line == "led test exit") {
    if (ledTestRemaining) { Serial.println("Ya hay una prueba del LED en curso."); return; }
    ledTestEntry=line.endsWith("entry");
    ledTestRemaining=static_cast<uint8_t>((ledTestEntry?2:3)*2);
    setBuiltinLed(true);
    ledTestNextAt=millis()+130;
    Serial.printf("Prueba LED %s iniciada; es diagnóstico y no representa barrera actuada.\n",ledTestEntry?"entrada":"salida");
  } else if (line.startsWith("servo ")) {
    if (servoMotion.active) { Serial.println("Ya hay un movimiento servo; esperá a que termine."); return; }
    const bool entry=line.indexOf("entry")>=0;
    if (!entry && line.indexOf("exit")<0) { Serial.println("Usá servo entry|exit open|close."); return; }
    const uint8_t channel=entry?PCA_SERVO_ENTRY:PCA_SERVO_EXIT;
    if (line.endsWith("open")) startServoMove(channel, entry?ENTRY_OPEN_US:EXIT_OPEN_US);
    else if (line.endsWith("close")) startServoMove(channel, entry?ENTRY_CLOSED_US:EXIT_CLOSED_US);
    else Serial.println("Usá servo entry|exit open|close.");
  } else Serial.println("Comando desconocido; escribí help.");
}

void serviceSerial(uint32_t now) {
  while (Serial.available()) {
    const char c=static_cast<char>(Serial.read());
    if (c=='\n' || c=='\r') { if (!serialLine.isEmpty()) { handleSerialCommand(serialLine); serialLine=""; } }
    else if (serialLine.length()<100) serialLine += c;
  }
  if (diagnosticMode && diagSensorStream && due(now,nextDiagSensorAt)) {
    Serial.printf("[sensores] entry=%s exit=%s\n", digitalRead(PIN_ENTRY_IR)==LOW?"LOW/obstáculo":"HIGH/libre", digitalRead(PIN_EXIT_IR)==LOW?"LOW/obstáculo":"HIGH/libre");
    nextDiagSensorAt=now+250;
  }
  if (ledTestRemaining && due(now,ledTestNextAt)) {
    setBuiltinLed(!builtinLedOn);
    --ledTestRemaining;
    ledTestNextAt=now+130;
    if (!ledTestRemaining) { setBuiltinLed(false); Serial.println("Prueba LED integrada completada; no se envió operación vehicular."); }
  }
  if (diagnosticMode && operationStage == OperationStage::Idle) serviceServo(now);
}

void registerWifiEvents() {
  // Conservar los handlers durante toda la ejecución: destruirlos desuscribe eventos.
  wifiConnectedHandler = WiFi.onStationModeConnected([](const WiFiEventStationModeConnected &) {
    wifiAssociated = true;
    if (wifiScanActive) scanInterrupted = true;
    Serial.println("[WiFi] Asociado al punto de acceso; esperando IP por DHCP.");
  });
  wifiDisconnectedHandler = WiFi.onStationModeDisconnected([](const WiFiEventStationModeDisconnected &event) {
    lastWifiDisconnectReason = static_cast<int>(event.reason);
    wifiAssociated = false;
    nextWifiAttemptAt = millis() + WIFI_RETRY_INTERVAL_MS;
    Serial.printf("[WiFi] Desconexión: motivo=%u, estado=%d, contexto=%s.\n",
                  static_cast<unsigned>(event.reason), static_cast<int>(WiFi.status()),
                  wifiScanActive ? "escaneo controlado" : "conexión normal");
  });
  wifiGotIpHandler = WiFi.onStationModeGotIP([](const WiFiEventStationModeGotIP &event) {
    Serial.printf("[WiFi] IP=%s, RSSI=%d dBm\n", event.ip.toString().c_str(), WiFi.RSSI());
  });
}

void serviceWifi(uint32_t now) {
  const uint8_t sdkStatus = wifi_station_get_connect_status();
  static int lastSdkStatus = -1;
  if (lastSdkStatus != sdkStatus) {
    lastSdkStatus = sdkStatus;
    Serial.printf("[WiFi] Estado SDK=%u (0=inactivo, 1=conectando, 2=clave rechazada, 3=AP ausente, 4=fallo, 5=IP obtenida).\n", sdkStatus);
  }
  const bool connected=WiFi.status()==WL_CONNECTED;
  if (connected && !wifiWasConnected) {
    wifiWasConnected=true;
    Serial.printf("[WiFi] Conectado; RSSI=%d dBm\n", WiFi.RSSI());
    configTime(0,0,NTP_SERVER_1,NTP_SERVER_2);
  } else if (!connected && wifiWasConnected) {
    wifiWasConnected=false;
    Serial.println("[WiFi] Conexión perdida; se conserva estado de barrera, reconectando.");
  }
  // WL_DISCONNECTED también puede representar una asociación en curso.
  // No interrumpirla ni reiniciar DHCP. El SDK gestiona la reconexión automática.
  const bool retryable = sdkStatus == STATION_IDLE || sdkStatus == STATION_WRONG_PASSWORD ||
                        sdkStatus == STATION_NO_AP_FOUND || sdkStatus == STATION_CONNECT_FAIL;
  const bool retrySafe = !servoMotion.active &&
      (operationStage == OperationStage::Idle || operationStage == OperationStage::AckRunning ||
       operationStage == OperationStage::Failed);
  if (!wifiScanActive && retrySafe && !connected && !wifiAssociated && retryable && due(now,nextWifiAttemptAt)) {
    nextWifiAttemptAt=now+WIFI_RETRY_INTERVAL_MS;
    Serial.println("[WiFi] Reintento tras 30s sin asociación activa.");
    WiFi.begin(WIFI_SSID,WIFI_PASSWORD);
  }
}

} // namespace

void setup() {
  Serial.begin(115200);
  int64_t testEpoch = 0;

bool testOk = parseTimestamp(
  "2026-11-25T22:14:58.414026+00:00",
  testEpoch
);

Serial.printf(
  "[TEST FECHA] valido=%s epoch=%ld esperado=1795644898\n",
  testOk ? "SI" : "NO",
  static_cast<long>(testEpoch)
);
  Serial.println();
  Serial.println("TFC - Estacionamiento / NodeMCU ESP8266 - modo hardware");
  pinMode(LED_BUILTIN,OUTPUT); setBuiltinLed(false);
  pinMode(PIN_ENTRY_IR,INPUT_PULLUP); pinMode(PIN_EXIT_IR,INPUT_PULLUP);
  pinMode(PIN_BUZZER,OUTPUT); digitalWrite(PIN_BUZZER,LOW);
  attachInterrupt(digitalPinToInterrupt(PIN_ENTRY_IR),entrySensorEdge,FALLING);
  attachInterrupt(digitalPinToInterrupt(PIN_EXIT_IR),exitSensorEdge,FALLING);
  if (hasPlaceholder(WIFI_SSID) || hasPlaceholder(WIFI_PASSWORD) || hasPlaceholder(SUPABASE_URL) ||
      hasPlaceholder(SUPABASE_PUBLISHABLE_KEY) || hasPlaceholder(ESP_DEVICE_SECRET)) {
#if defined(TFC_PROFILE_LOCAL)
    Serial.println("[config] Perfil LOCAL con valores de ejemplo/incompletos; no habilitar hardware.");
#else
    Serial.println("[config] Config.h tiene valores incompletos; revise la configuración sin compartir secretos.");
#endif
  }
#if !defined(TFC_PROFILE_LOCAL)
  trustAnchors.append(SUPABASE_ROOT_CA_DER,sizeof(SUPABASE_ROOT_CA_DER));
#endif
  Wire.begin(PIN_I2C_SDA,PIN_I2C_SCL);
  Wire.setClock(100000);
  pcaReady=pcaBegin();
  if (pcaReady) {
    Serial.println("[PCA9685] Detectado/configurado a 50 Hz. Servos sin pulsos al inicio.");
    pcaSetOn(PCA_TRAFFIC_RED); pcaSetOff(PCA_TRAFFIC_GREEN); setRgb(RgbColor::Off); setWhiteLights(false);
  } else Serial.println("[PCA9685] No responde; ninguna operación física será confirmada.");
  WiFi.persistent(false);
  registerWifiEvents();
  const bool wifiModeOk = WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  nextWifiAttemptAt=millis()+WIFI_RETRY_INTERVAL_MS;
  const int wifiBeginStatus = static_cast<int>(WiFi.begin(WIFI_SSID,WIFI_PASSWORD));
  Serial.printf("[WiFi] Arranque: STA=%s, begin=%d\n", wifiModeOk ? "OK" : "ERROR", wifiBeginStatus);
  printWifiScanStatus();
  Serial.println("WiFi iniciando; hora NTP y heartbeats se habilitan al conectar.");
  printHelp();
}

void loop() {
  const uint32_t now=millis();
  serviceSerial(now);
  serviceWifiScan();
  serviceWifi(now);
  serviceBuzzer(now);
  serviceLdr();
  serviceSensorLatches(now);
  // La máquina física y los sensores tienen prioridad; las RPC secundarias
  // pueden ejecutarse en esperas y Failed, pero nunca durante un movimiento servo.
  serviceOperation(now);
  if (WiFi.status()==WL_CONNECTED && !clockIsValid() && due(now,lastClockNoticeAt+5000)) {
    lastClockNoticeAt=now; Serial.println("[NTP] Esperando hora válida; no se realizan RPC hasta validar TLS/vencimientos.");
  }

  const bool wifiConnected = WiFi.status()==WL_CONNECTED;
  const bool clockValid = clockIsValid();
  const bool networkAvailable = !wifiScanActive && !diagnosticMode && wifiConnected && clockValid;
  if (networkAvailable) {
    if (operationStage == OperationStage::Idle && !queueCommands.full() && due(now,nextClaimAt)) {
      nextClaimAt=now+CLAIM_INTERVAL_MS;
      claimCommands();
      if (operationStage == OperationStage::Idle && !queueCommands.empty())
        serviceOperation(millis());
    }

    const bool entryDetected = digitalRead(PIN_ENTRY_IR) == LOW;
    const bool exitDetected = digitalRead(PIN_EXIT_IR) == LOW;
    const bool lightingManual = manualWhiteOverride || manualRgbOverride;
    const bool telemetryChanged = !sensorTelemetryInitialized || entryDetected != lastReportedEntryDetected || exitDetected != lastReportedExitDetected ||
      ldrNight != lastReportedLdrNight || whiteLightsOn != lastReportedWhiteLightsOn || rgbColor != lastReportedRgbColor ||
      lightingManual != lastReportedLightingManual;
    if (TfcSafety::heartbeatAllowed(wifiConnected, clockValid, diagnosticMode,
                                    wifiScanActive, servoMotion.active) &&
        (telemetryChanged || due(millis(),nextHeartbeatAt)) && due(millis(),nextSensorReportRetryAt)) {
      const uint32_t reportAt = millis();
      nextSensorReportRetryAt = reportAt + SENSOR_REPORT_RETRY_MS;
      if (sendSensorTelemetry()) nextHeartbeatAt = reportAt + HEARTBEAT_INTERVAL_MS;
    }

    if (operationStage == OperationStage::Idle && queueCommands.empty() && !servoMotion.active &&
        due(millis(),nextParkingPollAt)) {
      nextParkingPollAt=millis()+PARKING_POLL_INTERVAL_MS;
      pollParkingState();
    }
  }
  yield();
}
