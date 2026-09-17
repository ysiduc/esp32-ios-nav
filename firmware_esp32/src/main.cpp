#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include <WiFi.h>
#include <WiFiServer.h>
#include <WiFiClient.h>
#include <WebSocketsClient.h>
#include <Preferences.h>
#include "display_ui.h"
#include "ams_service.h"
#include "ancs_service.h"

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
#include <TJpg_Decoder.h>
bool g_clipMapOnly = false;
bool tft_output(int16_t x, int16_t y, uint16_t w, uint16_t h, uint16_t* bitmap) {
  if (y >= tft.height() || x >= tft.width()) return 1;
  if (g_clipMapOnly && x >= 154) return 1;
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

// Combined GAP event handler for AMS & ANCS
static int combinedGapHandler(ble_gap_event *event, void *arg) {
  AppleMediaService::handleGapEvent(event, arg);
  AppleNotificationService::handleGapEvent(event, arg);
  return 0;
}

// =========================================================================
// 1. BLE Server Callbacks
// =========================================================================
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) {
    bleConnected = true;
    display.setBleConnected(true);
    Serial.printf("[BLE] iPhone connected! conn_handle=%d, enc=%d, bond=%d\n",
                  desc->conn_handle, desc->sec_state.encrypted, desc->sec_state.bonded);

    AppleMediaService::connHandle = desc->conn_handle;
    AppleMediaService::lastCheckTime = millis();
    AppleNotificationService::connHandle = desc->conn_handle;
    AppleNotificationService::lastCheckTime = millis();

    // Configure BLE connection parameters for flawless WiFi coexistence
    // (Interval 30-50ms, Supervision timeout 6000ms = 6 seconds so WiFi RF scan never drops BLE)
    pServer->updateConnParams(desc->conn_handle, 24, 40, 0, 600);

    // If already encrypted/bonded, immediately trigger ANCS sequential discovery (which chains to AMS)
    if (desc->sec_state.encrypted) {
      Serial.println("[BLE] Link already encrypted. Starting ANCS sequential discovery...");
      AppleNotificationService::onEncrypted(desc->conn_handle);
    } else {
      // Trigger pairing/bonding request to iOS (prompts native iOS pairing dialog)
      int secRc = NimBLEDevice::startSecurity(desc->conn_handle);
      Serial.printf("[BLE] startSecurity returned: %d\n", secRc);
    }

    // Keep advertising active so the App or other scans can still find this device
    NimBLEDevice::startAdvertising();
  }

  void onAuthenticationComplete(ble_gap_conn_desc* desc) {
    Serial.printf("[BLE] Authentication complete! enc=%d, bond=%d\n",
                  desc->sec_state.encrypted, desc->sec_state.bonded);
    if (desc->sec_state.encrypted) {
      AppleNotificationService::onEncrypted(desc->conn_handle);
    }
  }

  void onDisconnect(NimBLEServer* pServer) {
    bleConnected = false;
    display.setBleConnected(false);
    AppleMediaService::onDisconnected();
    AppleNotificationService::onDisconnected();
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
  if (typeStr == "PING") {
    if (doc["clock"].is<const char*>()) {
      curClock = String(doc["clock"].as<const char*>());
    }
    if (doc["bat"].is<uint8_t>()) {
      curBattery = doc["bat"].as<uint8_t>();
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

    const char* name = doc["title"] | "Cuoc goi den";
    const char* msg = doc["msg"] | "Cuoc goi den tu iPhone";
    // If ANCS already set a caller name from iOS native system, do NOT overwrite with generic "Cuoc goi den"
    if (display.isCallActive() && strcmp(display.getCallerName(), "Cuoc goi den") != 0 && strcmp(name, "Cuoc goi den") == 0) {
      return;
    }
    popupTitle = name;
    popupMsg = msg;
    popupType = "CALL";
    popupExpire = millis() + 10000;
    display.showCallAlert(name, popupMsg.c_str());
    return;
  } else if (typeStr == "SMS") {
    const char* sender = doc["title"] | "Tin nhan";
    const char* content = doc["msg"] | "Thong bao moi";
    popupTitle = sender;
    popupMsg = content;
    popupType = "SMS";
    popupExpire = millis() + 8000;
    display.showSmsAlert(sender, content);
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
  if (doc["bat"].is<int>()) curBattery = doc["bat"];
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

  // Security Auth & Bonding for iOS (Required by Apple Media Service & ANCS)
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setSecurityInitKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setSecurityRespKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setCustomGapHandler(combinedGapHandler);
  AppleMediaService::init();
  AppleNotificationService::init();

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

  // Custom Advertisement Data (22 bytes, NEVER truncated, full device name)
  NimBLEAdvertisementData advData;
  advData.setFlags(0x06); // General Discoverable + BR/EDR not supported
  advData.setName("ESP32-S3 Navi");
  advData.setCompleteServices(NimBLEUUID((uint16_t)0xFFE0));
  pAdvertising->setAdvertisementData(advData);

  // Scan Response Data with Apple Notification Center Service (ANCS) Solicitation (18 bytes)
  // This triggers the native iOS prompt: "Allow ESP32-S3 Navi to display iPhone notifications?"
  NimBLEAdvertisementData scanResponseData;
  scanResponseData.addData((char*)ancsSolicitData, sizeof(ancsSolicitData));
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
    if (activeRenderBufLen > 100) {
      g_clipMapOnly = true;
      TJpgDec.drawJpg(6, 26, (uint8_t*)activeRenderBuf, activeRenderBufLen);
      g_clipMapOnly = false;
    }
    #endif
  }

  // 2. Update HUD and status UI
  bool isStreaming = (millis() - lastFrameTime < 4000);
  display.update(isStreaming);


  // 4. Periodic check for Apple Media Service & ANCS discovery
  AppleMediaService::checkPeriodic();
  AppleNotificationService::checkPeriodic();

  delay(1);
}
