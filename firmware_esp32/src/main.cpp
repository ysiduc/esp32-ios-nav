#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include <WiFi.h>
#include <WiFiServer.h>
#include <WiFiClient.h>
#include <WebSocketsServer.h>
#include <esp_wifi.h>
#include <tcpip_adapter.h>
#include <Preferences.h>
#include <Update.h>
#include "display_ui.h"
#include "ancs_service.h"
#include "cts_service.h"
#include "ams_service.h"

#ifndef FW_VERSION
#define FW_VERSION "2.0.0"
#endif

// ESP32 SoftAP (no Internet):
//  - Port 8081: Non-Blocking Zero-Alloc TCP Binary Stream (0xAA 0xBB lenH lenL jpeg / 0xAA 0xCC lenH lenL json)
//  - Port 8080: Legacy WebSocket fallback (heartbeat disabled so SoftAP never drops)
static WebSocketsServer webSocketServer(8080);
static WiFiServer tcpStreamServer(8081);
static WiFiClient tcpStreamClient;
static uint8_t wsClientNum = 255;
static bool wsConnected = false;
static volatile bool tcpConnected = false;
static volatile uint8_t tcpPendingAcks = 0;
static volatile bool needWifiModeApply = false;
static volatile bool pendingWifiStatusNotify = false;
static volatile bool pendingBleRestart = false;
static unsigned long pendingBleRestartAt = 0;

static Preferences prefs;
static String bleName = "Hoa hướng dương";
static String wifiSsid = "Hoa hướng dương";
static String wifiPass = "12345678";
static bool hotspotMode = false; // false = ESP32 SoftAP, true = STA client (Phone Hotspot)
static String staSsid = "";
static String staPass = "";

static String sanitizeCfgString(String s) {
  s.replace("\"", "");
  s.replace("\\", "");
  return s;
}

static String buildDeviceConfigJson(bool restarting) {
  bool isSta = (hotspotMode && staSsid.length() > 0);
  bool staReady = isSta && (WiFi.status() == WL_CONNECTED);
  String ipStr = isSta ? (staReady ? WiFi.localIP().toString() : "") : "192.168.4.1";
  return "{\"type\":\"DEVICE_CONFIG\",\"ble_name\":\"" + sanitizeCfgString(bleName) +
         "\",\"ssid\":\"" + sanitizeCfgString(wifiSsid) +
         "\",\"pass\":\"" + sanitizeCfgString(wifiPass) +
         "\",\"hotspot_mode\":" + String(hotspotMode ? 1 : 0) +
         ",\"sta_ssid\":\"" + sanitizeCfgString(staSsid) +
         "\",\"sta_pass\":\"" + sanitizeCfgString(staPass) +
         "\",\"mode\":\"" + String(isSta ? "STA" : "AP") +
         "\",\"ip\":\"" + ipStr +
         "\",\"port\":8081,\"tcp\":" + String(tcpConnected ? 1 : 0) +
         ",\"fw_ver\":\"" FW_VERSION "\",\"ota\":1" +
         ",\"restarting\":" + String(restarting ? 1 : 0) + "}";
}

static String buildWifiStatusJson() {
  bool isSta = (hotspotMode && staSsid.length() > 0);
  bool staReady = isSta && (WiFi.status() == WL_CONNECTED);
  String stStr = isSta ? (staReady ? "connected" : "connecting") : "connected";
  String ipStr = isSta ? (staReady ? WiFi.localIP().toString() : "") : "192.168.4.1";
  String gwStr = staReady ? WiFi.gatewayIP().toString() : "";
  String activeSsid = isSta ? staSsid : wifiSsid;
  return "{\"type\":\"WIFI_STATUS\",\"status\":\"" + stStr +
         "\",\"mode\":\"" + String(isSta ? "STA" : "AP") +
         "\",\"ip\":\"" + ipStr +
         "\",\"gw\":\"" + gwStr +
         "\",\"ws\":" + String((wsConnected || tcpConnected) ? 1 : 0) +
         ",\"port\":8081,\"hotspot\":\"" + sanitizeCfgString(activeSsid) + "\"}";
}

// Start SoftAP WITHOUT offering a default gateway/DNS via DHCP, so iOS immediately sees
// "no Internet on this Wi-Fi" and keeps using cellular data without Wi-Fi Assist disconnects.
static void startSoftAp() {
  WiFi.disconnect(true);
  WiFi.softAPdisconnect(true);
  delay(40);
  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(0, 0, 0, 0), IPAddress(255, 255, 255, 0));
  WiFi.softAP(wifiSsid.c_str(), wifiPass.c_str(), 1, 0, 4);
  WiFi.setTxPower(WIFI_POWER_19_5dBm);
  WiFi.setSleep(true); // MUST BE TRUE for WiFi + BLE coexistence

  tcpip_adapter_dhcps_stop(TCPIP_ADAPTER_IF_AP);
  uint8_t offerRouter = 0; // 0 = do NOT offer router (default gateway) option
  tcpip_adapter_dhcps_option(TCPIP_ADAPTER_OP_SET, TCPIP_ADAPTER_ROUTER_SOLICITATION_ADDRESS, &offerRouter, sizeof(offerRouter));
  tcpip_adapter_dhcps_start(TCPIP_ADAPTER_IF_AP);
  Serial.printf("[WiFi AP] SSID '%s' (no GW, local-only), IP %s\n", wifiSsid.c_str(), WiFi.softAPIP().toString().c_str());
}

// Join Phone Personal Hotspot / external Wi-Fi in STA mode so phone keeps 4G/5G SIM Internet
static void startStaHotspot() {
  WiFi.softAPdisconnect(true);
  WiFi.disconnect(false);
  delay(40);
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.setSleep(true); // MUST BE TRUE for WiFi + NimBLE coexistence
  WiFi.setTxPower(WIFI_POWER_19_5dBm);
  if (staPass.length() == 0) {
    WiFi.begin(staSsid.c_str());
  } else {
    WiFi.begin(staSsid.c_str(), staPass.c_str());
  }
  Serial.printf("[WiFi STA] Joining Personal Hotspot SSID='%s' passLen=%d\n", staSsid.c_str(), staPass.length());
}

static void applyActiveWifiMode() {
  if (hotspotMode && staSsid.length() > 0) {
    startStaHotspot();
  } else {
    if (hotspotMode && staSsid.length() == 0) {
      Serial.println("[WiFi STA] Empty Hotspot SSID -> staying in SoftAP mode");
    }
    startSoftAp();
  }
}

// Triple-Buffered Lock-Free Pipeline (Zero Tearing, Zero Malloc) for 28-30 FPS JPEG Stream
static uint8_t bleRxBuf[32768];
static uint8_t framePool[3][32768];
static size_t framePoolLen[3] = {0, 0, 0};
static volatile int8_t latestReadySlot = -1;
static volatile int8_t readingSlot = -1;
static portMUX_TYPE frameMux = portMUX_INITIALIZER_UNLOCKED;

static char tcpJsonBuf[1024];
static volatile size_t tcpJsonLen = 0;
static volatile bool tcpJsonAvailable = false;

static volatile unsigned long lastFrameTime = 0;

static int8_t acquireFreeWriterSlot() {
  portENTER_CRITICAL(&frameMux);
  int8_t slot = -1;
  for (int8_t i = 0; i < 3; i++) {
    if (i != readingSlot && i != latestReadySlot) {
      slot = i;
      break;
    }
  }
  if (slot < 0) {
    slot = (readingSlot == 0) ? 1 : 0;
  }
  portEXIT_CRITICAL(&frameMux);
  return slot;
}

static bool publishCompleteFrameFromWriter(int8_t writerSlot, size_t len) {
  portENTER_CRITICAL(&frameMux);
  const bool overwroteUnread = (latestReadySlot >= 0);
  framePoolLen[writerSlot] = len;
  latestReadySlot = writerSlot;
  portEXIT_CRITICAL(&frameMux);
  return overwroteUnread;
}

static void enqueueTcpAck() {
  portENTER_CRITICAL(&frameMux);
  if (tcpPendingAcks < 8) {
    tcpPendingAcks++;
  }
  portEXIT_CRITICAL(&frameMux);
}

static void resetTcpAcks() {
  portENTER_CRITICAL(&frameMux);
  tcpPendingAcks = 0;
  portEXIT_CRITICAL(&frameMux);
}

static void flushPendingTcpAcks() {
  uint8_t count = 0;
  portENTER_CRITICAL(&frameMux);
  count = tcpPendingAcks;
  tcpPendingAcks = 0;
  portEXIT_CRITICAL(&frameMux);
  if (count == 0) return;
  uint8_t acks[8];
  const uint8_t n = (count > 8) ? 8 : count;
  memset(acks, 'K', n);
  tcpStreamClient.write(acks, n);
}

