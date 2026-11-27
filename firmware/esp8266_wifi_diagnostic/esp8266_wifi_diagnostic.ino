#include <Arduino.h>
#include <ESP8266WiFi.h>
#include <Wire.h>
#include "Config.h"
extern "C" {
#include <user_interface.h>
}
// Reutilizar Config.h existente mediante -I; no copiar ni publicar credenciales.
#include <Config.h>

char stage = 0;
bool noSleep = false, useIrq = true, useTasks = true, pcaOk = false;
bool scanning = false, scanPending = false, scanDone = false, scanAuto = true;
bool scanInterference = false;
int scanStatus = -1, lastReason = -1;
uint32_t scanAt = 0, nextLog = 0, loops = 0;
volatile uint32_t entryEdges = 0, exitEdges = 0;
struct Match { int rssi, channel, auth; };
Match matches[8];
unsigned networks = 0, matched = 0;
WiFiEventHandler connectedHandler, disconnectedHandler, ipHandler;
String input;

void IRAM_ATTR entryEdge() { ++entryEdges; }
void IRAM_ATTR exitEdge() { ++exitEdges; }

bool writeReg(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(0x40); Wire.write(reg); Wire.write(value);
  return Wire.endTransmission() == 0;
}
bool channel(uint8_t ch, bool high) {
  uint8_t base = 6 + 4 * ch;
  return writeReg(base,0) && writeReg(base+1,high?16:0) &&
         writeReg(base+2,0) && writeReg(base+3,high?0:16);
}
bool initPca() {
  Wire.begin(D2,D1); Wire.setClock(100000);
  Wire.beginTransmission(0x40); Wire.write(0);
  if (Wire.endTransmission(false) != 0 || Wire.requestFrom(uint8_t(0x40),uint8_t(1)) != 1) return false;
  uint8_t mode = Wire.read();
  if (!writeReg(0,(mode & 0x7f)|0x10) || !writeReg(0xfe,121) ||
      !writeReg(0,mode & ~0x10)) return false;
  delay(5);
  if (!writeReg(0,(mode & ~0x10)|0xa0)) return false;
  for (uint8_t i=0;i<16;++i) if (!channel(i,false)) return false;
  return true;
}
void statusLog() {
  noInterrupts();
  uint32_t inEdges = entryEdges, outEdges = exitEdges;
  interrupts();
  Serial.printf("[diag] etapa=%c modo=%u SDK=%u WiFi=%d motivo=%d heap=%u sleep=%u PHY=%u IP=%s RSSI=%d loops=%u IRQ=%u/%u\n",
    stage?stage:'-', unsigned(WiFi.getMode()), wifi_station_get_connect_status(),
    int(WiFi.status()),lastReason,ESP.getFreeHeap(),unsigned(WiFi.getSleepMode()),
    unsigned(WiFi.getPhyMode()),WiFi.localIP().toString().c_str(),WiFi.RSSI(),
    loops,inEdges,outEdges);
  loops=0;
}
void startStage(char selected) {
  if (stage) { Serial.println("Reiniciar la placa para cambiar etapa/opciones."); return; }
  stage=selected;
  Serial.printf("[inicio] etapa=%c sleep=%s IRQ=%s tareas=%s\n",stage,noSleep?"OFF":"default",useIrq?"ON":"OFF",useTasks?"ON":"OFF");
  // Orden del firmware principal: GPIO/IRQ, PCA9685, WiFi.
  if (stage=='C') {
    pinMode(LED_BUILTIN,OUTPUT); digitalWrite(LED_BUILTIN,HIGH);
    pinMode(D5,INPUT_PULLUP); pinMode(D6,INPUT_PULLUP);
    pinMode(D7,OUTPUT); digitalWrite(D7,LOW);
    if (useIrq) {
      attachInterrupt(digitalPinToInterrupt(D5),entryEdge,FALLING);
      attachInterrupt(digitalPinToInterrupt(D6),exitEdge,FALLING);
    }
  }
  if (stage!='A') {
    pcaOk=initPca();
    Serial.printf("[PCA] %s; canales de servo SIN pulsos.\n",pcaOk?"OK":"ERROR");
  }
  if (stage=='C' && pcaOk) {
    channel(2,true); channel(3,false); // Semáforo rojo
    channel(11,false); channel(12,true); // RGB común ánodo: rojo
  }
  // La conexión inicial reproduce las dos llamadas del sketch básico.
  WiFi.persistent(false);
  bool modeOk=WiFi.mode(WIFI_STA);
  if (noSleep) Serial.printf("[sleep] OFF aceptado=%d\n",WiFi.setSleepMode(WIFI_NONE_SLEEP));
  int result=WiFi.begin(WIFI_SSID,WIFI_PASSWORD);
  Serial.printf("[inicio] STA=%d begin=%d; sin temporizador manual de reconexión.\n",modeOk,result);
  statusLog(); nextLog=millis()+5000;
}
void scanCallback(void *result, STATUS resultStatus) {
  scanStatus=int(resultStatus); networks=0; matched=0;
  if (resultStatus==OK) {
    for (const bss_info *ap=static_cast<bss_info *>(result);ap;ap=STAILQ_NEXT(ap,next)) {
      ++networks;
      if (ap->ssid_len!=strlen(WIFI_SSID) || memcmp(ap->ssid,WIFI_SSID,ap->ssid_len)!=0) continue;
      if (matched<8) matches[matched]={ap->rssi,ap->channel,int(ap->authmode)};
      ++matched;
    }
  }
  scanDone=true;
}
void restoreConnection() {
  Serial.printf("[scan] restaurar STA=%d\n",WiFi.mode(WIFI_STA));
  WiFi.setAutoReconnect(scanAuto);
  Serial.printf("[scan] begin=%d\n",int(WiFi.begin(WIFI_SSID,WIFI_PASSWORD)));
  scanning=false;
}
void startScan() {
  if (!stage) { Serial.println("Seleccionar A, B o C primero."); return; }
  if (scanning || scanPending) { Serial.println("Escaneo previo pendiente; no iniciar otro."); return; }
  statusLog();
  scanning=true; scanDone=false; scanInterference=false;
  scanAuto=WiFi.getAutoReconnect(); WiFi.setAutoReconnect(false);
  bool disconnected=wifi_station_disconnect(); // No borra credenciales.
  bool modeOk=WiFi.mode(WIFI_STA) && WiFi.getMode()==WIFI_STA;
  if (!disconnected || !modeOk) { Serial.println("[scan] Preparación FALLIDA."); restoreConnection(); return; }
  static scan_config config;
  memset(&config,0,sizeof(config)); config.show_hidden=true;
  scanAt=millis(); scanPending=true;
  if (!wifi_station_scan(&config,scanCallback)) {
    scanPending=false; Serial.println("[scan] Inicio RECHAZADO por SDK."); restoreConnection();
  } else Serial.println("[scan] Único escaneo SDK iniciado; autoReconnect suspendido.");
}
void serviceScan() {
  if (!scanning) {
    if (scanPending && scanDone) { scanPending=false; Serial.println("[scan] Callback tardío descartado."); }
    return;
  }
  if (!scanDone) {
    if (millis()-scanAt<30000) return;
    Serial.println("[scan] TIMEOUT: no equivale a cero redes."); restoreConnection(); return;
  }
  scanPending=false;
  if (scanStatus!=OK || scanInterference || WiFi.getMode()!=WIFI_STA)
    Serial.printf("[scan] FALLIDO/INTERRUMPIDO STATUS=%d asociación concurrente=%d\n",scanStatus,scanInterference);
  else {
    Serial.printf("[scan] ÉXITO STATUS=%d redes=%u coincidencias SSID configurado=%u\n",scanStatus,networks,matched);
    for (unsigned i=0;i<matched && i<8;++i)
      Serial.printf("[scan] RSSI=%d canal=%d seguridad SDK=%d (0=abierta 1=WEP 2=WPA 3=WPA2 4=mixto)\n",
        matches[i].rssi,matches[i].channel,matches[i].auth);
  }
  restoreConnection(); statusLog();
}
void help() {
  Serial.println("Tras reset: A | B | C (una etapa por arranque).");
  Serial.println("Antes de elegir etapa: sleep off | sleep default | irq off | irq on | tasks off | tasks on");
  Serial.println("Luego: status | wifi scan | help. Reiniciar para comparar otra etapa.");
}
void command(String line) {
  line.trim(); line.toLowerCase();
  if (line=="help") { help(); return; }
  if (line=="status") { statusLog(); return; }
  if (line=="wifi scan") { startScan(); return; }
  if (line=="a" || line=="b" || line=="c") { startStage(char(line[0]-'a'+'A')); return; }
  if (stage) { Serial.println("Opciones solo antes de elegir etapa; reiniciar."); return; }
  if (line=="sleep off") noSleep=true;
  else if (line=="sleep default") noSleep=false;
  else if (line=="irq off") useIrq=false;
  else if (line=="irq on") useIrq=true;
  else if (line=="tasks off") useTasks=false;
  else if (line=="tasks on") useTasks=true;
  else { Serial.println("Comando desconocido."); return; }
  Serial.println("Opción registrada; elegir etapa.");
}
void setup() {
  Serial.begin(115200);
  Serial.printf("\nDiagnóstico independiente TFC; core=%s SDK=%s reset=%s\n",
    ESP.getCoreVersion().c_str(),ESP.getSdkVersion(),ESP.getResetReason().c_str());
  connectedHandler=WiFi.onStationModeConnected([](const WiFiEventStationModeConnected &) {
    if (scanning) scanInterference=true;
    Serial.println("[WiFi] Asociado; esperando DHCP.");
  });
  disconnectedHandler=WiFi.onStationModeDisconnected([](const WiFiEventStationModeDisconnected &event) {
    lastReason=int(event.reason);
    Serial.printf("[WiFi] motivo=%d contexto=%s\n",lastReason,scanning?"escaneo controlado":"normal");
  });
  ipHandler=WiFi.onStationModeGotIP([](const WiFiEventStationModeGotIP &event) {
    Serial.printf("[WiFi] IP=%s RSSI=%d\n",event.ip.toString().c_str(),WiFi.RSSI());
  });
  help();
}
void loop() {
  while (Serial.available()) {
    char c=char(Serial.read());
    if (c=='\r' || c=='\n') { if (input.length()) { command(input); input=""; } }
    else if (input.length()<64) input+=c;
  }
  
if (stage == 'C' && useTasks) {
  static bool night = false;
  static unsigned long lastLdrRead = 0;

  // Leer A0 como máximo una vez cada 200 ms.
  if (millis() - lastLdrRead >= 200) {
    lastLdrRead = millis();

    int reading = analogRead(A0);
    bool next = night;

    if (!night && reading <= 100) next = true;
    else if (night && reading >= 150) next = false;

    if (next != night) {
      if (pcaOk) {
        for (uint8_t i = 4; i <= 10; ++i) {
          channel(i, next);
        }
      }
      night = next;
    }
  }

  // Mantener las lecturas digitales como antes.
  (void)digitalRead(D5);
  (void)digitalRead(D6);
}

  serviceScan();
  ++loops;
  if (stage && int32_t(millis()-nextLog)>=0) { nextLog=millis()+5000; statusLog(); }
  yield();
}
