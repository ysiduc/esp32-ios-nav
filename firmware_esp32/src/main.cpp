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
#include "display_ui.h"
#include "ancs_service.h"
#include "cts_service.h"
#include "ams_service.h"

// ESP32 SoftAP (no Internet):
//  - Port 8081: Non-Blocking Zero-Alloc TCP Binary Stream (0xAA 0xBB lenH lenL jpeg / 0xAA 0xCC lenH lenL json)
//  - Port 8080: Legacy WebSocket fallback (heartbeat disabled so SoftAP never drops)
static WebSocketsServer webSocketServer(8080);
static WiFiServer tcpStreamServer(8081);
static WiFiClient tcpStreamClient;
static uint8_t wsClientNum = 255;
static bool wsConnected = false;
static volatile bool tcpConnected = false;
static volatile bool tcpNeedDrawAck = false;
static volatile bool needSoftApRestart = false;
static volatile bool pendingBleRestart = false;
static unsigned long pendingBleRestartAt = 0;

static Preferences prefs;
static String bleName = "ysiducnaga";
static String wifiSsid = "ysiducnaga";
static String wifiPass = "12345678";

// Start SoftAP WITHOUT offering a default gateway/DNS via DHCP, so iOS immediately sees
// "no Internet on this Wi-Fi" and keeps using cellular data without Wi-Fi Assist disconnects.
static void startSoftAp() {
  WiFi.softAPdisconnect(true);
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

static void publishCompleteFrameFromWriter(int8_t writerSlot, size_t len) {
  portENTER_CRITICAL(&frameMux);
  framePoolLen[writerSlot] = len;
  latestReadySlot = writerSlot;
  portEXIT_CRITICAL(&frameMux);
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
bool g_skipNavPopup = false;
bool tft_output(int16_t x, int16_t y, uint16_t w, uint16_t h, uint16_t* bitmap) {
  if (y >= tft.height() || x >= tft.width()) return 1;
  if (g_clipMapOnly && (x < 6 || x >= 150 || y < 8 || y >= 232)) return 1;
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
    if (pNavChar != nullptr && bleConnected) {
      String resp = "{\"type\":\"APP_CONNECT_ACK\",\"status\":\"connected\"}";
      pNavChar->setValue(resp.c_str());
      pNavChar->notify();
      delay(10);
      String cfgResp = "{\"type\":\"DEVICE_CONFIG\",\"ble_name\":\"" + bleName + "\",\"ssid\":\"" + wifiSsid + "\",\"pass\":\"" + wifiPass + "\",\"ip\":\"192.168.4.1\",\"port\":8081,\"tcp\":" + String(tcpConnected ? 1 : 0) + "}";
      pNavChar->setValue(cfgResp.c_str());
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
  } else if (typeStr == "DEVICE_CONFIG" || typeStr == "BLE_CONFIG" || typeStr == "WIFI_CONFIG" || typeStr == "WIFI_QUERY" || typeStr == "DEVICE_QUERY") {
    bool wifiChanged = false;
    bool bleChanged = false;

    if (doc["ssid"].is<const char*>()) {
      String newSsid = String(doc["ssid"].as<const char*>());
      newSsid.replace("\"", "");
      newSsid.replace("\\", "");
      newSsid.trim();
      if (newSsid.length() >= 1 && newSsid.length() <= 31 && newSsid != wifiSsid) {
        wifiSsid = newSsid;
        wifiChanged = true;
      }
    }
    if (doc["pass"].is<const char*>()) {
      String newPass = String(doc["pass"].as<const char*>());
      newPass.replace("\"", "");
      newPass.replace("\\", "");
      if (newPass.length() >= 8 && newPass.length() <= 63 && newPass != wifiPass) {
        wifiPass = newPass;
        wifiChanged = true;
      }
    }
    if (doc["ble_name"].is<const char*>()) {
      String newBle = String(doc["ble_name"].as<const char*>());
      newBle.replace("\"", "");
      newBle.replace("\\", "");
      newBle.trim();
      if (newBle.length() >= 1 && newBle.length() <= 24 && newBle != bleName) {
        bleName = newBle;
        bleChanged = true;
      }
    }

    if (wifiChanged) {
      prefs.begin("nav_wifi", false);
      prefs.putString("ap_ssid", wifiSsid);
      prefs.putString("ap_pass", wifiPass);
      prefs.end();
      Serial.printf("[WiFi AP] Saved new AP SSID='%s' passLen=%d -> restarting SoftAP\n", wifiSsid.c_str(), wifiPass.length());
      needSoftApRestart = true;
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
      String cfgResp = "{\"type\":\"DEVICE_CONFIG\",\"ble_name\":\"" + bleName + "\",\"ssid\":\"" + wifiSsid + "\",\"pass\":\"" + wifiPass + "\",\"ip\":\"192.168.4.1\",\"port\":8081,\"tcp\":" + String(tcpConnected ? 1 : 0) + ",\"restarting\":" + String(bleChanged ? 1 : 0) + "}";
      pNavChar->setValue(cfgResp.c_str());
      pNavChar->notify();
      delay(10);
      String resp = "{\"type\":\"WIFI_STATUS\",\"status\":\"connected\",\"mode\":\"AP\",\"ip\":\"192.168.4.1\",\"ws\":" + String((wsConnected || tcpConnected) ? 1 : 0) + ",\"port\":8081,\"hotspot\":\"" + wifiSsid + "\"}";
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

  bool isNav = (doc["nav"] | 0) == 1;
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
      } else if (magic2 == 0xBC || magic2 == 0xBD) {
        uint8_t totalChunks = (uint8_t)value[3];
        uint8_t chunkIdx = (uint8_t)value[4];
        size_t payloadLen = value.length() - 5;
        const char* targetPath = (magic2 == 0xBC) ? "/bg_wait.jpg" : "/bg_map.jpg";

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
          display.forceRedraw();
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

  for (;;) {
    if (needSoftApRestart) {
      needSoftApRestart = false;
      if (tcpStreamClient) tcpStreamClient.stop();
      tcpConnected = false;
      rxState = 0;
      rxPos = 0;
      startSoftAp();
      tcpStreamServer.begin();
    }

    if (tcpStreamServer.hasClient()) {
      WiFiClient incoming = tcpStreamServer.accept();
      if (incoming) {
        if (tcpStreamClient) tcpStreamClient.stop();
        tcpStreamClient = incoming;
        tcpStreamClient.setNoDelay(true);
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
      rxState = 0;
      rxPos = 0;
      Serial.println("[TCP 8081] iPhone disconnected");
    }

    if (tcpStreamClient && tcpStreamClient.connected()) {
      if (tcpNeedDrawAck) {
        tcpNeedDrawAck = false;
        const uint8_t ack = 'K';
        tcpStreamClient.write(&ack, 1);
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
          if (pktType == 0xBB || pktType == 0xCC) {
            rxState = 2;
          } else if (pktType == 0xDD) {
            const uint8_t ack = 'K';
            tcpStreamClient.write(&ack, 1);
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
          if (pktLen == 0 || (pktType == 0xBB && pktLen > 32768) || (pktType == 0xCC && pktLen > 1023)) {
            rxState = 0;
          } else {
            if (pktType == 0xBB) {
              writerSlot = acquireFreeWriterSlot();
            }
            rxState = 4;
          }
        } else if (rxState == 4) {
          int avail = tcpStreamClient.available();
          if (avail <= 0) break;
          size_t remain = pktLen - rxPos;
          size_t toRead = ((size_t)avail < remain) ? (size_t)avail : remain;
          uint8_t* dst = (pktType == 0xBB)
              ? (framePool[writerSlot] + rxPos)
              : ((uint8_t*)tcpJsonBuf + rxPos);
          int got = tcpStreamClient.read(dst, toRead);
          if (got > 0) {
            rxPos += (size_t)got;
          } else {
            break;
          }
          if (rxPos >= pktLen) {
            if (pktType == 0xBB) {
              if (pktLen > 100 && framePool[writerSlot][0] == 0xFF && framePool[writerSlot][1] == 0xD8) {
                publishCompleteFrameFromWriter(writerSlot, pktLen);
              } else {
                tcpNeedDrawAck = true;
              }
            } else if (pktType == 0xCC) {
              tcpJsonBuf[pktLen] = '\0';
              tcpJsonLen = pktLen;
              tcpJsonAvailable = true;
              const uint8_t ack = 'K';
              tcpStreamClient.write(&ack, 1);
            }
            rxState = 0;
            rxPos = 0;
          }
        }
      }

      if (tcpNeedDrawAck) {
        tcpNeedDrawAck = false;
        const uint8_t ack = 'K';
        tcpStreamClient.write(&ack, 1);
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
  bleName = prefs.getString("ble_name", "ysiducnaga");
  prefs.end();
  if (bleName.length() == 0) bleName = "ysiducnaga";

  prefs.begin("nav_wifi", false);
  wifiSsid = prefs.getString("ap_ssid", "ysiducnaga");
  wifiPass = prefs.getString("ap_pass", "12345678");
  prefs.end();
  if (wifiSsid.length() == 0) wifiSsid = "ysiducnaga";
  if (wifiPass.length() < 8) wifiPass = "12345678";
  Serial.printf("[NVS] BLE='%s' | SoftAP SSID='%s'\n", bleName.c_str(), wifiSsid.c_str());

  // 1. Initialize TJpgDec BEFORE display.init() so any background JPEG drawn during init has a valid callback
  #if defined(DISPLAY_TFT_ST7789)
  TJpgDec.setJpgScale(1);
  TJpgDec.setSwapBytes(true);
  TJpgDec.setCallback(tft_output);
  #endif

  // 2. Start Display (safe to render SPIFFS JPEGs)
  display.init();

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
  // Complete Local Name: "ysiducnaga" (12 bytes)
  // Custom Nav Service: 0xFFE0 (4 bytes)
  // Total = 16 bytes <= 31 bytes!
  NimBLEAdvertisementData scanResponseData;
  scanResponseData.setName(bleName.c_str());
  scanResponseData.setCompleteServices(NimBLEUUID((uint16_t)0xFFE0));
  pAdvertising->setScanResponseData(scanResponseData);

  pAdvertising->setMinInterval(16); // 10ms fast advertising
  pAdvertising->setMaxInterval(32); // 20ms
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  // 3. Start ESP32 SoftAP (no Internet) + Non-Blocking TCP Stream (8081) + WebSocket fallback (8080)
  startSoftAp();
  tcpStreamServer.begin();
  xTaskCreatePinnedToCore(tcpStreamTask, "tcpStreamTask", 4096, nullptr, 2, nullptr, 1);

  webSocketServer.begin();
  webSocketServer.onEvent(webSocketEvent);
  webSocketServer.disableHeartbeat();

  Serial.printf("[BLE & WiFi AP] '%s' ready: join Wi-Fi '%s' (pass '%s') on TCP 8081 / WS 8080!\n",
                bleName.c_str(), wifiSsid.c_str(), wifiPass.c_str());
}

void loop() {
  // Handle deferred reboot after custom BLE name save
  if (pendingBleRestart && millis() >= pendingBleRestartAt) {
    pendingBleRestart = false;
    Serial.println("[BLE] Rebooting to apply new Bluetooth name...");
    delay(50);
    ESP.restart();
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
  }
  portEXIT_CRITICAL(&frameMux);

  if (slotToDraw >= 0) {
    lastFrameTime = millis();
    uint8_t* frameBuf = framePool[slotToDraw];

    #if defined(DISPLAY_TFT_ST7789)
    // Render live map/simulator when app has established handshake (isAppConnected) or WiFi stream is active
    if (frameLen > 100 && (display.isAppConnected() || wsConnected || tcpConnected)) {
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
      } else if (jpgW > 0) {
        display.setFullScreenStream(false);
        g_clipMapOnly = true;
        g_skipNavPopup = false;
        tft.setViewport(6, 8, 144, 224, false);
        TJpgDec.drawJpg(6, 8, frameBuf, frameLen);
        tft.resetViewport();
        g_clipMapOnly = false;
        tft.drawRoundRect(4, 6, 148, 228, 12, tft.color565(56, 189, 248));
        display.onFrameRendered();
      }
    }
    #endif

    // Signal iPhone AFTER physical ST7789 draw completes so TCP never queues stale frames
    if (tcpConnected) {
      tcpNeedDrawAck = true;
    }
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
  bool isStreaming = (display.isAppConnected() || wsConnected || tcpConnected) && (millis() - lastFrameTime < 4000);
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
