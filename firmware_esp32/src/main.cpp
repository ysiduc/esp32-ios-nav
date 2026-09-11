#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include "display_ui.h"

// Frame Buffer for Direct High-Speed 20 FPS JPEG Stream over BLE
static uint8_t jpegFrameBuf[40960];
static volatile size_t jpegFrameLen = 0;
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
volatile uint8_t curTurn = 6; // Turn Left (Image 3)
volatile uint16_t curDist = 208;
volatile uint16_t curTotalDist = 5900;
volatile uint8_t curSpeed = 0;
volatile uint8_t curEta = 11;
volatile int curHeading = 0;
String curStreet = "CAU SONG LU";
String curArrival = "12:05";

// ANCS / Notification State
String popupTitle = "";
String popupMsg = "";
String popupType = "NONE";
unsigned long popupExpire = 0;

// =========================================================================
// 1. BLE Server Callbacks
// =========================================================================
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer) {
    bleConnected = true;
    display.setBleConnected(true);
    Serial.println("[BLE] iPhone da ket noi!");
  }

  void onDisconnect(NimBLEServer* pServer) {
    bleConnected = false;
    display.setBleConnected(false);
    Serial.println("[BLE] Da ngat ket noi. Phat quang ba lai...");
    NimBLEDevice::startAdvertising();
  }
};

// =========================================================================
// 2. Custom Navigation Characteristic Callback (Receives 20 FPS JPEG & JSON)
// =========================================================================
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
        bleJpegBytesReceived = 0;
      }

      if (frameId == currentBleFrameId) {
        size_t payloadLen = value.length() - 5;
        if (bleJpegBytesReceived + payloadLen < sizeof(jpegFrameBuf)) {
          memcpy(jpegFrameBuf + bleJpegBytesReceived, value.data() + 5, payloadLen);
          bleJpegBytesReceived += payloadLen;
        }

        if (chunkIdx == totalChunks - 1 && bleJpegBytesReceived > 100) {
          jpegFrameLen = bleJpegBytesReceived;
          lastFrameTime = millis();
          #if defined(DISPLAY_TFT_ST7789)
          TJpgDec.drawJpg(6, 26, jpegFrameBuf, jpegFrameLen);
          #endif
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
      }

      curTurn = doc["turn"] | 0;
      curDist = doc["dist"] | 0;
      curTotalDist = doc["tot_dist"] | 0;
      curSpeed = doc["speed"] | 0;
      curEta = doc["eta"] | 0;
      curStreet = String(doc["street"] | "CAU SONG LU");
      curArrival = String(doc["arrival"] | "12:05");
      if (doc["head"].is<int>()) curHeading = doc["head"];

      display.setNavData(curTurn, curDist, curTotalDist, curSpeed, curEta, curStreet.c_str(), curArrival.c_str());
    }
  }
};

// =========================================================================
// Setup & Loop
// =========================================================================
void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("\n=== ESP32-S3 SMART NAVIGATOR (IMAGE 3 100% MATCH) ===");

  // 1. Start Display
  display.init();
  #if defined(DISPLAY_TFT_ST7789)
  TJpgDec.setJpgScale(1);
  TJpgDec.setSwapBytes(false);
  TJpgDec.setCallback(tft_output);
  #endif

  // 2. Start NimBLE Server (Max MTU 517 for High-Speed BLE Stream)
  NimBLEDevice::init("ESP32_NAV_ANCS");
  NimBLEDevice::setMTU(517);
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);

  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  NimBLEService* pNavService = pServer->createService(navServiceUUID);
  pNavChar = pNavService->createCharacteristic(
    navCharUUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );
  pNavChar->setCallbacks(new NavCharCallbacks());
  pNavService->start();

  NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(navServiceUUID);
  pAdvertising->setMinInterval(16); // 10ms fast advertising
  pAdvertising->setMaxInterval(32); // 20ms
  pAdvertising->setMinPreferred(6); // 7.5ms min interval
  pAdvertising->setMaxPreferred(12); // 15ms max interval
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  Serial.println("[BLE] ESP32 da san sang nhan luong 20 FPS qua Bluetooth BLE (MTU 517)!");
}

void loop() {
  bool isStreaming = (millis() - lastFrameTime < 2500);
  display.update(isStreaming);
  delay(5);
}
