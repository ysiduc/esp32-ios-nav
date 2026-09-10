#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <TFT_eSPI.h>
#include <TJpg_Decoder.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include "config.h"

// Hardware display instance
TFT_eSPI tft = TFT_eSPI();

// BLE State
bool deviceConnected = false;
NimBLEServer* pServer = nullptr;
NimBLECharacteristic* pNavCharacteristic = nullptr;

// Wi-Fi & Stream State
HTTPClient http;
WiFiClient* stream = nullptr;
bool isWifiConnected = false;
bool isStreamActive = false;

// Navigation Data Fallback State
int currentTurnCode = 0;
int currentDistance = 0;
int currentSpeed = 0;
String currentStreet = "San sang";
String currentArrival = "--:--";
int currentEta = 0;
int totalDistance = 0;

// Frame rate tracking
unsigned long lastFpsCheck = 0;
int frameCounter = 0;
float currentFps = 0.0;

// JPEG Buffer for BLE Chunks
#define MAX_JPEG_BUF_SIZE (64 * 1024)
uint8_t jpegBuffer[MAX_JPEG_BUF_SIZE];
size_t jpegBufferLen = 0;
int lastFrameId = -1;

// =========================================================================
// TJpg_Decoder Callback: Render 16x16 Pixel Blocks to Screen at High Speed
// =========================================================================
bool tft_output(int16_t x, int16_t y, uint16_t w, uint16_t h, uint16_t* bitmap) {
  if (y >= tft.height()) return 0;
  tft.pushImage(x, y, w, h, bitmap);
  return 1;
}

// =========================================================================
// BLE Callbacks
// =========================================================================
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer) {
    deviceConnected = true;
    Serial.println("[BLE] Phone Connected!");
  }

  void onDisconnect(NimBLEServer* pServer) {
    deviceConnected = false;
    Serial.println("[BLE] Phone Disconnected. Advertising...");
    NimBLEDevice::startAdvertising();
  }
};

class NavCharCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic) {
    std::string rxValue = pCharacteristic->getValue();
    if (rxValue.length() == 0) return;

    // Check for Binary Chunked JPEG Packet (Magic 0xAA 0xBB)
    if (rxValue.length() > 5 && (uint8_t)rxValue[0] == 0xAA && (uint8_t)rxValue[1] == 0xBB) {
      uint8_t frameId = (uint8_t)rxValue[2];
      uint8_t totalChunks = (uint8_t)rxValue[3];
      uint8_t chunkIdx = (uint8_t)rxValue[4];

      if (frameId != lastFrameId) {
        lastFrameId = frameId;
        jpegBufferLen = 0;
      }

      size_t payloadLen = rxValue.length() - 5;
      if (jpegBufferLen + payloadLen < MAX_JPEG_BUF_SIZE) {
        memcpy(jpegBuffer + jpegBufferLen, rxValue.data() + 5, payloadLen);
        jpegBufferLen += payloadLen;
      }

      // If last chunk received, decode and draw to screen
      if (chunkIdx == totalChunks - 1 && jpegBufferLen > 10) {
        TJpgDec.drawJpg(0, 0, jpegBuffer, jpegBufferLen);
        frameCounter++;
      }
      return;
    }

    // JSON Navigation Telemetry Fallback
    JsonDocument doc;
    DeserializationError error = deserializeJson(doc, rxValue);
    if (!error) {
      currentTurnCode = doc["turn"] | 0;
      currentDistance = doc["dist"] | 0;
      currentSpeed = doc["speed"] | 0;
      currentStreet = doc["street"] | "San sang";
      currentEta = doc["eta"] | 0;
      currentArrival = doc["arrival"] | "--:--";
      totalDistance = doc["tot_dist"] | 0;

      // If not currently streaming Wi-Fi video, render local 50/50 UI
      if (!isStreamActive) {
        renderLocalHud();
      }
    }
  }
};

// =========================================================================
// Local 50/50 HUD Renderer (When Wi-Fi stream is offline)
// =========================================================================
void renderLocalHud() {
  tft.startWrite();

  // Right Side background (160..320)
  int halfW = tft.width() / 2;
  tft.fillRect(halfW, 0, halfW, tft.height(), 0x1123); // Dark slate

  // Turn Arrow & Distance
  tft.setTextColor(TFT_CYAN, 0x1123);
  tft.setTextSize(2);
  tft.setCursor(halfW + 10, 15);
  
  if (currentDistance >= 1000) {
    tft.printf("%.1f km", currentDistance / 1000.0);
  } else {
    tft.printf("%d m", currentDistance);
  }

  // Speed
  tft.setTextColor(TFT_GREEN, 0x1123);
  tft.setTextSize(1);
  tft.setCursor(halfW + 10, 40);
  tft.printf("%d km/h", currentSpeed);

  // Street Name
  tft.setTextColor(TFT_YELLOW, 0x0841);
  tft.fillRect(halfW + 6, 60, halfW - 12, 22, 0x0841);
  tft.setCursor(halfW + 10, 66);
  tft.print(currentStreet.substring(0, 16));

  // ETA & Arrival Time
  tft.setTextColor(TFT_WHITE, 0x1123);
  tft.setCursor(halfW + 10, 95);
  tft.printf("DEN: %s", currentArrival.c_str());
  tft.setCursor(halfW + 10, 110);
  tft.printf("CON: %d ph", currentEta);

  tft.endWrite();
}

