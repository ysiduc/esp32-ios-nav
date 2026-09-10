#pragma once

#include <Arduino.h>

// =========================================================================
// 1. Wi-Fi / Hotspot Configuration (For 20 FPS MJPEG Stream)
// =========================================================================
// Set your phone hotspot SSID & password (or home Wi-Fi):
#define WIFI_SSID       "iPhone"
#define WIFI_PASSWORD   "12345678"

// Stream URL served by the Flutter App (Default port 8080):
// On iOS Personal Hotspot, the iPhone IP is usually 172.20.10.1
// On Android Personal Hotspot, the phone IP is usually 192.168.43.1 or 192.168.4.1
#define MJPEG_STREAM_URL "http://172.20.10.1:8080/stream.mjpg"

// =========================================================================
// 2. BLE Configuration (For Bluetooth Low Energy Telemetry & Chunks)
// =========================================================================
#define BLE_DEVICE_NAME     "ESP32_Smart_Nav"
#define NAV_SERVICE_UUID    "0000FFE0-0000-1000-8000-00805F9B34FB"
#define NAV_CHAR_UUID       "0000FFE1-0000-1000-8000-00805F9B34FB"

// =========================================================================
// 3. Display Configuration
// =========================================================================
#define SCREEN_ROTATION     1   // 1 or 3 for Landscape (320x240 / 240x240)
#define TARGET_FPS          20  // 20 FPS rendering target