// =========================================================================
// Lock-Step Wi-Fi TCP OTA Firmware Update Pipeline (0xAA 0xE0..0xE3)
// tcpStreamTask reads packets into otaRxBuf; loop() exclusively owns Update & TFT.
// =========================================================================
static uint8_t otaRxBuf[8192];
static volatile bool otaActive = false;
static volatile uint8_t otaCmdType = 0; // 0xE0=BEGIN, 0xE1=DATA, 0xE2=END, 0xE3=ABORT, 0xE4=DISCONNECT
static volatile size_t otaRxLen = 0;
static volatile uint8_t otaRespBuf[2] = {0, 0};
static volatile uint8_t otaRespLen = 0;
static size_t otaTotalSize = 0;
static size_t otaWritten = 0;
static unsigned long otaLastActivityMs = 0;
static unsigned long otaLastUiUpdateMs = 0;
static char otaLabel[64] = "";
static bool otaRestartPending = false;
static unsigned long otaRestartAt = 0;
static unsigned long otaErrorHoldUntil = 0;

static void enqueueOtaResp(uint8_t b1, uint8_t b2 = 0) {
  portENTER_CRITICAL(&frameMux);
  otaRespBuf[0] = b1;
  otaRespBuf[1] = b2;
  otaRespLen = (b2 != 0) ? 2 : 1;
  portEXIT_CRITICAL(&frameMux);
}

static void resetOtaResp() {
  portENTER_CRITICAL(&frameMux);
  otaRespLen = 0;
  portEXIT_CRITICAL(&frameMux);
}

static void flushPendingOtaResp() {
  uint8_t buf[2] = {0, 0};
  uint8_t len = 0;
  portENTER_CRITICAL(&frameMux);
  len = otaRespLen;
  if (len > 0) {
    buf[0] = otaRespBuf[0];
    buf[1] = otaRespBuf[1];
    otaRespLen = 0;
  }
  portEXIT_CRITICAL(&frameMux);
  if (len > 0 && tcpStreamClient && tcpStreamClient.connected()) {
    tcpStreamClient.write(buf, len);
  }
}

static uint8_t currentBleFrameId = 255;
static size_t bleJpegBytesReceived = 0;

// UUIDs for Custom Navigation Service
static NimBLEUUID navServiceUUID("0000FFE0-0000-1000-8000-00805F9B34FB");
static NimBLEUUID navCharUUID("0000FFE1-0000-1000-8000-00805F9B34FB");

#if defined(DISPLAY_OLED_SSD1306)
U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2(U8G2_R0, /* reset=*/ U8X8_PIN_NONE, /* clock=*/ 22, /* data=*/ 21);
#elif defined(DISPLAY_TFT_ST7789)
TFT_eSPI tft = TFT_eSPI();
U8g2_for_TFT_eSPI u8f;
TFT_eSprite marqueeSpr = TFT_eSprite(&tft);
U8g2_for_TFT_eSPI u8f_marquee;
#include <TJpg_Decoder.h>
bool g_clipMapOnly = false;
int16_t g_clipX = 6, g_clipY = 8, g_clipW = 144, g_clipH = 224;
bool g_skipNavPopup = false;
bool tft_output(int16_t x, int16_t y, uint16_t w, uint16_t h, uint16_t* bitmap) {
  if (y >= tft.height() || x >= tft.width()) return 1;
  if (g_clipMapOnly && (x + (int16_t)w <= g_clipX || x >= g_clipX + g_clipW || y + (int16_t)h <= g_clipY || y >= g_clipY + g_clipH)) return 1;
  if (g_skipNavPopup && x >= 144 && y >= 24 && y < 72) return 1;
  tft.pushImage(x, y, w, h, bitmap);
  return 1;
}
#endif

DisplayManager display;
NimBLEServer* pServer = nullptr;
NimBLECharacteristic* pNavChar = nullptr;

// Navigation & Telemetry State
volatile bool bleConnected = false;
volatile uint8_t curTurn = 6; // Turn Left
volatile uint16_t curDist = 209;
volatile uint16_t curTotalDist = 300;
volatile uint8_t curSpeed = 0;
volatile uint8_t curEta = 1;
volatile int curHeading = 0;
String curStreet = "CAU SONG LU";
String curArrival = "18:26";
String curClock = "18:25";
uint8_t curBattery = 89;

// ANCS / Notification State
String popupTitle = "";
String popupMsg = "";
String popupType = "NONE";
unsigned long popupExpire = 0;

// State machine for strictly sequential Apple GATT discovery (CTS -> AMS -> ANCS)
enum AppleDiscState {
  APPLE_DISC_IDLE = 0,
  APPLE_DISC_START_CTS,
  APPLE_DISC_WAIT_CTS,
  APPLE_DISC_START_AMS,
  APPLE_DISC_WAIT_AMS,
  APPLE_DISC_START_ANCS,
  APPLE_DISC_WAIT_ANCS,
  APPLE_DISC_COMPLETE
};

static AppleDiscState appleDiscState = APPLE_DISC_IDLE;
static unsigned long appleDiscTimer = 0;
static bool secPending = false;
static unsigned long secPendingTime = 0;
static uint16_t bleConnectedHandle = 0;
static unsigned long bleConnectedTime = 0;

// GAP event handler to monitor connection lifecycle and clean up bonds
static int combinedGapHandler(ble_gap_event *event, void *arg) {
  if (event->type == BLE_GAP_EVENT_ENC_CHANGE) {
    Serial.printf("[BLE] Link encrypted (status=%d, conn_handle=%d)\n",
                  event->enc_change.status, event->enc_change.conn_handle);
    if (event->enc_change.status == 0) {
      secPending = false;
      // Link encrypted and bonded! Start sequential discovery starting with CTS
      appleDiscState = APPLE_DISC_START_CTS;
      appleDiscTimer = millis() + 200;
    } else {
      NimBLEDevice::deleteBond(event->enc_change.conn_handle);
      Serial.printf("[BLE] Link encryption failed (status=%d). Stale bond cleared. If previously bonded, please 'Forget This Device' in iPhone Bluetooth Settings.\n",
                    event->enc_change.status);
    }
  }
  if (event->type == BLE_GAP_EVENT_REPEAT_PAIRING) {
    Serial.printf("[BLE] Repeat pairing request from conn_handle=%d. Resetting bond and retrying...\n",
                  event->repeat_pairing.conn_handle);
    NimBLEDevice::deleteBond(event->repeat_pairing.conn_handle);
    return BLE_GAP_REPEAT_PAIRING_RETRY;
  }
  if (event->type == BLE_GAP_EVENT_DISCONNECT) {
    Serial.printf("[BLE] Disconnected event! reason=0x%04x (HCI 0x%02x)\n",
                  event->disconnect.reason, event->disconnect.reason - 0x200);
  }
  AppleMediaService::handleGapEvent(event, arg);
  AppleNotificationService::handleGapEvent(event, arg);
  AppleCurrentTimeService::handleGapEvent(event, arg);
  return 0;
}

static unsigned long bleDisconnectTime = 0;

// =========================================================================
// 1. BLE Server Callbacks
// =========================================================================
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) {
    bleConnected = true;
    bleDisconnectTime = 0;
    display.setBleConnected(true);
    Serial.printf("[BLE] iPhone connected! conn_handle=%d, enc=%d, bond=%d\n",
                  desc->conn_handle, desc->sec_state.encrypted, desc->sec_state.bonded);

    bleConnectedHandle = desc->conn_handle;
    bleConnectedTime = millis();

    AppleMediaService::connHandle = desc->conn_handle;
    AppleNotificationService::connHandle = desc->conn_handle;
    AppleCurrentTimeService::connHandle = desc->conn_handle;

    // Request Apple-compliant connection parameters (20ms - 40ms interval, 6000ms supervision timeout)
    pServer->updateConnParams(desc->conn_handle, 16, 32, 0, 600);

    // Stop advertising while connected to eliminate 2.4GHz RF collisions with Wi-Fi & BLE link
    NimBLEDevice::stopAdvertising();

    if (desc->sec_state.encrypted) {
      Serial.println("[BLE] Link already encrypted/bonded. Starting Apple sequential discovery...");
      secPending = false;
      appleDiscState = APPLE_DISC_START_CTS;
      appleDiscTimer = millis() + 300;
    } else {
      // Slave security request must be sent 500ms after connection so iOS prompts "Bluetooth Pairing Request"
      Serial.println("[BLE] Link connected (unencrypted). Scheduling slave security request in 500ms...");
      secPending = true;
      secPendingTime = millis() + 500;
      appleDiscState = APPLE_DISC_IDLE;
    }
  }

  void onAuthenticationComplete(ble_gap_conn_desc* desc) {
    Serial.printf("[BLE] Authentication complete! enc=%d, bond=%d\n",
                  desc->sec_state.encrypted, desc->sec_state.bonded);
    if (desc->sec_state.encrypted) {
      secPending = false;
      if (appleDiscState == APPLE_DISC_IDLE) {
        appleDiscState = APPLE_DISC_START_CTS;
        appleDiscTimer = millis() + 200;
      }
    }
  }

  void onDisconnect(NimBLEServer* pServer) {
    bleConnected = false;
    bleConnectedHandle = 0;
    secPending = false;
    appleDiscState = APPLE_DISC_IDLE;
    display.setBleConnected(false);
    bleDisconnectTime = millis();
    AppleMediaService::onDisconnected();
    AppleNotificationService::onDisconnected();
    AppleCurrentTimeService::onDisconnected();
    Serial.println("[BLE] Disconnected. Grace period active (6s)...");
    NimBLEDevice::startAdvertising();
  }
};

