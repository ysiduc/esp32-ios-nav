#ifndef DISPLAY_UI_H
#define DISPLAY_UI_H

#include <Arduino.h>
#include "icons.h"

#if defined(DISPLAY_OLED_SSD1306)
#include <U8g2lib.h>
#include <Wire.h>
extern U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2;

#elif defined(DISPLAY_TFT_ST7789)
#include <TFT_eSPI.h>
extern TFT_eSPI tft;
#endif

enum DisplayState {
  STATE_PAIRING_WAIT,
  STATE_NAVIGATION,
  STATE_POPUP_CALL,
  STATE_POPUP_SMS
};

struct NavStateData {
  uint8_t turnCode = 6;       // 6 = Turn Left (as in user image), 2 = Turn Right
  uint16_t distMeters = 208;
  uint16_t totalDistMeters = 5900;
  uint8_t speedKmh = 0;
  uint8_t etaMinutes = 11;
  char streetName[48] = "CAU SONG LU";
  char arrivalTime[16] = "12:05";
  bool isConnected = false;
};

struct AncsPopupData {
  char title[32] = "";
  char message[64] = "";
  uint32_t expireMillis = 0;
};

class DisplayManager {
private:
  DisplayState _currentState = STATE_PAIRING_WAIT;
  NavStateData _navData;
  AncsPopupData _popupData;
  bool _needFullRedraw = true;
  unsigned long _lastRenderTime = 0;

public:
  void init() {
#if defined(DISPLAY_OLED_SSD1306)
    u8g2.begin();
    u8g2.enableUTF8Print();
    u8g2.setFontMode(0);
#elif defined(DISPLAY_TFT_ST7789)
    #if defined(TFT_BL) && TFT_BL >= 0
    pinMode(TFT_BL, OUTPUT);
    digitalWrite(TFT_BL, HIGH);
    #endif
    tft.init();
    tft.setRotation(1); // Landscape 320x240
    tft.invertDisplay(false);
    tft.fillScreen(0x0000); // Deep Black
    _drawPairingScreenTft();
#endif
  }

  void setNavData(uint8_t turn, uint16_t dist, uint16_t totalDist, uint8_t speed, uint8_t eta, const char* street, const char* arrival = "12:05") {
    _navData.turnCode = turn;
    _navData.distMeters = dist;
    _navData.totalDistMeters = totalDist;
    _navData.speedKmh = speed;
    _navData.etaMinutes = eta;
    strncpy(_navData.streetName, street, sizeof(_navData.streetName) - 1);
    _navData.streetName[sizeof(_navData.streetName) - 1] = '\0';
    strncpy(_navData.arrivalTime, arrival, sizeof(_navData.arrivalTime) - 1);
    _navData.arrivalTime[sizeof(_navData.arrivalTime) - 1] = '\0';

    if (_currentState != STATE_POPUP_CALL && _currentState != STATE_POPUP_SMS) {
      _currentState = STATE_NAVIGATION;
      _needFullRedraw = true;
    }
  }

  void setBleConnected(bool connected) {
    if (_navData.isConnected != connected) {
      _needFullRedraw = true;
    }
    _navData.isConnected = connected;
    if (!connected && _currentState == STATE_NAVIGATION) {
      _currentState = STATE_PAIRING_WAIT;
      _needFullRedraw = true;
    } else if (connected && _currentState == STATE_PAIRING_WAIT) {
      _currentState = STATE_NAVIGATION;
      _needFullRedraw = true;
    }
  }

  void showCallAlert(const char* callerName) {
    strncpy(_popupData.title, callerName, sizeof(_popupData.title) - 1);
    _popupData.expireMillis = millis() + 8000;
    _currentState = STATE_POPUP_CALL;
    _needFullRedraw = true;
  }

  void showSmsAlert(const char* sender, const char* msg) {
    strncpy(_popupData.title, sender, sizeof(_popupData.title) - 1);
    strncpy(_popupData.message, msg, sizeof(_popupData.message) - 1);
    _popupData.expireMillis = millis() + 6000;
    _currentState = STATE_POPUP_SMS;
    _needFullRedraw = true;
  }

