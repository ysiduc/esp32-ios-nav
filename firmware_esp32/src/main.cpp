#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include <WiFi.h>
#include <WiFiServer.h>
#include <WiFiClient.h>
#include <WebSocketsClient.h>
#include <Preferences.h>
#include "display_ui.h"
#include "ancs_service.h"
#include "cts_service.h"
#include "ams_service.h"

// Pure WiFi STA Client for iPhone Hotspot (IP 172.20.10.1:8080)
static WebSocketsClient webSocketClient;
static bool wsConnected = false;
static bool staConnected = false;
static Preferences prefs;
static String wifiSsid = "#ysiduc";
static String wifiPass = "00000000";



// Ping-Pong Double Buffering for Smooth 20 FPS JPEG Stream without Race Conditions
static uint8_t bleRxBuf[24576];
static uint8_t renderBufA[24576];
static uint8_t renderBufB[24576];
static volatile uint8_t* activeRenderBuf = renderBufA;
static volatile size_t activeRenderBufLen = 0;
static volatile bool newFrameAvailable = false;
static volatile unsigned long lastFrameTime = 0;

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
extern DisplayManager display;
bool tft_output(int16_t x, int16_t y, uint16_t w, uint16_t h, uint16_t* bitmap) {
  if (y >= tft.height() || x >= tft.width()) return 1;
  if (g_clipMapOnly && x >= 154) return 1;
  // If top notification banner is active, clip map stream from overwriting banner at y: 24..80
  if (display.isPopupActive() && (y + h > 24 && y < 80)) return 1;
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

// GAP event handler to monitor connection lifecycle, clean up bonds, and forward to Apple services
static int combinedGapHandler(ble_gap_event *event, void *arg) {
  // Forward notification events to Apple services for notifications & media
  AppleNotificationService::handleGapEvent(event, arg);
  AppleMediaService::handleGapEvent(event, arg);
  AppleCurrentTimeService::handleGapEvent(event, arg);

  if (event->type == BLE_GAP_EVENT_ENC_CHANGE) {
    Serial.printf("[BLE] Link encrypted (status=%d, conn_handle=%d)\n",
                  event->enc_change.status, event->enc_change.conn_handle);
    if (event->enc_change.status == 0) {
      secPending = false;
      // Link encrypted and bonded! Start ANCS notification discovery
      appleDiscState = APPLE_DISC_START_ANCS;
      appleDiscTimer = millis() + 200;
    } else {
      appleDiscState = APPLE_DISC_IDLE;
      NimBLEDevice::deleteBond(event->enc_change.conn_handle);
      Serial.printf("[BLE] Link encryption failed (status=%d). Stale bond cleared.\n",
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
  return 0;
}

// =========================================================================
// 1. BLE Server Callbacks
// =========================================================================
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) {
    bleConnected = true;
    display.setBleConnected(true);
    Serial.printf("[BLE] iPhone connected! conn_handle=%d, bonded=%d, encrypted=%d\n",
                  desc->conn_handle, desc->sec_state.bonded, desc->sec_state.encrypted);

    bleConnectedHandle = desc->conn_handle;
    bleConnectedTime = millis();

    AppleNotificationService::connHandle = desc->conn_handle;
    AppleMediaService::connHandle = desc->conn_handle;
    AppleCurrentTimeService::connHandle = desc->conn_handle;

    // Request Apple-compliant connection parameters (20ms - 40ms interval, 6000ms supervision timeout)
    pServer->updateConnParams(desc->conn_handle, 16, 32, 0, 600);

    // Stop advertising while connected to eliminate 2.4GHz RF collisions with Wi-Fi & BLE link
    NimBLEDevice::stopAdvertising();

    if (desc->sec_state.encrypted) {
      Serial.println("[BLE] Link already encrypted/bonded. Starting Apple ANCS discovery...");
      secPending = false;
      appleDiscState = APPLE_DISC_START_ANCS;
      appleDiscTimer = millis() + 300;
    } else if (desc->sec_state.bonded) {
      Serial.println("[BLE] Link bonded, awaiting encryption change or starting ANCS...");
      secPending = false;
      appleDiscState = APPLE_DISC_START_ANCS;
      appleDiscTimer = millis() + 600;
    } else {
      // Unbonded link: Schedule slave security request in 500ms so iOS prompts native "Bluetooth Pairing Request" dialog
      Serial.println("[BLE] Link connected (unbonded). Scheduling security request in 500ms to trigger Pairing dialog...");
      secPending = true;
      secPendingTime = millis() + 500;
      appleDiscState = APPLE_DISC_IDLE;
    }
  }

  void onAuthenticationComplete(ble_gap_conn_desc* desc) {
    Serial.printf("[BLE] Authentication complete! enc=%d, bond=%d\n",
                  desc->sec_state.encrypted, desc->sec_state.bonded);
    secPending = false;
    if (desc->sec_state.encrypted) {
      appleDiscState = APPLE_DISC_START_ANCS;
      appleDiscTimer = millis() + 200;
    }
  }

  void onDisconnect(NimBLEServer* pServer) {
    bleConnected = false;
    bleConnectedHandle = 0;
    secPending = false;
    appleDiscState = APPLE_DISC_IDLE;
    AppleNotificationService::onDisconnected();
    AppleMediaService::onDisconnected();
    display.setBleConnected(false);
    display.setAppConnected(false);
    Serial.println("[BLE] Disconnected. Restarting advertising...");
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
  } else if (typeStr == "WIFI_CONFIG" || typeStr == "WIFI_QUERY") {
    if (doc["ssid"].is<const char*>() && doc["pass"].is<const char*>()) {
      wifiSsid = String(doc["ssid"].as<const char*>());
      wifiPass = String(doc["pass"].as<const char*>());
      prefs.begin("nav_wifi", false);
      prefs.putString("ssid", wifiSsid);
      prefs.putString("pass", wifiPass);
      prefs.end();
      Serial.printf("[WiFi STA] Saved & Reconnecting with SSID: '%s'\n", wifiSsid.c_str());
      WiFi.disconnect();
      WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());
    }
    if (pNavChar != nullptr && bleConnected) {
      String staIp = (WiFi.status() == WL_CONNECTED) ? WiFi.localIP().toString() : "none";
      String statusStr = (WiFi.status() == WL_CONNECTED) ? "connected" : "connecting";
      String resp = "{\"type\":\"WIFI_STATUS\",\"status\":\"" + statusStr + "\",\"mode\":\"STA\",\"sta_ip\":\"" + staIp + "\",\"ws\":" + (wsConnected ? "1" : "0") + ",\"port\":8080,\"hotspot\":\"" + wifiSsid + "\"}";
      pNavChar->setValue(resp.c_str());
      pNavChar->notify();
    }
    return;

} else if (typeStr == "CALL") {
    const char* name = doc["title"] | "Cuộc gọi đến";
    const char* msg = doc["msg"] | "đang gọi đến...";
    const char* appStr = doc["app"] | "sim";

    AppSourceType appType = APP_SOURCE_SIM;
    if (strcasecmp(appStr, "zalo") == 0) {
      appType = APP_SOURCE_ZALO;
    } else if (strcasecmp(appStr, "messenger") == 0) {
      appType = APP_SOURCE_MESSENGER;
    } else {
      appType = APP_SOURCE_SIM;
    }

    if (display.isCallActive() && strcmp(display.getCallerName(), "Cuộc gọi đến") != 0 && strcmp(name, "Cuộc gọi đến") == 0) {
      return;
    }
    popupTitle = name;
    popupMsg = msg;
    popupType = "CALL";
    popupExpire = millis() + 60000;
    display.showCallAlert(name, popupMsg.c_str(), appType);
    return;
  } else if (typeStr == "SMS") {
    const char* sender = doc["title"] | "Tin nhắn";
    const char* content = doc["msg"] | "Thông báo mới";
    const char* appStr = doc["app"] | "sms";

    AppSourceType appType = APP_SOURCE_SMS;
    if (strcasecmp(appStr, "zalo") == 0) {
      appType = APP_SOURCE_ZALO;
    } else if (strcasecmp(appStr, "messenger") == 0) {
      appType = APP_SOURCE_MESSENGER;
    } else if (strcasecmp(appStr, "sim") == 0 || strcasecmp(appStr, "sms") == 0) {
      appType = APP_SOURCE_SMS;
    } else {
      appType = APP_SOURCE_OTHER;
    }

    popupTitle = sender;
    popupMsg = content;
    popupType = "SMS";
    popupExpire = millis() + 10000; // Exactly 10s for SMS notification
    display.showSmsAlert(sender, content, appType);
    return;
  } else if (typeStr == "CALL_END") {
    popupType = "NONE";
    popupExpire = 0;
    display.dismissAlert();
    return;
  } else if (typeStr == "CALL_ACTIVE") {
    const char* name = doc["title"] | "Dang nghe may";
    popupTitle = name;
    popupType = "CALL_ACTIVE";
    popupExpire = millis() + 5000;
    display.showCallAlert(name, "Dang nghe may");
    return;
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
    if (curSong.length() > 0 && curSong != "CHUA PHAT NHAC") {
      display.setSongInfo(curSong.c_str(), curArtist.c_str());
    }
  }
}

// WebSocket Event Handler for iPhone Hotspot stream
void webSocketEvent(WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_DISCONNECTED:
      wsConnected = false;
      Serial.println("[WebSocket] Disconnected from iPhone Hotspot!");
      break;
    case WStype_CONNECTED:
      wsConnected = true;
      Serial.printf("[WebSocket] Connected to iPhone Hotspot Server: %s\n", (const char*)payload);
      break;
    case WStype_TEXT:
      if (length > 0) {
        processJsonPacket((const char*)payload);
      }
      break;
    case WStype_BIN:
      if (length > 100 && payload[0] == 0xFF && payload[1] == 0xD8) {
        uint8_t* nextBuf = (activeRenderBuf == renderBufA) ? renderBufB : renderBufA;
        if (length <= sizeof(renderBufA)) {
          memcpy(nextBuf, payload, length);
          activeRenderBuf = nextBuf;
          activeRenderBufLen = length;
          newFrameAvailable = true;
        }
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
            if (bleRxBuf[0] == 0xFF && bleRxBuf[1] == 0xD8) {
              uint8_t* nextBuf = (activeRenderBuf == renderBufA) ? renderBufB : renderBufA;
              memcpy(nextBuf, bleRxBuf, bleJpegBytesReceived);
              activeRenderBuf = nextBuf;
              activeRenderBufLen = bleJpegBytesReceived;
              newFrameAvailable = true;
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
// Setup & Loop
// =========================================================================
void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("\n=== ESP32-S3 SMART NAVIGATOR (YSIDUC ST7789 20 FPS) ===");

  // 0. Mount SPIFFS Filesystem for Custom Background Images
  if (!SPIFFS.begin(true)) {
    Serial.println("[SPIFFS] Mount failed, formatted partition.");
  } else {
    Serial.println("[SPIFFS] Filesystem mounted successfully.");
  }

  // Load saved Hotspot credentials from Preferences NVS
  prefs.begin("nav_wifi", false);
  wifiSsid = prefs.getString("ssid", "#ysiduc");
  wifiPass = prefs.getString("pass", "00000000");
  prefs.end();
  Serial.printf("[NVS] Loaded Hotspot SSID: '%s'\n", wifiSsid.c_str());

  // 1. Initialize TJpgDec BEFORE display.init() so any background JPEG drawn during init has a valid callback
  #if defined(DISPLAY_TFT_ST7789)
  TJpgDec.setJpgScale(1);
  TJpgDec.setSwapBytes(true);
  TJpgDec.setCallback(tft_output);
  #endif

  // 2. Start Display (safe to render SPIFFS JPEGs)
  display.init();

  // 2. Start NimBLE Server (Max MTU 517 for High-Speed BLE Stream)
  NimBLEDevice::init("ESP32-S3 Navi");
  NimBLEDevice::setMTU(517);

  // Enable BLE Security Auth with Bonding for Apple Notification Center Service (ANCS)
  NimBLEDevice::setSecurityAuth(true, false, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setSecurityInitKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setSecurityRespKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setCustomGapHandler(combinedGapHandler);

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
    NIMBLE_PROPERTY::READ |
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR |
    NIMBLE_PROPERTY::NOTIFY
  );
  pNavChar->setCallbacks(new NavCharCallbacks());
  pNavService->start();

  NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();

  // Primary Advertisement Data (must strictly be <= 31 bytes):
  // 1. Flags: 0x02, 0x01, 0x06 (3 bytes)
  // 2. 128-bit Service Solicitation for ANCS (AD Type 0x15): 0x11, 0x15, [16 bytes UUID] (18 bytes)
  //    -> This triggers iOS Settings -> Bluetooth to immediately recognize and list "ESP32-S3 Navi" in Other Devices!
  // 3. Complete 16-bit Service UUID: 0x03, 0x03, 0xE0, 0xFF (4 bytes)
  // 4. Shortened Local Name (AD Type 0x08): 0x05, 0x08, 'N', 'a', 'v', 'i' (6 bytes)
  // Total in advData = 3 + 18 + 4 + 6 = 31 bytes (EXACTLY 31 bytes maximum!)
  NimBLEAdvertisementData advData;
  advData.setFlags(0x06);
  advData.addData(std::string((char*)ancsSolicitData, sizeof(ancsSolicitData)));
  advData.setCompleteServices(NimBLEUUID((uint16_t)0xFFE0));
  advData.setShortName("Navi");
  pAdvertising->setAdvertisementData(advData);

  // Scan Response Data (Active Scan response <= 31 bytes):
  // Complete Local Name (AD Type 0x09): 0x0E, 0x09, "ESP32-S3 Navi" (15 bytes)
  // Total in scanResponseData = 15 bytes <= 31 bytes
  NimBLEAdvertisementData scanResponseData;
  scanResponseData.setName("ESP32-S3 Navi");
  pAdvertising->setScanResponseData(scanResponseData);

  pAdvertising->setMinInterval(16); // 10ms fast advertising
  pAdvertising->setMaxInterval(32); // 20ms
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  // 3. Start WiFi in Pure Station Mode (STA only - ESP32 connects to iPhone Hotspot, no SoftAP)
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(true); // MUST BE TRUE for WiFi + BLE coexistence in ESP-IDF!
  WiFi.setAutoReconnect(true);

  // Connect to iPhone Personal Hotspot using loaded/configured credentials
  Serial.printf("[WiFi STA] Connecting to iPhone Hotspot ('%s')...\n", wifiSsid.c_str());
  WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());

  // Configure SNTP for automatic time sync (UTC+7 Vietnam)
  configTime(7 * 3600, 0, "pool.ntp.org", "time.google.com");

  // Configure WebSocket Client callbacks (begin() is called when WiFi connects)
  webSocketClient.onEvent(webSocketEvent);
  webSocketClient.setReconnectInterval(2000);
  webSocketClient.enableHeartbeat(15000, 3000, 2);

  Serial.printf("[BLE & WiFi STA] ESP32-S3 Navi ready for Hotspot ('%s') + AMS & ANCS!\n", wifiSsid.c_str());
}

void loop() {
  // 0. Manage iPhone Hotspot STA connection & WebSocket loop
  if (WiFi.status() == WL_CONNECTED && WiFi.localIP() != IPAddress(0, 0, 0, 0)) {
    if (!staConnected) {
      staConnected = true;
      IPAddress gw = WiFi.gatewayIP();
      String host = (gw != IPAddress(0, 0, 0, 0)) ? gw.toString() : "172.20.10.1";
      Serial.printf("[WiFi STA] Connected to iPhone Hotspot! ESP32 IP: %s, Gateway: %s, Target: %s:8080\n",
                    WiFi.localIP().toString().c_str(), gw.toString().c_str(), host.c_str());
      webSocketClient.disconnect();
      webSocketClient.begin(host.c_str(), 8080, "/");
    }
    webSocketClient.loop();
  } else {
    if (staConnected) {
      staConnected = false;
      Serial.println("[WiFi STA] Disconnected from iPhone Hotspot. Reconnecting...");
      webSocketClient.disconnect();
    }
  }


  // 1. Decode & push new JPEG Map Frame safely on the Main thread
  if (newFrameAvailable) {
    newFrameAvailable = false;
    lastFrameTime = millis();
    #if defined(DISPLAY_TFT_ST7789)
    // Only render live map when in Navigation mode (app connected via BLE)
    if (activeRenderBufLen > 100 && display.isAppConnected()) {
      g_clipMapOnly = true;
      if (display.isPopupActive()) {
        tft.setViewport(6, 80, 144, 154, false); // Clip below notification banner
      } else {
        tft.setViewport(6, 26, 144, 208, false);
      }
      TJpgDec.drawJpg(6, 26, (uint8_t*)activeRenderBuf, activeRenderBufLen);
      tft.resetViewport();
      g_clipMapOnly = false;
    }
    #endif

    // Send ACK back to iPhone Hotspot WebSocket server so iPhone sends the NEXT frame with 0ms queue delay!
    if (wsConnected) {
      webSocketClient.sendTXT("K");
      webSocketClient.loop();
    }
  }

  // 2. Update HUD and status UI
  bool isStreaming = (millis() - lastFrameTime < 4000);
  display.update(isStreaming);

  // 3. Delayed Security Request execution to prompt iOS native "Bluetooth Pairing Request"
  if (secPending && millis() >= secPendingTime) {
    secPending = false;
    if (bleConnected && bleConnectedHandle != 0) {
      Serial.println("[BLE] Requesting security from iPhone (startSecurity) to trigger native Pairing dialog...");
      int rc = NimBLEDevice::startSecurity(bleConnectedHandle);
      Serial.printf("[BLE] NimBLEDevice::startSecurity returned rc=%d\n", rc);
      appleDiscState = APPLE_DISC_START_ANCS;
      appleDiscTimer = millis() + 1000;
    }
  }

  // 4. Strictly Sequential Apple GATT Discovery State Machine (ANCS -> CTS -> AMS)
  if (bleConnected && bleConnectedHandle != 0) {
    switch (appleDiscState) {
      case APPLE_DISC_START_ANCS:
        if (millis() >= appleDiscTimer) {
          if (AppleNotificationService::isSubscribed) {
            appleDiscState = APPLE_DISC_START_CTS;
            appleDiscTimer = millis() + 100;
          } else {
            Serial.println("[BLE State] Step 1/3: Starting ANCS (Notifications) discovery...");
            appleDiscState = APPLE_DISC_WAIT_ANCS;
            appleDiscTimer = millis() + 6000; // 6s allows user time to tap Allow Notifications on iPhone
            AppleNotificationService::startDiscovery(bleConnectedHandle);
          }
        }
        break;

      case APPLE_DISC_WAIT_ANCS:
        if (!AppleNotificationService::isDiscovering) {
          Serial.println("[BLE State] ANCS completed! Advancing to CTS (Time)...");
          appleDiscState = APPLE_DISC_START_CTS;
          appleDiscTimer = millis() + 100;
        } else if (millis() >= appleDiscTimer) {
          Serial.println("[BLE State] ANCS timed out. Advancing to CTS (Time)...");
          AppleNotificationService::isDiscovering = false;
          appleDiscState = APPLE_DISC_START_CTS;
          appleDiscTimer = millis() + 100;
        }
        break;

      case APPLE_DISC_START_CTS:
        if (millis() >= appleDiscTimer) {
          if (AppleCurrentTimeService::isSubscribed) {
            appleDiscState = APPLE_DISC_START_AMS;
            appleDiscTimer = millis() + 100;
          } else {
            Serial.println("[BLE State] Step 2/3: Starting CTS (Time) discovery...");
            appleDiscState = APPLE_DISC_WAIT_CTS;
            appleDiscTimer = millis() + 4000;
            AppleCurrentTimeService::startDiscovery(bleConnectedHandle);
          }
        }
        break;

      case APPLE_DISC_WAIT_CTS:
        if (!AppleCurrentTimeService::isDiscovering) {
          Serial.println("[BLE State] CTS completed. Step 3/3: Advancing to AMS...");
          appleDiscState = APPLE_DISC_START_AMS;
          appleDiscTimer = millis() + 100;
        } else if (millis() >= appleDiscTimer) {
          Serial.println("[BLE State] CTS timed out. Step 3/3: Advancing to AMS...");
          AppleCurrentTimeService::isDiscovering = false;
          appleDiscState = APPLE_DISC_START_AMS;
          appleDiscTimer = millis() + 100;
        }
        break;

      case APPLE_DISC_START_AMS:
        if (millis() >= appleDiscTimer) {
          if (AppleMediaService::isSubscribed) {
            appleDiscState = APPLE_DISC_COMPLETE;
          } else {
            Serial.println("[BLE State] Step 3/3: Starting AMS (Music Title) discovery...");
            appleDiscState = APPLE_DISC_WAIT_AMS;
            appleDiscTimer = millis() + 4000;
            AppleMediaService::startDiscovery(bleConnectedHandle);
          }
        }
        break;

      case APPLE_DISC_WAIT_AMS:
        if (!AppleMediaService::isDiscovering) {
          Serial.println("[BLE State] AMS completed! All Apple services active & configured.");
          appleDiscState = APPLE_DISC_COMPLETE;
        } else if (millis() >= appleDiscTimer) {
          Serial.println("[BLE State] AMS timed out. Finalizing discovery.");
          AppleMediaService::isDiscovering = false;
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

  delay(1);
}