// =========================================================================
// 2. Custom Navigation Characteristic Callback (Receives 20 FPS JPEG & JSON)
// =========================================================================
static uint8_t expectedBleChunkIdx = 0;

// Unified JSON Packet Processing for both BLE and WiFi TCP
void processJsonPacket(const char* jsonStr) {
  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, jsonStr);
  if (error) return;

  String typeStr = String(doc["type"] | "");
  if (typeStr == "APP_CONNECT") {
    display.setAppConnected(true);
    if (doc["clock"].is<const char*>()) {
      curClock = String(doc["clock"].as<const char*>());
      display.updateClock(curClock.c_str());
    }
    if (!doc["bat"].isNull()) {
      int b = doc["bat"].as<int>();
      if (b >= 0 && b <= 100) {
        curBattery = (uint8_t)b;
        display.updateBattery(curBattery);
        prefs.begin("nav_state", false);
        prefs.putUChar("bat", curBattery);
        prefs.end();
        Serial.printf("[JSON] APP_CONNECT: Battery updated to %d%%\n", curBattery);
      }
    }
    if (!doc["brightness"].isNull()) {
      int br = doc["brightness"].as<int>();
      display.setBrightness((uint8_t)constrain(br, 5, 100), true);
    }
    if (pNavChar != nullptr && bleConnected) {
      String resp = "{\"type\":\"APP_CONNECT_ACK\",\"status\":\"connected\"}";
      pNavChar->setValue(resp.c_str());
      pNavChar->notify();
      delay(10);
      String cfgResp = buildDeviceConfigJson(false);
      pNavChar->setValue(cfgResp.c_str());
      pNavChar->notify();
      delay(10);
      String stResp = buildWifiStatusJson();
      pNavChar->setValue(stResp.c_str());
      pNavChar->notify();
    }
    Serial.println("[BLE] Received APP_CONNECT handshake. Switched to Navigation screen.");
    return;
  } else if (typeStr == "APP_DISCONNECT") {
    display.setAppConnected(false);
    Serial.println("[BLE] Received APP_DISCONNECT. Returned to Standby screen.");
    return;
  } else if (typeStr == "PING") {
    if (doc["clock"].is<const char*>()) {
      curClock = String(doc["clock"].as<const char*>());
      display.updateClock(curClock.c_str());
    }
    if (!doc["bat"].isNull()) {
      int b = doc["bat"].as<int>();
      if (b >= 0 && b <= 100) {
        curBattery = (uint8_t)b;
        display.updateBattery(curBattery);
        prefs.begin("nav_state", false);
        prefs.putUChar("bat", curBattery);
        prefs.end();
      }
    }
    return;
  } else if (typeStr == "DEL_BG") {
    String target = String(doc["target"] | "all");
    if (target == "wait" || target == "all") {
      if (SPIFFS.exists("/bg_wait.jpg")) SPIFFS.remove("/bg_wait.jpg");
    }
    if (target == "map" || target == "all") {
      if (SPIFFS.exists("/bg_map.jpg")) SPIFFS.remove("/bg_map.jpg");
    }
    display.forceRedraw();
    return;
  } else if (typeStr == "DEVICE_CONFIG" || typeStr == "BLE_CONFIG" || typeStr == "WIFI_CONFIG" || typeStr == "WIFI_QUERY" || typeStr == "DEVICE_QUERY" || typeStr == "SET_HOTSPOT_MODE") {
    bool wifiChanged = false;
    bool bleChanged = false;

    if (doc["ssid"].is<const char*>()) {
      String newSsid = sanitizeCfgString(String(doc["ssid"].as<const char*>()));
      newSsid.trim();
      if (newSsid.length() >= 1 && newSsid.length() <= 31 && newSsid != wifiSsid) {
        wifiSsid = newSsid;
        wifiChanged = true;
      }
    }
    if (doc["pass"].is<const char*>()) {
      String newPass = sanitizeCfgString(String(doc["pass"].as<const char*>()));
      if (newPass.length() >= 8 && newPass.length() <= 63 && newPass != wifiPass) {
        wifiPass = newPass;
        wifiChanged = true;
      }
    }
    if (doc["sta_ssid"].is<const char*>()) {
      String newStaSsid = sanitizeCfgString(String(doc["sta_ssid"].as<const char*>()));
      newStaSsid.trim();
      if (newStaSsid.length() <= 31 && newStaSsid != staSsid) {
        staSsid = newStaSsid;
        wifiChanged = true;
      }
    }
    if (doc["sta_pass"].is<const char*>()) {
      String newStaPass = sanitizeCfgString(String(doc["sta_pass"].as<const char*>()));
      if ((newStaPass.length() == 0 || newStaPass.length() >= 8) && newStaPass.length() <= 63 && newStaPass != staPass) {
        staPass = newStaPass;
        wifiChanged = true;
      }
    }
    if (!doc["hotspot_mode"].isNull()) {
      bool reqHotspot = doc["hotspot_mode"].is<bool>()
          ? doc["hotspot_mode"].as<bool>()
          : (doc["hotspot_mode"].as<int>() != 0);
      if (reqHotspot && staSsid.length() == 0) {
        reqHotspot = false;
      }
      if (reqHotspot != hotspotMode) {
        hotspotMode = reqHotspot;
        wifiChanged = true;
      }
    }

    const char* rawBlePtr = doc["ble_name"].is<const char*>()
        ? doc["ble_name"].as<const char*>()
        : (doc["bleName"].is<const char*>() ? doc["bleName"].as<const char*>() : nullptr);
    if (rawBlePtr != nullptr) {
      String newBle = sanitizeCfgString(String(rawBlePtr));
      newBle.trim();
      if (newBle.length() >= 1 && newBle.length() <= 25 && newBle != bleName) {
        bleName = newBle;
        bleChanged = true;
      }
    }

    if (wifiChanged) {
      prefs.begin("nav_wifi", false);
      prefs.putString("ap_ssid", wifiSsid);
      prefs.putString("ap_pass", wifiPass);
      prefs.putBool("hotspot_mode", hotspotMode);
      prefs.putString("sta_ssid", staSsid);
      prefs.putString("sta_pass", staPass);
      prefs.end();
      Serial.printf("[WiFi] Saved config (mode=%s, ap='%s', sta='%s') -> applying\n",
                    hotspotMode ? "STA" : "AP", wifiSsid.c_str(), staSsid.c_str());
      needWifiModeApply = true;
    }
    if (bleChanged) {
      prefs.begin("nav_cfg", false);
      prefs.putString("ble_name", bleName);
      prefs.end();
      Serial.printf("[BLE] Saved new Bluetooth name '%s' -> scheduling safe reboot\n", bleName.c_str());
      pendingBleRestart = true;
      pendingBleRestartAt = millis() + 450;
    }

    if (pNavChar != nullptr && bleConnected) {
      String cfgResp = buildDeviceConfigJson(bleChanged);
      pNavChar->setValue(cfgResp.c_str());
      pNavChar->notify();
      delay(10);
      String resp = buildWifiStatusJson();
      pNavChar->setValue(resp.c_str());
      pNavChar->notify();
    }
    return;

  } else if (typeStr == "SET_UI_STYLE" || typeStr == "SET_WATCHFACE" || typeStr == "THEME_SELECT") {
    int s = doc["theme"] | doc["style"] | 0;
    display.setWatchfaceStyle((uint8_t)s);
    display.forceShowWatchfaceTheme();
    prefs.begin("nav_state", false);
    prefs.putUChar("theme", (uint8_t)s);
    prefs.end();
    Serial.printf("[JSON] Set Watchface/Theme style: %d and switched display\n", s);
    return;

  } else if (typeStr == "SET_BRIGHTNESS") {
    int br = doc["value"] | doc["brightness"] | 100;
    display.setBrightness((uint8_t)constrain(br, 5, 100), true);
    return;

  } else if (typeStr == "SET_PREVIEW_SCREEN") {
    int scr = doc["screen"] | doc["mode"] | 0;
    display.setPreviewScreenMode((uint8_t)constrain(scr, 0, 2));
    return;

  } else if (typeStr == "SET_MAN2_STYLE" || typeStr == "MAN2_THEME_SELECT") {
    int s = doc["theme"] | doc["style"] | 0;
    display.setIdleMapStyle((uint8_t)s);
    display.setPreviewScreenMode(2);
    Serial.printf("[JSON] Set Man 2 style: %d and switched display\n", s);
    return;

  } else if (typeStr == "EXIT_SIMULATOR" || typeStr == "RESTORE_IDLE_MAP" || typeStr == "MAP_MODE") {
    display.restoreIdleMap();
    return;

  } else if (typeStr == "POPUP" || typeStr == "POPUP_NOTIF" || typeStr == "CALL" || typeStr == "SMS") {
    String app = String(doc["app"] | (typeStr == "CALL" ? "call" : (typeStr == "SMS" ? "sms" : "bell")));
    String title = String(doc["title"] | doc["caller"] | doc["sender"] | "Thông báo");
    String msg = String(doc["msg"] | doc["message"] | doc["phone"] | "");
    bool isCall = (typeStr == "CALL" || app == "call" || doc["isCall"] == true);
    bool isMissed = (title.indexOf("nhỡ") >= 0 || title.indexOf("Missed") >= 0);
    uint32_t dur = (isCall && !isMissed) ? 60000UL : 5000UL;
    display.showNotificationPopup(app.c_str(), title.c_str(), msg.c_str(), isCall, dur);
    return;

  } else if (typeStr == "CALL_END" || typeStr == "DISMISS_POPUP") {
    display.dismissPopup();
    return;
  }

  // Auto-heal app connected state upon receiving active navigation packet
  if (!display.isAppConnected()) {
    display.setAppConnected(true);
  }
  if (!doc["nav"].isNull()) {
    int navVal = doc["nav"].as<int>();
    display.setNavigating(navVal == 1);
  }

  curTurn = doc["turn"] | curTurn;
  curDist = doc["dist"] | curDist;
  curTotalDist = doc["tot_dist"] | doc["tot"] | curTotalDist;
  curSpeed = doc["speed"] | curSpeed;
  curEta = doc["eta"] | curEta;
  if (doc["street"].is<const char*>()) curStreet = String((const char*)doc["street"]);
  if (doc["arrival"].is<const char*>()) {
    curArrival = String((const char*)doc["arrival"]);
  } else if (doc["arr"].is<const char*>()) {
    curArrival = String((const char*)doc["arr"]);
  }
  if (doc["clock"].is<const char*>()) curClock = String((const char*)doc["clock"]);
  if (!doc["bat"].isNull()) {
    int b = doc["bat"].as<int>();
    if (b >= 0 && b <= 100) {
      curBattery = (uint8_t)b;
      display.updateBattery(curBattery);
      prefs.begin("nav_state", false);
      prefs.putUChar("bat", curBattery);
      prefs.end();
    }
  }
  if (doc["head"].is<int>()) curHeading = doc["head"];

  // Dynamically calculate curArrival if not explicitly provided or if still default
  if (curArrival == "18:26" || curArrival.length() == 0) {
    int ch = 0, cm = 0;
    if (sscanf(curClock.c_str(), "%d:%d", &ch, &cm) == 2) {
      int totalMin = ch * 60 + cm + curEta;
      int arrH = (totalMin / 60) % 24;
      int arrM = totalMin % 60;
      char buf[8];
      snprintf(buf, sizeof(buf), "%02d:%02d", arrH, arrM);
      curArrival = String(buf);
    }
  }

  RoutePoint parsedPts[32];
  uint8_t parsedPtCount = 0;
  if (doc["pts"].is<JsonArray>()) {
    JsonArray arr = doc["pts"].as<JsonArray>();
    for (JsonVariant v : arr) {
      if (parsedPtCount >= 32) break;
      if (v.is<JsonArray>() && v.size() >= 2) {
        parsedPts[parsedPtCount].dx = v[0].as<int8_t>();
        parsedPts[parsedPtCount].dy = v[1].as<int8_t>();
        parsedPtCount++;
      }
    }
  }

  bool isNav = doc["nav"].isNull() ? display.isNavigating() : (doc["nav"].as<int>() == 1);
  display.setNavData(curTurn, curDist, curTotalDist, curSpeed, curEta, curStreet.c_str(), curArrival.c_str(), curClock.c_str(), curBattery, parsedPts, parsedPtCount, isNav, curHeading);

  if (doc["song"].is<const char*>() || doc["song"].is<String>()) {
    String curSong = String(doc["song"] | "");
    String curArtist = String(doc["artist"] | "");
    uint16_t el = doc["el"] | 0;
    uint16_t dur = doc["dur"] | 0;
    if (curSong.length() > 0 && curSong != "CHUA PHAT NHAC") {
      display.setSongInfo(curSong.c_str(), curArtist.c_str(), el, dur);
    }
  }
}

