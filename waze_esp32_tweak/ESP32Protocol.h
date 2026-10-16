#ifndef ESP32_PROTOCOL_H
#define ESP32_PROTOCOL_H

#import <Foundation/Foundation.h>

#define NAV_MAGIC_HEADER 0xAA
#define MAX_STREET_NAME_LEN 32

// BLE GATT Service & Characteristic UUIDs matching ESP32 firmware
#define ESP32_NAV_SERVICE_UUID @"0000FFE0-0000-1000-8000-00805F9B34FB"
#define ESP32_NAV_CHAR_UUID    @"0000FFE1-0000-1000-8000-00805F9B34FB"

// Maneuver icon codes matching firmware NavManeuverIcon enum
typedef NS_ENUM(uint8_t, NavManeuverIcon) {
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

// Binary packet structure packed with zero padding (100% matched with ESP32 nav_packet_parser.h)
#pragma pack(push, 1)
struct NavBinaryPacket {
    uint8_t header;                               // 0xAA
    uint8_t maneuverIcon;                         // 0..8
    uint32_t distanceToTurn;                      // Meters (Little Endian)
    uint32_t remainingDistance;                   // Meters (Little Endian)
    uint32_t remainingEta;                        // Seconds (Little Endian)
    uint8_t currentSpeed;                         // km/h
    uint8_t speedLimit;                           // km/h
    uint8_t nextStreetNameLen;                    // Length N
    char nextStreetName[MAX_STREET_NAME_LEN];     // Variable string
    uint8_t checksum;                             // XOR of all preceding bytes
};
#pragma pack(pop)

#endif /* ESP32_PROTOCOL_H */