  void update(bool isStreamingActive = false) {
    if ((_currentState == STATE_POPUP_CALL || _currentState == STATE_POPUP_SMS) && millis() > _popupData.expireMillis) {
      _currentState = _navData.isConnected ? STATE_NAVIGATION : STATE_PAIRING_WAIT;
      _needFullRedraw = true;
    }

#if defined(DISPLAY_OLED_SSD1306)
    _renderOled();
#elif defined(DISPLAY_TFT_ST7789)
    if (_needFullRedraw || millis() - _lastRenderTime > 1000) {
      _renderTft(isStreamingActive);
      _lastRenderTime = millis();
      _needFullRedraw = false;
    }
#endif
  }

private:
#if defined(DISPLAY_OLED_SSD1306)
  void _renderOled() {
    u8g2.clearBuffer();
    u8g2.sendBuffer();
  }
#endif

#if defined(DISPLAY_TFT_ST7789)
  void _drawPairingScreenTft() {
    tft.fillScreen(0x0000);

    // Top Status bar
    tft.setTextColor(0x07FF, 0x0000);
    tft.drawString("* ESP32 BLE", 10, 4, 2);
    tft.setTextColor(0xFFFF, 0x0000);
    tft.drawCentreString("11:54", 160, 4, 2);
    tft.setTextColor(0x07E0, 0x0000);
    tft.drawString("100%", 265, 4, 2);
    tft.drawRect(298, 6, 14, 8, 0x07E0);
    tft.fillRect(300, 8, 10, 4, 0x07E0);

    // Center Main Card
    tft.fillRoundRect(14, 26, 292, 202, 12, 0x131B);
    tft.drawRoundRect(14, 26, 292, 202, 12, 0x07FF);

    tft.setTextColor(0x07FF, 0x131B);
    tft.drawCentreString("ESP32 SMART NAVIGATOR", 160, 42, 4);

    tft.setTextColor(0x07E0, 0x131B);
    tft.drawCentreString("STREAM MAP 20 FPS (ZOOM x16)", 160, 76, 2);

    tft.setTextColor(0xFFFF, 0x131B);
    tft.drawString("1. Mo App tren dien thoai", 34, 110, 2);
    tft.drawString("2. Ket noi: ESP32_NAV_ANCS", 34, 138, 2);
    tft.drawString("3. Bat 'Mo phong Man hinh ESP32'", 34, 166, 2);
  }

