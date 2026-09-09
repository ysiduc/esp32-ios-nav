#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include "display_ui.h"

// UUIDs for Apple Notification Center Service (ANCS)
static NimBLEUUID ancsServiceUUID("7905F431-B5CE-4E99-A40F-4B1E122D00D0");
static NimBLEUUID notifSourceUUID("9FBF120D-6301-42D9-8C58-25E699A21DBD");
static NimBLEUUID controlPointUUID("69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9");
static NimBLEUUID dataSourceUUID("22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB");

// UUIDs for Custom Navigation Service
static NimBLEUUID navServiceUUID("0000FFE0-0000-1000-8000-00805F9B34FB");
static NimBLEUUID navCharUUID("0000FFE1-0000-1000-8000-00805F9B34FB");

#if defined(DISPLAY_OLED_SSD1306)
U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2(U8G2_R0, /* reset=*/ U8X8_PIN_NONE, /* clock=*/ 22, /* data=*/ 21);
#elif defined(DISPLAY_TFT_ST7789)
TFT_eSPI tft = TFT_eSPI();
#endif

DisplayManager display;
NimBLEServer* pServer = nullptr;
NimBLECharacteristic* pNavChar = nullptr;
bool deviceConnected = false;

// ANCS State Variables
uint32_t lastNotifUID = 0;
uint8_t lastCategoryID = 0;

// Forward Declarations
void handleAncsNotification(uint8_t eventID, uint8_t eventFlags, uint8_t categoryID, uint8_t categoryCount, uint32_t notifUID);

// -------------------------------------------------------------
// 1. BLE Server Callbacks (Connection / Disconnection)
// -------------------------------------------------------------
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer) {
    deviceConnected = true;
    display.setBleConnected(true);
    Serial.println("[BLE] iPhone da ket noi!");
  }

  void onDisconnect(NimBLEServer* pServer) {
    deviceConnected = false;
    display.setBleConnected(false);
    Serial.println("[BLE] Da ngat ket noi. Dang phat quang ba lai...");
    NimBLEDevice::startAdvertising();
  }
};

// -------------------------------------------------------------
// 2. Custom Navigation Characteristic Callback (Receiving JSON from Flutter)
// -------------------------------------------------------------
class NavCharCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic) {
    std::string value = pCharacteristic->getValue();
    if (value.length() == 0) return;

    Serial.printf("[BLE RX Nav]: %s\n", value.c_str());

    // Parse JSON with ArduinoJson
    JsonDocument doc;
    DeserializationError error = deserializeJson(doc, value.c_str());

    if (!error) {
      uint8_t turn = doc["turn"] | 0;
      uint16_t dist = doc["dist"] | 0;
      uint16_t totalDist = doc["tot_dist"] | 0;
      uint8_t speed = doc["speed"] | 0;
      uint8_t eta = doc["eta"] | 0;
      const char* street = doc["street"] | "Tiep tuc";

      display.setNavData(turn, dist, totalDist, speed, eta, street);
    } else {
      Serial.printf("[JSON] Loi parse JSON: %s\n", error.c_str());
    }
  }
};

// -------------------------------------------------------------
// 3. ANCS Notification Callback (Incoming Call & SMS from iOS)
// -------------------------------------------------------------
void onAncsNotifNotify(BLERemoteCharacteristic* pBLERemoteCharacteristic, uint8_t* pData, size_t length, bool isNotify) {
  if (length >= 8) {
    uint8_t eventID = pData[0];        // 0: Added, 1: Modified, 2: Removed
    uint8_t eventFlags = pData[1];
    uint8_t categoryID = pData[2];     // 1: Call, 4: Social/SMS, 6: Email...
    uint8_t categoryCount = pData[3];
    uint32_t notifUID = pData[4] | (pData[5] << 8) | (pData[6] << 16) | (pData[7] << 24);

    Serial.printf("[ANCS] Event: %d, Category: %d, UID: %u\n", eventID, categoryID, notifUID);

    if (eventID == 0) { // New Notification
      if (categoryID == 1) {
        // Category 1: Incoming Call (Cuoc goi den)
        Serial.println("[ANCS] >>> PHAT HIEN CUOC GOI DEN TU IPHONE <<<");
        display.showCallAlert("CUOC GOI IPHONE");
      } else if (categoryID == 4 || categoryID == 6 || categoryID == 2) {
        // Category 4: SMS / Social (Tin nhan)
        Serial.println("[ANCS] >>> PHAT HIEN TIN NHAN SMS / ZALO <<<");
        display.showSmsAlert("TIN NHAN MOI", "Co thong bao moi tren iPhone");
      }
    }
  }
}

// -------------------------------------------------------------
// 4. Setup BLE Services & Security
// -------------------------------------------------------------
void setupBle() {
  NimBLEDevice::init("ESP32_NAV_ANCS");

  // ANCS requires Encryption and Bonding with iPhone
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);

  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  // Create Custom Navigation GATT Service
  NimBLEService* pNavService = pServer->createService(navServiceUUID);
  pNavChar = pNavService->createCharacteristic(
    navCharUUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );
  pNavChar->setCallbacks(new NavCharCallbacks());
  pNavService->start();

  // Setup Advertising
  NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(navServiceUUID);
  pAdvertising->addServiceUUID(ancsServiceUUID); // Advertise ANCS Solicitation
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  Serial.println("[BLE] ESP32 da bat dau phat Bluetooth (ANCS + Navigation)!");
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n=== ESP32 IOS NAVIGATION & ANCS INITIALIZING ===");

  display.init();
  setupBle();
}

void loop() {
  display.update();
  delay(40); // ~25 FPS UI refresh loop
}
