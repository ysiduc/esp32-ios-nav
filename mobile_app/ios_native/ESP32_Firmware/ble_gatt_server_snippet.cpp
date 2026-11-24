#include <Arduino.h>
#include <NimBLEDevice.h>
#include "nav_packet_parser.h"

// Custom 128-bit UUID definitions matching iOS Central Manager
#define NAV_SERVICE_UUID        "0000FFF0-0000-1000-8000-00805F9B34FB"
#define NAV_DATA_CHAR_UUID      "0000FFF1-0000-1000-8000-00805F9B34FB"
#define NAV_STATUS_CHAR_UUID    "0000FFF2-0000-1000-8000-00805F9B34FB"

static NimBLEServer* pServer = nullptr;
static NimBLECharacteristic* pNavDataChar = nullptr;
static NimBLECharacteristic* pNavStatusChar = nullptr;
static bool deviceConnected = false;

// Forward declaration of display update function
void updateNavigationDisplay(const NavBinaryPacket& packet);

/**
 * Server Callbacks for Connection Management
 */
class NavigationServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) override {
        deviceConnected = true;
        Serial.printf("[BLE] iPhone Connected! conn_handle=%d\n", desc->conn_handle);
    }

    void onDisconnect(NimBLEServer* pServer) override {
        deviceConnected = false;
        Serial.println("[BLE] iPhone Disconnected. Restarting advertising...");
        NimBLEDevice::startAdvertising();
    }
};

/**
 * Characteristic Callbacks for Incoming Binary Packets
 */
class NavigationDataCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pCharacteristic) override {
        std::string rawData = pCharacteristic->getValue();
        const uint8_t* bytes = reinterpret_cast<const uint8_t*>(rawData.data());
        size_t length = rawData.length();

        NavBinaryPacket packet;
        if (NavPacketParser::parse(bytes, length, &packet)) {
            Serial.printf("[BLE] Nav Packet Received! Icon=%d, Dist=%lu m, Next: %s, Speed=%d km/h\n",
                          packet.maneuverIcon,
                          (unsigned long)packet.distanceToTurn,
                          packet.nextStreetName,
                          packet.currentSpeed);

            // Dispatch parsed data to display handler
            updateNavigationDisplay(packet);
        } else {
            Serial.printf("[BLE] Invalid packet received (len=%u)\n", (unsigned int)length);
        }
    }
};

/**
 * Mock/Example Display Handler updating TFT/OLED Screen
 */
void updateNavigationDisplay(const NavBinaryPacket& packet) {
    char etaStr[16];
    char distStr[16];
    char remDistStr[16];

    NavPacketParser::formatDistance(packet.distanceToTurn, distStr, sizeof(distStr));
    NavPacketParser::formatDistance(packet.remainingDistance, remDistStr, sizeof(remDistStr));
    NavPacketParser::formatEta(packet.remainingEta, etaStr, sizeof(etaStr));

    // Example rendering log
    Serial.println("================= DISPLAY HUD =================");
    Serial.printf(" MANEUVER ICON : %u\n", packet.maneuverIcon);
    Serial.printf(" DISTANCE NEXT : %s\n", distStr);
    Serial.printf(" NEXT STREET   : %s\n", packet.nextStreetName);
    Serial.printf(" REMAINING     : %s (ETA: %s)\n", remDistStr, etaStr);
    Serial.printf(" SPEED         : %u km/h\n", packet.currentSpeed);
    Serial.println("===============================================");

    // TODO: Call your actual TFT display functions:
    // display.drawTurnIcon(packet.maneuverIcon);
    // display.drawDistance(distStr);
    // display.drawStreetName(packet.nextStreetName);
    // display.drawEta(etaStr);
}

/**
 * Initialize NimBLE GATT Server
 */
void setupNavigationBLE() {
    Serial.println("[BLE] Initializing ESP32-S3 Navigation GATT Server...");

    // 1. Initialize NimBLE
    NimBLEDevice::init("ESP32-NAV");
    NimBLEDevice::setPower(ESP_PWR_LVL_P9); // Max TX power for motorcycle mount

    // 2. Create Server & Callbacks
    pServer = NimBLEDevice::createServer();
    pServer->setCallbacks(new NavigationServerCallbacks());

    // 3. Create Navigation Service
    NimBLEService* pNavService = pServer->createService(NAV_SERVICE_UUID);

    // 4. Create Navigation Data Characteristic (Write Without Response + Notify)
    pNavDataChar = pNavService->createCharacteristic(
        NAV_DATA_CHAR_UUID,
        NIMBLE_PROPERTY::WRITE |
        NIMBLE_PROPERTY::WRITE_NR |
        NIMBLE_PROPERTY::NOTIFY
    );
    pNavDataChar->setCallbacks(new NavigationDataCallbacks());

    // 5. Create Device Status Characteristic (Read / Write)
    pNavStatusChar = pNavService->createCharacteristic(
        NAV_STATUS_CHAR_UUID,
        NIMBLE_PROPERTY::READ |
        NIMBLE_PROPERTY::WRITE
    );
    uint8_t initialStatus[2] = {0x01, 0x00}; // Ready
    pNavStatusChar->setValue(initialStatus, 2);

    // 6. Start Service
    pNavService->start();

    // 7. Setup Advertising
    NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(NAV_SERVICE_UUID);
    pAdvertising->setName("ESP32-NAV");
    pAdvertising->setScanResponse(true);
    pAdvertising->setMinPreferred(0x06); // Functions for iPhone connections
    pAdvertising->setMaxPreferred(0x12);

    NimBLEDevice::startAdvertising();
    Serial.println("[BLE] Advertising started. Waiting for iPhone connection...");
}