  void _renderTft(bool isStreamingActive) {
    if (_currentState == STATE_PAIRING_WAIT) {
      _drawPairingScreenTft();
      return;
    }

    if (_currentState == STATE_POPUP_CALL) {
      tft.fillRoundRect(15, 20, 290, 200, 16, 0x01E0);
      tft.drawRoundRect(15, 20, 290, 200, 16, 0x07E0);
      tft.setTextColor(0x07E0, 0x01E0);
      tft.drawCentreString("CUOC GOI DEN", 160, 35, 4);
      tft.setTextColor(0xFFFF, 0x01E0);
      tft.drawCentreString(_popupData.title, 160, 95, 4);
      tft.setTextColor(0x07FF, 0x01E0);
      tft.drawCentreString("Apple ANCS Notification", 160, 165, 2);
      return;
    }

    if (_currentState == STATE_POPUP_SMS) {
      tft.fillRoundRect(15, 20, 290, 200, 16, 0x0014);
      tft.drawRoundRect(15, 20, 290, 200, 16, 0x07FF);
      tft.setTextColor(0x07FF, 0x0014);
      tft.drawCentreString("TIN NHAN MOI", 160, 35, 4);
      tft.setTextColor(0xFFE0, 0x0014);
      tft.drawCentreString(_popupData.title, 160, 85, 4);
      tft.setTextColor(0xFFFF, 0x0014);
      tft.drawCentreString(_popupData.message, 160, 135, 2);
      return;
    }

    // =========================================================================
    // STATE_NAVIGATION: EXACT 100% REPLICA OF TARGET DESIGN
    // =========================================================================
    
    // 1. TOP HARDWARE STATUS BAR (y: 0 to 22)
    tft.fillRect(0, 0, 320, 22, 0x0000);
    tft.setTextColor(0x07FF, 0x0000);   // Cyan
    tft.drawString("* ESP32 BLE", 10, 4, 2);
    tft.setTextColor(0xFFFF, 0x0000);  // White Clock
    tft.drawCentreString("11:54", 160, 4, 2);
    tft.setTextColor(0x07E0, 0x0000);  // Neon Green
    tft.drawString("100%", 265, 4, 2);
    tft.drawRect(298, 6, 14, 8, 0x07E0);
    tft.fillRect(300, 8, 10, 4, 0x07E0);

    // 2. LEFT 50%: LIVE MINI MAP CANVAS (x: 4, y: 24, w: 150, h: 212)
    // When phone is actively streaming 20 FPS JPEG, do not overwrite canvas!
    if (!isStreamingActive) {
      tft.drawRoundRect(4, 24, 150, 212, 12, 0x07FF);
      tft.fillRoundRect(6, 26, 146, 208, 10, 0xE71C); // Light street map canvas

      // Route Path Line (Cyan neon line)
      tft.drawLine(78, 26, 78, 160, 0x07FF);
      tft.drawLine(79, 26, 79, 160, 0x07FF);
      tft.drawLine(80, 26, 80, 160, 0x07FF);
      tft.drawLine(81, 26, 81, 160, 0x07FF);

      // Vehicle Location Marker
      tft.drawCircle(80, 110, 15, 0x03FF);
      tft.fillCircle(80, 110, 10, 0x001F);
      tft.drawCircle(80, 110, 10, 0xFFFF);
      tft.fillTriangle(80, 104, 76, 113, 84, 113, 0xFFFF);

      // MAP LIVE Badge (Bottom-left pill)
      tft.fillRoundRect(10, 208, 56, 18, 4, 0x0000);
      tft.setTextColor(0x07E0, 0x0000);
      tft.drawString("MAP LIVE", 14, 211, 1);
    }

    // 3. RIGHT 50%: HUD NAVIGATION CARDS (x: 158, y: 24, w: 158, h: 212)
    // Outer Card Container
    tft.fillRoundRect(158, 24, 158, 212, 12, 0x131B);
    tft.drawRoundRect(158, 24, 158, 212, 12, 0x202D);

    // --- SECTION A: Maneuver Icon + Turn Distance + Speed (y: 28 to 86) ---
    tft.fillRoundRect(164, 30, 46, 46, 10, 0x0E15);
    tft.drawRoundRect(164, 30, 46, 46, 10, 0x07FF);

    const uint8_t* icon = icon_turn_left_32x32;
    switch (_navData.turnCode) {
      case 0: icon = icon_straight_32x32; break;
      case 1: case 2: case 3: icon = icon_turn_right_32x32; break;
      case 4: icon = icon_straight_32x32; break;
      case 5: case 6: case 7: icon = icon_turn_left_32x32; break;
      case 8: icon = icon_roundabout_32x32; break;
      case 9: icon = icon_arrive_32x32; break;
      default: icon = icon_turn_left_32x32; break;
    }
    tft.drawXBitmap(171, 37, icon, 32, 32, 0x07FF, 0x0E15);

    // Distance text (e.g. "208m")
    tft.setTextColor(0xFFFF, 0x131B);
    char distStr[16];
    if (_navData.distMeters >= 1000) {
      snprintf(distStr, sizeof(distStr), "%.1f km", (float)_navData.distMeters / 1000.0);
    } else {
      snprintf(distStr, sizeof(distStr), "%dm", _navData.distMeters);
    }
    tft.drawString(distStr, 218, 30, 4);

    // Speed text (e.g. "0 km/h")
    tft.setTextColor(0x07FF, 0x131B);
    char spdStr[16];
    snprintf(spdStr, sizeof(spdStr), "%d km/h", _navData.speedKmh);
    tft.drawString(spdStr, 218, 58, 2);

    // --- SECTION B: Street Name Pill Card (y: 92 to 140) ---
    tft.fillRoundRect(164, 92, 146, 44, 8, 0x0B11);
    tft.drawRoundRect(164, 92, 146, 44, 8, 0x1E29);
    tft.setTextColor(0xFFE0, 0x0B11); // Bright Gold/Yellow
    tft.drawString(_navData.streetName, 172, 106, 2);

    // --- SECTION C: ETA & Total Distance (y: 150 to 226) ---
    // Sub-labels
    tft.setTextColor(0x6474, 0x131B); // Grey
    tft.drawString("DU KIEN", 168, 154, 1);

    char totDistStr[16];
    if (_navData.totalDistMeters >= 1000) {
      snprintf(totDistStr, sizeof(totDistStr), "%.1f km", (float)_navData.totalDistMeters / 1000.0);
    } else {
      snprintf(totDistStr, sizeof(totDistStr), "%d m", _navData.totalDistMeters);
    }
    tft.drawRightString(totDistStr, 304, 154, 1);

    // Main values
    tft.setTextColor(0x07FF, 0x131B); // Cyan
    tft.drawString(_navData.arrivalTime, 168, 174, 4);

    tft.setTextColor(0x07E0, 0x131B); // Neon Green
    char etaStr[16];
    snprintf(etaStr, sizeof(etaStr), "%d ph", _navData.etaMinutes);
    tft.drawRightString(etaStr, 304, 174, 4);
  }
#endif
};

#endif