// WebSocket Server Event Handler (iPhone connects to ESP32 SoftAP)
void webSocketEvent(uint8_t num, WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_DISCONNECTED:
      if (num == wsClientNum) {
        wsConnected = false;
        wsClientNum = 255;
      }
      Serial.printf("[WebSocket] iPhone #%u disconnected\n", num);
      break;
    case WStype_CONNECTED:
      wsClientNum = num;
      wsConnected = true;
      Serial.printf("[WebSocket] iPhone #%u connected to ESP32 SoftAP\n", num);
      break;
    case WStype_TEXT:
      if (length > 0) {
        processJsonPacket((const char*)payload);
      }
      break;
    case WStype_BIN:
      if (length > 100 && payload[0] == 0xFF && payload[1] == 0xD8 && length <= 32768) {
        int8_t slot = acquireFreeWriterSlot();
        memcpy(framePool[slot], payload, length);
        publishCompleteFrameFromWriter(slot, length);
      }
      break;
    case WStype_ERROR:
      Serial.printf("[WebSocket] Error occurred, len=%d\n", length);
      break;
    default:
      break;
  }
}

class NavCharCallbacks : public NimBLECharacteristicCallbacks {

  void onWrite(NimBLECharacteristic* pCharacteristic) {
    if (otaActive || otaRestartPending) return;
    std::string value = pCharacteristic->getValue();
    if (value.length() == 0) return;

    // 1. Check for Binary Chunked JPEG Packet:
    // Magic 0xAA 0xBB: Live streaming JPEG frame (RAM)
    // Magic 0xAA 0xBC: Uploading custom background for Bluetooth pairing screen (/bg_wait.jpg)
    // Magic 0xAA 0xBD: Uploading custom background for map waiting/idle screen (/bg_map.jpg)
    if (value.length() >= 5 && (uint8_t)value[0] == 0xAA) {
      uint8_t magic2 = (uint8_t)value[1];
      if (magic2 == 0xBB) {
        uint8_t frameId = (uint8_t)value[2];
        uint8_t totalChunks = (uint8_t)value[3];
        uint8_t chunkIdx = (uint8_t)value[4];

        if (chunkIdx == 0) {
          currentBleFrameId = frameId;
          expectedBleChunkIdx = 0;
          bleJpegBytesReceived = 0;
        }

        if (frameId == currentBleFrameId && chunkIdx == expectedBleChunkIdx) {
          size_t payloadLen = value.length() - 5;
          if (bleJpegBytesReceived + payloadLen < sizeof(bleRxBuf)) {
            memcpy(bleRxBuf + bleJpegBytesReceived, value.data() + 5, payloadLen);
            bleJpegBytesReceived += payloadLen;
            expectedBleChunkIdx++;
          }

          if (chunkIdx == totalChunks - 1 && bleJpegBytesReceived > 100) {
            // Check JPEG Start-of-Image magic bytes (0xFF, 0xD8)
            if (bleRxBuf[0] == 0xFF && bleRxBuf[1] == 0xD8 && bleJpegBytesReceived <= 32768) {
              int8_t slot = acquireFreeWriterSlot();
              memcpy(framePool[slot], bleRxBuf, bleJpegBytesReceived);
              publishCompleteFrameFromWriter(slot, bleJpegBytesReceived);
            }
          }
        }
        return;
      } else if (magic2 == 0xBC || magic2 == 0xBD || magic2 == 0xBE || magic2 == 0xBF || magic2 == 0xC0 || magic2 == 0xC1) {
        uint8_t totalChunks = (uint8_t)value[3];
        uint8_t chunkIdx = (uint8_t)value[4];
        size_t payloadLen = value.length() - 5;
        const char* targetPath = (magic2 == 0xBC) ? "/bg_wait.jpg"
                               : (magic2 == 0xBD) ? "/bg_map.jpg"
                               : (magic2 == 0xBE) ? "/custom_theme_bg.jpg"
                               : (magic2 == 0xBF) ? "/custom_theme.json"
                               : (magic2 == 0xC0) ? "/custom_man2_bg.jpg"
                                                  : "/custom_man2.json";

        static File bgUploadFile;
        if (chunkIdx == 0) {
          if (SPIFFS.exists(targetPath)) SPIFFS.remove(targetPath);
          bgUploadFile = SPIFFS.open(targetPath, FILE_WRITE);
          Serial.printf("[SPIFFS] Started uploading %s (%d chunks)\n", targetPath, totalChunks);
        }

        if (bgUploadFile) {
          bgUploadFile.write((const uint8_t*)value.data() + 5, payloadLen);
        }

        if (chunkIdx == totalChunks - 1) {
          if (bgUploadFile) {
            bgUploadFile.flush();
            bgUploadFile.close();
            Serial.printf("[SPIFFS] Finished uploading %s! Saved to flash.\n", targetPath);
          }
          if (magic2 == 0xBE || magic2 == 0xBF) {
            display.markCustomThemeReload();
          } else if (magic2 == 0xC0 || magic2 == 0xC1) {
            display.markMan2ThemeReload();
          } else {
            display.forceRedraw();
          }
        }
        return;
      }
    }

    // 2. JSON Notification or Navigation Telemetry
    processJsonPacket(value.c_str());
  }
};

