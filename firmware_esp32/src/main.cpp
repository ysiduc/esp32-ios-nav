#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include "display_ui.h"
#include "ams_service.h"

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
bool tft_output(int16_t x, int16_t y, uint16_t w, uint16_t h, uint16_t* bitmap) {
  if (y >= tft.height() || x >= 154) return 1;
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

// =========================================================================
// 1. BLE Server Callbacks
// =========================================================================
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) {
    bleConnected = true;
    display.setBleConnected(true);
    Serial.printf("[BLE] iPhone connected! conn_handle=%d, enc=%d, bond=%d\n",
                  desc->conn_handle, desc->sec_state.encrypted, desc->sec_state.bonded);

    // Increase supervision timeout to 1000 (10 seconds) to prevent auto-disconnects when idle in background
    pServer->updateConnParams(desc->conn_handle, 16, 32, 0, 1000);

    AppleMediaService::connHandle = desc->conn_handle;
    AppleMediaService::lastCheckTime = millis();

    // If already encrypted/bonded, immediately trigger AMS
    if (desc->sec_state.encrypted) {
      Serial.println("[BLE] Link already encrypted. Starting AMS discovery...");
      AppleMediaService::onEncrypted(desc->conn_handle);
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
      AppleMediaService::onEncrypted(desc->conn_handle);
    }
  }

  void onDisconnect(NimBLEServer* pServer) {
    bleConnected = false;
    display.setBleConnected(false);
    AppleMediaService::onDisconnected();
    Serial.println("[BLE] Disconnected. Restarting advertising...");
    NimBLEDevice::startAdvertising();
  }
};

// =========================================================================
// 2. Custom Navigation Characteristic Callback (Receives 20 FPS JPEG & JSON)
// =========================================================================
static uint8_t expectedBleChunkIdx = 0;

class NavCharCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic) {
    std::string value = pCharacteristic->getValue();
    if (value.length() == 0) return;

    // 1. Check for Binary Chunked JPEG Packet (Magic 0xAA 0xBB from iPhone Stream)
    if (value.length() >= 5 && (uint8_t)value[0] == 0xAA && (uint8_t)value[1] == 0xBB) {
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
    }

    // 2. JSON Notification or Navigation Telemetry
    JsonDocument doc;
    DeserializationError error = deserializeJson(doc, value.c_str());

    if (!error) {
      String typeStr = String(doc["type"] | "");
      if (typeStr == "CALL") {
        const char* name = doc["title"] | "Cuoc goi den";
        popupTitle = name;
        popupMsg = doc["msg"] | "Cuoc goi den tu iPhone";
        popupType = "CALL";
        popupExpire = millis() + 10000;
        display.showCallAlert(name);
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
        display.showCallActiveAlert(name);
        return;
      }

      curTurn = doc["turn"] | 0;
      curDist = doc["dist"] | 0;
      curTotalDist = doc["tot_dist"] | doc["tot"] | 0;
      curSpeed = doc["speed"] | 0;
      curEta = doc["eta"] | 0;
      curStreet = String(doc["street"] | "CAU SONG LU");
      curArrival = String(doc["arrival"] | "18:26");
      curClock = String(doc["clock"] | "18:25");
      curBattery = doc["bat"] | 89;
      if (doc["head"].is<int>()) curHeading = doc["head"];

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
      display.setNavData(curTurn, curDist, curTotalDist, curSpeed, curEta, curStreet.c_str(), curArrival.c_str(), curClock.c_str(), curBattery, parsedPts, parsedPtCount, isNav);

      if (doc["song"].is<const char*>() || doc["song"].is<String>()) {
        String curSong = String(doc["song"] | "");
        String curArtist = String(doc["artist"] | "");
        if (curSong.length() > 0 && curSong != "CHUA PHAT NHAC" && curSong != "Waiting For You") {
          display.setSongInfo(curSong.c_str(), curArtist.c_str());
        }
      }
    }
  }
};

// =========================================================================
// Setup & Loop
// =========================================================================
void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("\n=== ESP32-S3 SMART NAVIGATOR (YSIDUC ST7789 20 FPS) ===");

  // 1. Start Display
  display.init();
  #if defined(DISPLAY_TFT_ST7789)
  TJpgDec.setJpgScale(1);
  TJpgDec.setSwapBytes(true);
  TJpgDec.setCallback(tft_output);
  #endif

  // 2. Start NimBLE Server (Max MTU 517 for High-Speed BLE Stream)
  NimBLEDevice::init("ESP32-S3 Navi");
  NimBLEDevice::setMTU(517);

  // Security Auth & Bonding for iOS (Required by Apple Media Service)
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setCustomGapHandler(AppleMediaService::handleGapEvent);
  AppleMediaService::init();

  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  NimBLEService* pNavService = pServer->createService(navServiceUUID);
  pNavChar = pNavService->createCharacteristic(
    navCharUUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
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

  // Scan Response Data with Apple Media Service Solicitation (18 bytes)
  NimBLEAdvertisementData scanResponseData;
  scanResponseData.addData((char*)amsSolicitData, sizeof(amsSolicitData));
  pAdvertising->setScanResponseData(scanResponseData);

  pAdvertising->setMinInterval(16); // 10ms fast advertising
  pAdvertising->setMaxInterval(32); // 20ms
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  Serial.println("[BLE] ESP32-S3 Navi ready for 20 FPS JPEG stream + Apple Media Service!");
}

void loop() {
  // 1. Decode & push new JPEG Map Frame safely on the Main thread
  if (newFrameAvailable) {
    newFrameAvailable = false;
    lastFrameTime = millis();
    #if defined(DISPLAY_TFT_ST7789)
    if (activeRenderBufLen > 100) {
      TJpgDec.drawJpg(6, 26, (uint8_t*)activeRenderBuf, activeRenderBufLen);
    }
    #endif
  }

  // 2. Update HUD and status UI
  bool isStreaming = (millis() - lastFrameTime < 2500);
  display.update(isStreaming);

  // 3. Periodic check for Apple Media Service discovery
  AppleMediaService::checkPeriodic();

  delay(1);
}