// =========================================================================
// Wi-Fi MJPEG Stream Consumer (High-Speed 20 FPS Receiver)
// =========================================================================
void processMjpegStream() {
  if (!isWifiConnected) return;

  if (!isStreamActive) {
    Serial.printf("[HTTP] Connecting to Stream: %s...\n", MJPEG_STREAM_URL);
    http.begin(MJPEG_STREAM_URL);
    http.setTimeout(3000);
    int httpCode = http.GET();

    if (httpCode == HTTP_CODE_OK) {
      Serial.println("[HTTP] Stream Connected! Receiving 20 FPS frames...");
      stream = http.getStreamPtr();
      isStreamActive = true;
    } else {
      Serial.printf("[HTTP] Connect failed (code %d). Retrying in 2s...\n", httpCode);
      http.end();
      delay(2000);
      return;
    }
  }

  // Parse MJPEG Boundary and Read JPEG Frame
  if (stream != nullptr && stream->available()) {
    // Locate JPEG SOI (Start of Image 0xFF 0xD8)
    if (stream->find("\xFF\xD8")) {
      jpegBuffer[0] = 0xFF;
      jpegBuffer[1] = 0xD8;
      size_t bytesRead = 2;

      // Read until EOI (End of Image 0xFF 0xD9)
      bool foundEoi = false;
      unsigned long timeout = millis() + 100;

      while (millis() < timeout && bytesRead < MAX_JPEG_BUF_SIZE - 2) {
        if (stream->available()) {
          uint8_t b = stream->read();
          jpegBuffer[bytesRead++] = b;

          if (b == 0xD9 && jpegBuffer[bytesRead - 2] == 0xFF) {
            foundEoi = true;
            break;
          }
        }
      }

      if (foundEoi && bytesRead > 100) {
        // Decode JPEG with Hardware Acceleration and push to TFT
        TJpgDec.drawJpg(0, 0, jpegBuffer, bytesRead);
        frameCounter++;
      }
    }
  } else {
    // Connection dropped
    isStreamActive = false;
    http.end();
  }
}

// =========================================================================
// Setup
// =========================================================================
void setup() {
  Serial.begin(115200);
  Serial.println("\n=== ESP32 Smart Bike Navigator (20 FPS Stream) ===");

  // Initialize TFT Screen
  tft.init();
  tft.setRotation(SCREEN_ROTATION);
  tft.fillScreen(TFT_BLACK);
  tft.setTextColor(TFT_CYAN, TFT_BLACK);
  tft.setTextSize(2);
  tft.drawString("ESP32 NAVIGATOR", 20, 40);
  tft.setTextSize(1);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("Khoi dong 20 FPS Stream & BLE...", 20, 80);

  // Initialize TJpg_Decoder
  TJpgDec.setJpgScale(1);
  TJpgDec.setCallback(tft_output);
  TJpgDec.setSwapBytes(true);

  // Connect to Wi-Fi for 20 FPS video streaming
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.printf("[WiFi] Connecting to %s", WIFI_SSID);

  int wifiAttempts = 0;
  while (WiFi.status() != WL_CONNECTED && wifiAttempts < 15) {
    delay(400);
    Serial.print(".");
    wifiAttempts++;
  }

  if (WiFi.status() == WL_CONNECTED) {
    isWifiConnected = true;
    Serial.printf("\n[WiFi] Connected! IP: %s\n", WiFi.localIP().toString().c_str());
    tft.drawString("WiFi: DA KET NOI", 20, 110);
  } else {
    Serial.println("\n[WiFi] Offline. Operating in BLE Mode.");
    tft.drawString("WiFi: KHONG CO (Dung BLE)", 20, 110);
  }

  // Initialize NimBLE Server
  NimBLEDevice::init(BLE_DEVICE_NAME);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9); // Max TX power
  NimBLEDevice::setMTU(256);

  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  NimBLEService* pNavService = pServer->createService(NAV_SERVICE_UUID);
  pNavCharacteristic = pNavService->createCharacteristic(
    NAV_CHAR_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );
  pNavCharacteristic->setCallbacks(new NavCharCallbacks());
  pNavService->start();

  NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(NAV_SERVICE_UUID);
  pAdvertising->setName(BLE_DEVICE_NAME);
  pAdvertising->start();

  Serial.println("[BLE] Advertising as 'ESP32_Smart_Nav'. Ready!");
  delay(1000);
  tft.fillScreen(TFT_BLACK);
}

// =========================================================================
// Main Loop (20 FPS Cycle)
// =========================================================================
void loop() {
  // If Wi-Fi is connected, consume 20 FPS MJPEG Stream
  if (isWifiConnected) {
    processMjpegStream();
  }

  // Calculate & Display Live FPS
  if (millis() - lastFpsCheck >= 1000) {
    currentFps = frameCounter * 1000.0 / (millis() - lastFpsCheck);
    if (currentFps > 0.5) {
      Serial.printf("[PERF] Live Speed: %.1f FPS\n", currentFps);
    }
    frameCounter = 0;
    lastFpsCheck = millis();
  }

  delay(1);
}