// =========================================================================
// Dedicated Non-Blocking Persistent TCP Binary Stream Task (Port 8081)
// =========================================================================
static void tcpStreamTask(void* param) {
  (void)param;
  uint8_t rxState = 0; // 0: MAGIC 0xAA, 1: TYPE, 2: LEN_H, 3: LEN_L, 4: PAYLOAD
  uint8_t pktType = 0;
  uint16_t pktLen = 0;
  size_t rxPos = 0;
  int8_t writerSlot = -1;
  bool staWasConnected = false;
  unsigned long staConnectedAt = 0;
  unsigned long lastReverseDialAt = 0;
  unsigned long lastStaRetryAt = 0;

  for (;;) {
    if (needWifiModeApply) {
      needWifiModeApply = false;
      if (tcpStreamClient) tcpStreamClient.stop();
      tcpConnected = false;
      resetTcpAcks();
      resetOtaResp();
      if (otaActive && !otaRestartPending) {
        portENTER_CRITICAL(&frameMux);
        otaCmdType = 0xE4;
        portEXIT_CRITICAL(&frameMux);
      }
      rxState = 0;
      rxPos = 0;
      staWasConnected = false;
      staConnectedAt = 0;
      lastReverseDialAt = 0;
      lastStaRetryAt = millis();
      applyActiveWifiMode();
      tcpStreamServer.begin();
      pendingWifiStatusNotify = true;
    }

    if (hotspotMode && staSsid.length() > 0) {
      wl_status_t st = WiFi.status();
      if (st == WL_CONNECTED) {
        if (!staWasConnected) {
          staWasConnected = true;
          staConnectedAt = millis();
          lastReverseDialAt = millis();
          tcpStreamServer.begin();
          pendingWifiStatusNotify = true;
          Serial.printf("[WiFi STA] Connected! ESP IP=%s Gateway=%s\n",
                        WiFi.localIP().toString().c_str(),
                        WiFi.gatewayIP().toString().c_str());
        } else if (!tcpConnected && !wsConnected &&
                   !tcpStreamServer.hasClient() &&
                   (millis() - staConnectedAt >= 2800) &&
                   (millis() - lastReverseDialAt >= 3000)) {
          lastReverseDialAt = millis();
          IPAddress gw = WiFi.gatewayIP();
          if (gw != IPAddress(0, 0, 0, 0)) {
            WiFiClient revClient;
            if (revClient.connect(gw, 8082, 450)) {
              if (tcpStreamClient) tcpStreamClient.stop();
              tcpStreamClient = revClient;
              tcpStreamClient.setNoDelay(true);
              resetTcpAcks();
              tcpConnected = true;
              rxState = 0;
              rxPos = 0;
              const uint8_t ack = 'K';
              tcpStreamClient.write(&ack, 1);
              Serial.printf("[TCP 8082] Reverse stream connected to Phone Hotspot %s:8082\n",
                            gw.toString().c_str());
            }
          }
        }
      } else {
        if (staWasConnected) {
          staWasConnected = false;
          staConnectedAt = 0;
          if (tcpStreamClient) tcpStreamClient.stop();
          tcpConnected = false;
      resetTcpAcks();
      resetOtaResp();
      if (otaActive && !otaRestartPending) {
        portENTER_CRITICAL(&frameMux);
        otaCmdType = 0xE4;
        portEXIT_CRITICAL(&frameMux);
      }
          rxState = 0;
          rxPos = 0;
          pendingWifiStatusNotify = true;
          Serial.println("[WiFi STA] Hotspot connection lost, retrying...");
        }
        if (millis() - lastStaRetryAt >= 9000) {
          lastStaRetryAt = millis();
          if (staPass.length() == 0) {
            WiFi.begin(staSsid.c_str());
          } else {
            WiFi.begin(staSsid.c_str(), staPass.c_str());
          }
        }
      }
    }

    if (tcpStreamServer.hasClient()) {
      WiFiClient incoming = tcpStreamServer.accept();
      if (incoming) {
        if (tcpStreamClient) tcpStreamClient.stop();
        tcpStreamClient = incoming;
        tcpStreamClient.setNoDelay(true);
        resetTcpAcks();
        tcpConnected = true;
        rxState = 0;
        rxPos = 0;
        const uint8_t ack = 'K';
        tcpStreamClient.write(&ack, 1);
        Serial.println("[TCP 8081] iPhone persistent binary stream connected");
      }
    }

    if (tcpStreamClient && !tcpStreamClient.connected()) {
      tcpStreamClient.stop();
      tcpConnected = false;
      resetTcpAcks();
      resetOtaResp();
      if (otaActive && !otaRestartPending) {
        portENTER_CRITICAL(&frameMux);
        otaCmdType = 0xE4;
        portEXIT_CRITICAL(&frameMux);
      }
      rxState = 0;
      rxPos = 0;
      Serial.println("[TCP 8081] iPhone disconnected");
    }

    if (tcpStreamClient && tcpStreamClient.connected()) {
      flushPendingOtaResp();
      if (!otaActive) {
        flushPendingTcpAcks();
      }

      int loops = 0;
      while (tcpStreamClient.available() > 0 && loops++ < 256) {
        if (rxState == 0) {
          int c = tcpStreamClient.read();
          if (c == 0xAA) rxState = 1;
        } else if (rxState == 1) {
          int c = tcpStreamClient.read();
          if (c < 0) break;
          pktType = (uint8_t)c;
          if (pktType == 0xBB || pktType == 0xCC ||
              pktType == 0xE0 || pktType == 0xE1 || pktType == 0xE2 || pktType == 0xE3) {
            rxState = 2;
          } else if (pktType == 0xDD) {
            if (!otaActive) {
              const uint8_t ack = 'K';
              tcpStreamClient.write(&ack, 1);
            }
            rxState = 0;
          } else if (pktType == 0xAA) {
            rxState = 1;
          } else {
            rxState = 0;
          }
        } else if (rxState == 2) {
          int c = tcpStreamClient.read();
          if (c < 0) break;
          pktLen = ((uint16_t)c) << 8;
          rxState = 3;
        } else if (rxState == 3) {
          int c = tcpStreamClient.read();
          if (c < 0) break;
          pktLen |= (uint8_t)c;
          rxPos = 0;
          const bool validLen =
              (pktType == 0xBB && pktLen > 0 && pktLen <= 32768) ||
              (pktType == 0xCC && pktLen > 0 && pktLen <= 1023) ||
              (pktType == 0xE0 && pktLen > 0 && pktLen <= 512) ||
              (pktType == 0xE1 && pktLen > 0 && pktLen <= sizeof(otaRxBuf)) ||
              ((pktType == 0xE2 || pktType == 0xE3) && pktLen > 0 && pktLen <= 16);
          if (!validLen) {
            rxState = 0;
          } else {
            if (pktType == 0xBB) {
              writerSlot = acquireFreeWriterSlot();
            }
            rxState = 4;
          }
        } else if (rxState == 4) {
          const bool isOtaPkt = (pktType >= 0xE0 && pktType <= 0xE3);
          if (isOtaPkt && otaCmdType != 0) {
            // Wait for main loop() to finish writing the previous OTA chunk to Flash
            break;
          }
          int avail = tcpStreamClient.available();
          if (avail <= 0) break;
          size_t remain = pktLen - rxPos;
          size_t toRead = ((size_t)avail < remain) ? (size_t)avail : remain;
          uint8_t* dst = (pktType == 0xBB)
              ? (framePool[writerSlot] + rxPos)
              : (isOtaPkt ? (otaRxBuf + rxPos) : ((uint8_t*)tcpJsonBuf + rxPos));
          int got = tcpStreamClient.read(dst, toRead);
          if (got > 0) {
            rxPos += (size_t)got;
          } else {
            break;
          }
          if (rxPos >= pktLen) {
            if (pktType == 0xBB) {
              if (!otaActive && !otaRestartPending) {
                if (pktLen > 100 && framePool[writerSlot][0] == 0xFF && framePool[writerSlot][1] == 0xD8) {
                  if (publishCompleteFrameFromWriter(writerSlot, pktLen)) {
                    // Superseded an un-drawn queued frame; release 1 credit immediately for 2-frame pipelining.
                    enqueueTcpAck();
                  }
                } else {
                  enqueueTcpAck();
                }
              }
            } else if (pktType == 0xCC) {
              if (!otaActive && !otaRestartPending) {
                tcpJsonBuf[pktLen] = '\0';
                tcpJsonLen = pktLen;
                tcpJsonAvailable = true;
                const uint8_t ack = 'K';
                tcpStreamClient.write(&ack, 1);
              }
            } else if (isOtaPkt) {
              portENTER_CRITICAL(&frameMux);
              otaRxLen = pktLen;
              otaCmdType = pktType;
              portEXIT_CRITICAL(&frameMux);
            }
            rxState = 0;
            rxPos = 0;
          }
        }
      }

      flushPendingOtaResp();
      if (!otaActive) {
        flushPendingTcpAcks();
      }
    }

    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

// =========================================================================
// Setup & Loop
// =========================================================================
void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("\n=== ESP32-S3 SMART NAVIGATOR (YSIDUCNAGA ST7789 30 FPS) ===");

  // 0. Mount SPIFFS Filesystem for Custom Background Images
  if (!SPIFFS.begin(true)) {
    Serial.println("[SPIFFS] Mount failed, formatted partition.");
  } else {
    Serial.println("[SPIFFS] Filesystem mounted successfully.");
  }

  // Load saved Bluetooth & SoftAP Hotspot credentials from Preferences NVS
  prefs.begin("nav_cfg", true);
  bleName = prefs.getString("ble_name", "Hoa hướng dương");
  prefs.end();
  if (bleName.length() == 0 || bleName == "ysiducnaga") bleName = "Hoa hướng dương";

  prefs.begin("nav_wifi", false);
  wifiSsid = prefs.getString("ap_ssid", "Hoa hướng dương");
  wifiPass = prefs.getString("ap_pass", "12345678");
  hotspotMode = prefs.getBool("hotspot_mode", false);
  staSsid = prefs.getString("sta_ssid", "");
  staPass = prefs.getString("sta_pass", "");
  prefs.end();
  if (wifiSsid.length() == 0 || wifiSsid == "ysiducnaga") wifiSsid = "Hoa hướng dương";
  if (wifiPass.length() < 8) wifiPass = "12345678";
  if (hotspotMode && staSsid.length() == 0) hotspotMode = false;
  Serial.printf("[NVS] BLE='%s' | mode=%s | AP='%s' | STA='%s'\n",
                bleName.c_str(), hotspotMode ? "STA" : "AP", wifiSsid.c_str(), staSsid.c_str());

  // 1. Initialize TJpgDec BEFORE display.init() so any background JPEG drawn during init has a valid callback
  #if defined(DISPLAY_TFT_ST7789)
  TJpgDec.setJpgScale(1);
  TJpgDec.setSwapBytes(true);
  TJpgDec.setCallback(tft_output);
  #endif

  // 2. Start Display (safe to render SPIFFS JPEGs)
  display.init();
#ifdef OTA_TEST_BANNER
  display.drawOtaProgress(100, 1024, 1024, "OTA TEST v" FW_VERSION " OK!", false, true);
  delay(2200);
  display.forceRedraw();
#endif

  // 2. Start NimBLE Server (Max MTU 517 for High-Speed BLE Stream)
  NimBLEDevice::init(bleName.c_str());
  NimBLEDevice::setMTU(517);

  // Security Auth & Bonding for iOS (Required by Apple Media Service & ANCS)
  // bonding = true, mitm = false ("Just Works" - no PIN input needed), sc = true (LE Secure Connections)
  NimBLEDevice::setSecurityAuth(true, false, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setSecurityInitKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setSecurityRespKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setCustomGapHandler(combinedGapHandler);
  AppleMediaService::init();
  AppleNotificationService::init();
  AppleCurrentTimeService::init();

  // Restore last known battery level and clock from flash storage
  prefs.begin("nav_state", true);
  uint8_t savedBat = prefs.getUChar("bat", 0);
  uint8_t savedH = prefs.getUChar("clk_h", 255);
  uint8_t savedM = prefs.getUChar("clk_m", 255);
  prefs.end();
  if (savedBat > 0 && savedBat <= 100) {
    curBattery = savedBat;
  } else {
    curBattery = 85;
  }
  display.updateBattery(curBattery);

  if (savedH < 24 && savedM < 60) {
    display.setTime(savedH, savedM, 0);
    Serial.printf("[NVS] Restored clock from flash: %02d:%02d\n", savedH, savedM);
  }

  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  NimBLEService* pNavService = pServer->createService(navServiceUUID);
  pNavChar = pNavService->createCharacteristic(
    navCharUUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC |
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE_ENC |
    NIMBLE_PROPERTY::NOTIFY
  );
  pNavChar->setCallbacks(new NavCharCallbacks());
  pNavService->start();

  NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();

  // 1. Primary Advertisement Data (Max 31 bytes):
  // Flags: 3 bytes (0x02, 0x01, 0x06)
  // ANCS 128-bit Service Solicitation: 18 bytes (0x11, 0x15, ...UUID...)
  // Total = 21 bytes <= 31 bytes!
  // Placing ANCS Solicitation in advData is REQUIRED by Apple for iOS Settings to recognize the accessory,
  // trigger pairing, and display the "Allow iPhone Notifications" prompt!
  NimBLEAdvertisementData advData;
  advData.setFlags(0x06); // General Discoverable + BR/EDR not supported
  advData.addData((char*)ancsSolicitData, sizeof(ancsSolicitData));
  pAdvertising->setAdvertisementData(advData);

  // 2. Scan Response Data (Max 31 bytes):
  // Complete Local Name: "Hoa hướng dương" (20 UTF-8 bytes + 2B header = 22B)
  // Custom Nav Service: 0xFFE0 (4 bytes) -> Total = 26 bytes <= 31 bytes!
  NimBLEAdvertisementData scanResponseData;
  scanResponseData.setName(bleName.c_str());
  scanResponseData.setCompleteServices(NimBLEUUID((uint16_t)0xFFE0));
  pAdvertising->setScanResponseData(scanResponseData);

  pAdvertising->setMinInterval(16); // 10ms fast advertising
  pAdvertising->setMaxInterval(32); // 20ms
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  // 3. Start active Wi-Fi mode (SoftAP or STA Personal Hotspot) + Non-Blocking TCP Stream (8081) + WebSocket fallback (8080)
  applyActiveWifiMode();
  tcpStreamServer.begin();
  xTaskCreatePinnedToCore(tcpStreamTask, "tcpStreamTask", 4096, nullptr, 2, nullptr, 1);

  webSocketServer.begin();
  webSocketServer.onEvent(webSocketEvent);
  webSocketServer.disableHeartbeat();

  Serial.printf("[BLE & WiFi] '%s' ready (%s mode) on TCP 8081 / WS 8080!\n",
                bleName.c_str(), hotspotMode ? "Hotspot STA" : "SoftAP");
}

static bool handleOtaInLoop() {
  if (otaRestartPending) {
    if (millis() >= otaRestartAt) {
      otaRestartPending = false;
      Serial.println("[OTA] Rebooting into updated firmware...");
      delay(60);
      ESP.restart();
    }
    return true;
  }

  uint8_t cmd = 0;
  size_t len = 0;
  portENTER_CRITICAL(&frameMux);
  cmd = otaCmdType;
  len = otaRxLen;
  portEXIT_CRITICAL(&frameMux);

  if (cmd == 0xE0) {
    char jsonBuf[513];
    size_t copyLen = (len < 512) ? len : 512;
    memcpy(jsonBuf, otaRxBuf, copyLen);
    jsonBuf[copyLen] = '\0';

    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, jsonBuf);
    size_t fwSize = err ? 0 : (size_t)(doc["size"] | 0);
    String md5Str = err ? String("") : String(doc["md5"] | "");
    String verStr = err ? String("") : String(doc["ver"] | "");
    String nameStr = err ? String("") : String(doc["name"] | "firmware.bin");

    if (otaActive) {
      Update.abort();
      otaActive = false;
    }

    if (fwSize < 65536 || fwSize > 3342336) {
      Serial.printf("[OTA] Reject invalid firmware size: %u\n", (unsigned)fwSize);
      portENTER_CRITICAL(&frameMux);
      otaCmdType = 0;
      portEXIT_CRITICAL(&frameMux);
      enqueueOtaResp('E', '1');
      display.drawOtaProgress(0, 0, fwSize, "Kích thước firmware không hợp lệ", true, false);
      otaErrorHoldUntil = millis() + 2500UL;
      return true;
    }

    if (!Update.begin(fwSize, U_FLASH)) {
      Serial.printf("[OTA] Update.begin(%u) failed: %s\n", (unsigned)fwSize, Update.errorString());
      portENTER_CRITICAL(&frameMux);
      otaCmdType = 0;
      portEXIT_CRITICAL(&frameMux);
      enqueueOtaResp('E', '1');
      display.drawOtaProgress(0, 0, fwSize, "Không mở được phân vùng OTA", true, false);
      otaErrorHoldUntil = millis() + 2500UL;
      return true;
    }

    md5Str.trim();
    md5Str.toLowerCase();
    if (md5Str.length() == 32) {
      Update.setMD5(md5Str.c_str());
    }

    if (verStr.length() > 0) {
      snprintf(otaLabel, sizeof(otaLabel), "Phiên bản %s (%u KB)",
               verStr.c_str(), (unsigned)((fwSize + 512) / 1024));
    } else {
      snprintf(otaLabel, sizeof(otaLabel), "%s (%u KB)",
               nameStr.c_str(), (unsigned)((fwSize + 512) / 1024));
    }

    otaTotalSize = fwSize;
    otaWritten = 0;
    otaLastActivityMs = millis();
    otaLastUiUpdateMs = 0;
    otaErrorHoldUntil = 0;
    otaActive = true;
    // Discard any pending JPEG frame while OTA owns the display
    portENTER_CRITICAL(&frameMux);
    latestReadySlot = -1;
    otaCmdType = 0;
    portEXIT_CRITICAL(&frameMux);

    display.forceRedraw();
    display.drawOtaProgress(0, 0, otaTotalSize, otaLabel, false, false);
    enqueueOtaResp('O');
    Serial.printf("[OTA] Begin: size=%u md5=%s label='%s'\n",
                  (unsigned)fwSize, md5Str.c_str(), otaLabel);
    return true;

  } else if (cmd == 0xE1) {
    if (!otaActive) {
      portENTER_CRITICAL(&frameMux);
      otaCmdType = 0;
      portEXIT_CRITICAL(&frameMux);
      enqueueOtaResp('E', '5');
      return false;
    }
    size_t written = Update.write(otaRxBuf, len);
    portENTER_CRITICAL(&frameMux);
    otaCmdType = 0;
    portEXIT_CRITICAL(&frameMux);

    if (written != len) {
      Serial.printf("[OTA] Update.write failed (%u/%u): %s\n",
                    (unsigned)written, (unsigned)len, Update.errorString());
      Update.abort();
      otaActive = false;
      enqueueOtaResp('E', '2');
      display.drawOtaProgress(0, otaWritten, otaTotalSize, "Lỗi ghi bộ nhớ Flash", true, false);
      otaErrorHoldUntil = millis() + 2500UL;
      return true;
    }

    otaWritten += written;
    otaLastActivityMs = millis();
    uint8_t pct = (otaTotalSize > 0)
        ? (uint8_t)((uint64_t)otaWritten * 100ULL / (uint64_t)otaTotalSize)
        : 0;
    if (pct > 100) pct = 100;
    if (pct == 100 || (millis() - otaLastUiUpdateMs >= 180UL)) {
      otaLastUiUpdateMs = millis();
      display.drawOtaProgress(pct, otaWritten, otaTotalSize, otaLabel, false, false);
    }
    enqueueOtaResp('O');
    return true;

  } else if (cmd == 0xE2) {
    size_t expectedEndSize = otaTotalSize;
    if (len >= 4) {
      expectedEndSize = ((size_t)otaRxBuf[0] << 24) |
                        ((size_t)otaRxBuf[1] << 16) |
                        ((size_t)otaRxBuf[2] << 8) |
                        (size_t)otaRxBuf[3];
    }
    portENTER_CRITICAL(&frameMux);
    otaCmdType = 0;
    portEXIT_CRITICAL(&frameMux);

    if (!otaActive) {
      enqueueOtaResp('E', '5');
      return false;
    }
    if (otaWritten != otaTotalSize || otaWritten != expectedEndSize) {
      Serial.printf("[OTA] Size mismatch: written=%u expected=%u/%u\n",
                    (unsigned)otaWritten, (unsigned)otaTotalSize, (unsigned)expectedEndSize);
      Update.abort();
      otaActive = false;
      enqueueOtaResp('E', '4');
      display.drawOtaProgress(0, otaWritten, otaTotalSize, "Thiếu dữ liệu firmware", true, false);
      otaErrorHoldUntil = millis() + 2500UL;
      return true;
    }
    if (!Update.end(false)) {
      Serial.printf("[OTA] Update.end failed (MD5/verify): %s\n", Update.errorString());
      Update.abort();
      otaActive = false;
      enqueueOtaResp('E', '3');
      display.drawOtaProgress(0, otaWritten, otaTotalSize, "Sai mã kiểm tra MD5", true, false);
      otaErrorHoldUntil = millis() + 2500UL;
      return true;
    }

    otaActive = false;
    otaRestartPending = true;
    otaRestartAt = millis() + 750UL;
    display.drawOtaProgress(100, otaTotalSize, otaTotalSize, otaLabel, false, true);
    enqueueOtaResp('R');
    Serial.printf("[OTA] Success (%u bytes verified)! Reboot scheduled.\n", (unsigned)otaWritten);
    return true;

  } else if (cmd == 0xE3 || cmd == 0xE4) {
    portENTER_CRITICAL(&frameMux);
    otaCmdType = 0;
    portEXIT_CRITICAL(&frameMux);
    if (otaActive) {
      Update.abort();
      otaActive = false;
      Serial.printf("[OTA] Aborted (reason=0x%02X)\n", cmd);
      display.forceRedraw();
    }
    if (cmd == 0xE3) {
      enqueueOtaResp('A');
    }
    return false;
  }

  if (otaActive) {
    if (millis() - otaLastActivityMs > 20000UL) {
      Serial.println("[OTA] Inactivity timeout (>20s) -> aborting cleanly");
      Update.abort();
      otaActive = false;
      display.drawOtaProgress(0, otaWritten, otaTotalSize, "Quá thời gian kết nối", true, false);
      otaErrorHoldUntil = millis() + 2500UL;
    }
    return true;
  }

  if (otaErrorHoldUntil > 0) {
    if (millis() < otaErrorHoldUntil) {
      return true;
    }
    otaErrorHoldUntil = 0;
    display.forceRedraw();
  }
  return false;
}

void loop() {
  // Handle deferred reboot after custom BLE name save
  if (pendingBleRestart && millis() >= pendingBleRestartAt) {
    pendingBleRestart = false;
    Serial.println("[BLE] Rebooting to apply new Bluetooth name...");
    delay(50);
    ESP.restart();
  }

  // Exclusive OTA Flash update loop (pauses map streaming & HUD updates safely)
  if (handleOtaInLoop()) {
    delay(1);
    return;
  }

  // Safely push deferred Wi-Fi mode/IP change notifications from main loop thread
  if (pendingWifiStatusNotify) {
    pendingWifiStatusNotify = false;
    if (pNavChar != nullptr && bleConnected) {
      String resp = buildWifiStatusJson();
      pNavChar->setValue(resp.c_str());
      pNavChar->notify();
    }
  }

  // Handle any JSON control packet received on TCP 8081 safely on main loop thread
  if (tcpJsonAvailable) {
    char localJson[1024];
    size_t jlen = tcpJsonLen;
    if (jlen >= sizeof(localJson)) jlen = sizeof(localJson) - 1;
    memcpy(localJson, tcpJsonBuf, jlen);
    localJson[jlen] = '\0';
    tcpJsonAvailable = false;
    processJsonPacket(localJson);
  }

  // 0. Serve legacy WebSocket client if connected on 8080
  webSocketServer.loop();

  // 1. Decode & push latest triple-buffered JPEG Frame on Main thread (zero contention with tcpStreamTask)
  int8_t slotToDraw = -1;
  size_t frameLen = 0;
  portENTER_CRITICAL(&frameMux);
  if (latestReadySlot >= 0) {
    slotToDraw = latestReadySlot;
    readingSlot = slotToDraw;
    frameLen = framePoolLen[slotToDraw];
    latestReadySlot = -1;
    // Release TCP pipeline credit as soon as decode/SPI draw begins so the next frame prepares in parallel.
    if (tcpConnected && tcpPendingAcks < 8) {
      tcpPendingAcks++;
    }
  }
  portEXIT_CRITICAL(&frameMux);

  if (slotToDraw >= 0) {
    uint8_t* frameBuf = framePool[slotToDraw];

    #if defined(DISPLAY_TFT_ST7789)
    // Only draw streamed map/minimap onto ST7789 while app is actively connected (Màn 2 / Màn 3).
    // Never overwrite Màn 1 (STATE_STANDBY_WATCHFACE) when BLE/app disconnected, even if Wi-Fi stays connected.
    if (frameLen > 100 && display.isAppConnected() && display.getCurrentState() != STATE_STANDBY_WATCHFACE) {
      lastFrameTime = millis();
      uint16_t jpgW = 0, jpgH = 0;
      TJpgDec.getJpgSize(&jpgW, &jpgH, frameBuf, frameLen);
      if (jpgW >= 300) {
        display.setFullScreenStream(true);
        g_clipMapOnly = false;
        tft.resetViewport();
        int mapY = (jpgH <= 216) ? 24 : 0;
        g_skipNavPopup = display.isPopupActive() && (display.getCurrentState() == STATE_NAVIGATION);
        TJpgDec.drawJpg(0, mapY, frameBuf, frameLen);
        display.onFrameRendered();
      } else if (jpgW > 0 && !display.isNavigating()) {
        int16_t mx, my, mw, mh, br;
        uint16_t bCol;
        display.getIdleMinimapRect(mx, my, mw, mh, br, bCol);
        display.setFullScreenStream(false);
        if (display.getCurrentState() == STATE_APP_IDLE_MAP) {
          g_clipX = mx; g_clipY = my; g_clipW = mw; g_clipH = mh;
          g_clipMapOnly = true;
          g_skipNavPopup = false;
          tft.setViewport(mx, my, mw, mh, false);
          TJpgDec.drawJpg(mx - (144 - mw) / 2, my - (224 - mh) / 2, frameBuf, frameLen);
          tft.resetViewport();
          g_clipMapOnly = false;
          if (bCol != 0) {
            tft.drawRoundRect(mx - 2, my - 2, mw + 4, mh + 4, br, bCol);
          }
          display.onFrameRendered();
        }
      }
    }
    #endif

    if (wsConnected && wsClientNum != 255) {
      webSocketServer.sendTXT(wsClientNum, "K");
    }

    portENTER_CRITICAL(&frameMux);
    readingSlot = -1;
    portEXIT_CRITICAL(&frameMux);

    webSocketServer.loop();
  }

  // Grace period before dropping to Standby if BLE disconnected
  if (!bleConnected && display.isAppConnected() && bleDisconnectTime > 0 && (millis() - bleDisconnectTime > 6000)) {
    display.setAppConnected(false);
    bleDisconnectTime = 0;
    Serial.println("[BLE] Grace period expired (>6s). Returned to Standby.");
  }

  // 2. Update HUD and status UI
  bool isStreaming = display.isAppConnected() && (wsConnected || tcpConnected) && (millis() - lastFrameTime < 4000);
  display.update(isStreaming);

  // 3. Delayed Security Request execution to prompt iOS native Pairing dialog
  if (secPending && millis() >= secPendingTime) {
    secPending = false;
    if (bleConnected && bleConnectedHandle != 0) {
      Serial.println("[BLE] Requesting security from iPhone (startSecurity) to trigger native Pairing dialog...");
      int rc = NimBLEDevice::startSecurity(bleConnectedHandle);
      Serial.printf("[BLE] NimBLEDevice::startSecurity returned rc=%d\n", rc);
    }
  }

  // 4. Strictly Sequential Apple GATT Discovery State Machine (CTS -> AMS -> ANCS)
  if (bleConnected && bleConnectedHandle != 0) {
    switch (appleDiscState) {
      case APPLE_DISC_START_CTS:
        if (millis() >= appleDiscTimer) {
          if (AppleCurrentTimeService::isSubscribed) {
            appleDiscState = APPLE_DISC_START_AMS;
            appleDiscTimer = millis() + 100;
          } else {
            Serial.println("[BLE State] Step 1/3: Starting CTS (Time) discovery...");
            appleDiscState = APPLE_DISC_WAIT_CTS;
            appleDiscTimer = millis() + 4000;
            AppleCurrentTimeService::startDiscovery(bleConnectedHandle);
          }
        }
        break;

      case APPLE_DISC_WAIT_CTS:
        if (!AppleCurrentTimeService::isDiscovering) {
          Serial.println("[BLE State] CTS completed. Step 2/3: Advancing to AMS...");
          appleDiscState = APPLE_DISC_START_AMS;
          appleDiscTimer = millis() + 100;
        } else if (millis() >= appleDiscTimer) {
          Serial.println("[BLE State] CTS timed out. Step 2/3: Advancing to AMS...");
          AppleCurrentTimeService::isDiscovering = false;
          appleDiscState = APPLE_DISC_START_AMS;
          appleDiscTimer = millis() + 100;
        }
        break;

      case APPLE_DISC_START_AMS:
        if (millis() >= appleDiscTimer) {
          if (AppleMediaService::isSubscribed) {
            appleDiscState = APPLE_DISC_START_ANCS;
            appleDiscTimer = millis() + 100;
          } else {
            Serial.println("[BLE State] Step 2/3: Starting AMS (Music Title) discovery...");
            appleDiscState = APPLE_DISC_WAIT_AMS;
            appleDiscTimer = millis() + 4000;
            AppleMediaService::startDiscovery(bleConnectedHandle);
          }
        }
        break;

      case APPLE_DISC_WAIT_AMS:
        if (!AppleMediaService::isDiscovering) {
          Serial.println("[BLE State] AMS completed. Step 3/3: Advancing to ANCS...");
          appleDiscState = APPLE_DISC_START_ANCS;
          appleDiscTimer = millis() + 100;
        } else if (millis() >= appleDiscTimer) {
          Serial.println("[BLE State] AMS timed out. Step 3/3: Advancing to ANCS...");
          AppleMediaService::isDiscovering = false;
          appleDiscState = APPLE_DISC_START_ANCS;
          appleDiscTimer = millis() + 100;
        }
        break;

      case APPLE_DISC_START_ANCS:
        if (millis() >= appleDiscTimer) {
          if (AppleNotificationService::isSubscribed) {
            appleDiscState = APPLE_DISC_COMPLETE;
          } else {
            Serial.println("[BLE State] Step 3/3: Starting ANCS (Notifications) discovery...");
            appleDiscState = APPLE_DISC_WAIT_ANCS;
            appleDiscTimer = millis() + 6000; // 6s allows user time to tap Allow Notifications on iPhone
            AppleNotificationService::startDiscovery(bleConnectedHandle);
          }
        }
        break;

      case APPLE_DISC_WAIT_ANCS:
        if (!AppleNotificationService::isDiscovering) {
          Serial.println("[BLE State] ANCS completed! All Apple services active & configured.");
          appleDiscState = APPLE_DISC_COMPLETE;
        } else if (millis() >= appleDiscTimer) {
          Serial.println("[BLE State] ANCS timed out. Finalizing discovery.");
          AppleNotificationService::isDiscovering = false;
          appleDiscState = APPLE_DISC_COMPLETE;
        }
        break;

      case APPLE_DISC_COMPLETE:
      case APPLE_DISC_IDLE:
      default:
        break;
    }

    // 5. Periodic Apple Time sync check (once every 60s when connected & subscribed)
    AppleCurrentTimeService::checkPeriodic();
    AppleNotificationService::checkPeriodic();
  }

  // 5. Periodic real-time clock check from SNTP
  static unsigned long lastClockCheck = 0;
  if (millis() - lastClockCheck > 1000) {
    lastClockCheck = millis();
    time_t now = time(nullptr);
    if (now > 100000) {
      struct tm* t = localtime(&now);
      if (t && t->tm_year > 120) {
        char clkBuf[16];
        snprintf(clkBuf, sizeof(clkBuf), "%02d:%02d", t->tm_hour, t->tm_min);
        if (curClock != clkBuf) {
          curClock = clkBuf;
          display.updateClock(clkBuf);
        }
      }
    }
  }

  // 6. Save clock to NVS on minute change so it persists across power cycles
  static uint8_t lastSavedH = 255;
  static uint8_t lastSavedM = 255;
  uint8_t curH = 0, curM = 0;
  display.getClock(curH, curM);
  if (curH != lastSavedH || curM != lastSavedM) {
    lastSavedH = curH;
    lastSavedM = curM;
    prefs.begin("nav_state", false);
    prefs.putUChar("clk_h", curH);
    prefs.putUChar("clk_m", curM);
    prefs.end();
  }

  if (!wsConnected && !tcpConnected) {
    delay(1);
  }
}
