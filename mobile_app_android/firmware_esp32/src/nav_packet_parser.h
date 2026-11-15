#ifndef NAV_PACKET_PARSER_H
#define NAV_PACKET_PARSER_H

#include <Arduino.h>

#define NAV_MAGIC_HEADER 0xAA
#define MAX_STREET_NAME_LEN 32

// Maneuver icon codes matching iOS Swift enum
enum NavManeuverIcon : uint8_t {
    MANEUVER_NONE = 0,
    MANEUVER_STRAIGHT = 1,
    MANEUVER_SLIGHT_RIGHT = 2,
    MANEUVER_RIGHT = 3,
    MANEUVER_SHARP_RIGHT = 4,
    MANEUVER_UTURN = 5,
    MANEUVER_LEFT = 6,
    MANEUVER_ROUNDABOUT = 7,
    MANEUVER_ARRIVE = 8
};

// Binary packet structure packed with zero padding
struct __attribute__((packed)) NavBinaryPacket {
    uint8_t header;              // 0xAA
    uint8_t maneuverIcon;        // 0..8
    uint32_t distanceToTurn;     // Meters (Little Endian)
    uint32_t remainingDistance;  // Meters (Little Endian)
    uint32_t remainingEta;       // Seconds (Little Endian)
    uint8_t currentSpeed;        // km/h
    uint8_t speedLimit;          // km/h
    uint8_t nextStreetNameLen;   // Length N
    char nextStreetName[MAX_STREET_NAME_LEN]; // Variable / fixed buffer
    uint8_t checksum;            // XOR of all preceding bytes
};

class NavPacketParser {
public:
    /// Unpack and validate a raw binary payload received over BLE
    static bool parse(const uint8_t* data, size_t len, NavBinaryPacket* outPacket) {
        // Minimum packet length: 1(header) + 1(icon) + 4(dist) + 4(remDist) + 4(eta) + 1(spd) + 1(spdLim) + 1(strLen) + 0(str) + 1(checksum) = 14 bytes
        if (data == nullptr || len < 14) {
            return false;
        }

        // 1. Verify Magic Header
        if (data[0] != NAV_MAGIC_HEADER) {
            return false;
        }

        // 2. Verify XOR Checksum
        uint8_t calculatedChecksum = 0;
        for (size_t i = 0; i < len - 1; ++i) {
            calculatedChecksum ^= data[i];
        }

        uint8_t receivedChecksum = data[len - 1];
        if (calculatedChecksum != receivedChecksum) {
            Serial.printf("[NavParser] Checksum mismatch: calc=0x%02X, recv=0x%02X\n", calculatedChecksum, receivedChecksum);
            return false;
        }

        // 3. Unpack fixed fields (Little Endian)
        outPacket->header = data[0];
        outPacket->maneuverIcon = data[1];

        memcpy(&outPacket->distanceToTurn, &data[2], 4);
        memcpy(&outPacket->remainingDistance, &data[6], 4);
        memcpy(&outPacket->remainingEta, &data[10], 4);

        outPacket->currentSpeed = data[14];
        outPacket->speedLimit = data[15];
        outPacket->nextStreetNameLen = data[16];

        // 4. Extract string payload
        size_t strLen = outPacket->nextStreetNameLen;
        if (strLen > MAX_STREET_NAME_LEN - 1) {
            strLen = MAX_STREET_NAME_LEN - 1;
        }

        // Check buffer bounds
        if (17 + strLen < len) {
            memcpy(outPacket->nextStreetName, &data[17], strLen);
            outPacket->nextStreetName[strLen] = '\0';
        } else {
            outPacket->nextStreetName[0] = '\0';
        }

        outPacket->checksum = receivedChecksum;
        return true;
    }

    /// Helper to format remaining duration (e.g. "12m" or "1h 15m")
    static void formatEta(uint32_t totalSeconds, char* outBuffer, size_t maxLen) {
        uint32_t mins = totalSeconds / 60;
        if (mins >= 60) {
            uint32_t hours = mins / 60;
            uint32_t remainMins = mins % 60;
            snprintf(outBuffer, maxLen, "%luh %lum", (unsigned long)hours, (unsigned long)remainMins);
        } else {
            snprintf(outBuffer, maxLen, "%lum", (unsigned long)mins);
        }
    }

    /// Helper to format distances (e.g. "450 m" or "2.4 km")
    static void formatDistance(uint32_t meters, char* outBuffer, size_t maxLen) {
        if (meters >= 1000) {
            float km = (float)meters / 1000.0f;
            snprintf(outBuffer, maxLen, "%.1f km", km);
        } else {
            snprintf(outBuffer, maxLen, "%lu m", (unsigned long)meters);
        }
    }
};

#endif // NAV_PACKET_PARSER_H
