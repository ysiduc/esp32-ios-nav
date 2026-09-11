#ifndef DISPLAY_UI_H
#define DISPLAY_UI_H

#include <Arduino.h>

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
  uint8_t turnCode = 6;       // 6 = Turn Left, 2 = Turn Right, 0 = Straight
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
    tft.fillScreen(TFT_BLACK);
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
    if (_needFullRedraw || millis() - _lastRenderTime > 800) {
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
    tft.fillScreen(TFT_BLACK);

    // Top Status bar
    tft.setTextColor(TFT_CYAN, TFT_BLACK);
    tft.drawString("* ESP32 BLE", 10, 4, 2);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.drawCentreString("11:54", 160, 4, 2);
    tft.setTextColor(TFT_GREEN, TFT_BLACK);
    tft.drawString("100%", 265, 4, 2);
    tft.drawRect(298, 6, 14, 8, TFT_GREEN);
    tft.fillRect(300, 8, 10, 4, TFT_GREEN);

    // Center Main Card (Dark Navy Charcoal)
    uint16_t cCardBg = tft.color565(17, 24, 36);
    tft.fillRoundRect(14, 26, 292, 202, 12, cCardBg);
    tft.drawRoundRect(14, 26, 292, 202, 12, TFT_CYAN);

    tft.setTextColor(TFT_CYAN, cCardBg);
    tft.drawCentreString("ESP32 SMART NAVIGATOR", 160, 42, 4);

    tft.setTextColor(TFT_GREEN, cCardBg);
    tft.drawCentreString("STREAM MAP 20 FPS (ZOOM x16)", 160, 76, 2);

    tft.setTextColor(TFT_WHITE, cCardBg);
    tft.drawString("1. Mo App tren dien thoai", 34, 110, 2);
    tft.drawString("2. Ket noi Bluetooth: ESP32_NAV_ANCS", 34, 138, 2);
    tft.drawString("3. Bat 'Mo phong Man hinh ESP32'", 34, 166, 2);
  }

  /// Draw Anti-Aliased Clean Vector Maneuver Arrow
  void _drawManeuverArrow(int x, int y, uint8_t turnCode) {
    // Clear arrow background box
    tft.fillRoundRect(x, y, 44, 44, 8, tft.color565(14, 20, 30));
    tft.drawRoundRect(x, y, 44, 44, 8, TFT_CYAN);

    int cx = x + 22;
    int cy = y + 22;

    if (turnCode == 5 || turnCode == 6 || turnCode == 7) {
      // TURN LEFT (Image 3)
      tft.fillRect(cx + 6, cy - 6, 4, 18, TFT_CYAN);
      tft.fillRect(cx - 10, cy - 6, 18, 4, TFT_CYAN);
      tft.fillTriangle(cx - 14, cy - 4, cx - 6, cy - 11, cx - 6, cy + 3, TFT_CYAN);
    }
    else if (turnCode == 1 || turnCode == 2 || turnCode == 3) {
      // TURN RIGHT
      tft.fillRect(cx - 10, cy - 6, 4, 18, TFT_CYAN);
      tft.fillRect(cx - 8, cy - 6, 18, 4, TFT_CYAN);
      tft.fillTriangle(cx + 14, cy - 4, cx + 6, cy - 11, cx + 6, cy + 3, TFT_CYAN);
    }
    else if (turnCode == 4) {
      // U-TURN
      tft.fillRect(cx + 6, cy - 4, 4, 16, TFT_CYAN);
      tft.fillRect(cx - 8, cy - 8, 16, 4, TFT_CYAN);
      tft.fillRect(cx - 8, cy - 4, 4, 16, TFT_CYAN);
      tft.fillTriangle(cx - 6, cy + 14, cx - 12, cy + 6, cx, cy + 6, TFT_CYAN);
    }
    else if (turnCode == 8) {
      // ROUNDABOUT
      tft.drawCircle(cx, cy, 10, TFT_CYAN);
      tft.drawCircle(cx, cy, 9, TFT_CYAN);
      tft.fillTriangle(cx + 6, cy - 10, cx + 13, cy - 6, cx + 6, cy - 2, TFT_CYAN);
    }
    else if (turnCode == 9) {
      // ARRIVED / DESTINATION FLAG
      tft.fillRect(cx - 8, cy - 10, 3, 22, TFT_WHITE);
      tft.fillTriangle(cx - 5, cy - 10, cx + 10, cy - 4, cx - 5, cy + 2, TFT_CYAN);
    }
    else {
      // STRAIGHT
      tft.fillRect(cx - 2, cy - 6, 4, 18, TFT_CYAN);
      tft.fillTriangle(cx, cy - 12, cx - 8, cy - 4, cx + 8, cy - 4, TFT_CYAN);
    }
  }

  void _renderTft(bool isStreamingActive) {
    if (_currentState == STATE_PAIRING_WAIT) {
      _drawPairingScreenTft();
      return;
    }

    if (_currentState == STATE_POPUP_CALL) {
      uint16_t cCallBg = tft.color565(2, 44, 34);
      tft.fillRoundRect(15, 20, 290, 200, 16, cCallBg);
      tft.drawRoundRect(15, 20, 290, 200, 16, TFT_GREEN);
      tft.setTextColor(TFT_GREEN, cCallBg);
      tft.drawCentreString("CUOC GOI DEN", 160, 35, 4);
      tft.setTextColor(TFT_WHITE, cCallBg);
      tft.drawCentreString(_popupData.title, 160, 95, 4);
      tft.setTextColor(TFT_CYAN, cCallBg);
      tft.drawCentreString("Apple ANCS Notification", 160, 165, 2);
      return;
    }

    if (_currentState == STATE_POPUP_SMS) {
      uint16_t cSmsBg = tft.color565(11, 25, 44);
      tft.fillRoundRect(15, 20, 290, 200, 16, cSmsBg);
      tft.drawRoundRect(15, 20, 290, 200, 16, TFT_CYAN);
      tft.setTextColor(TFT_CYAN, cSmsBg);
      tft.drawCentreString("TIN NHAN MOI", 160, 35, 4);
      tft.setTextColor(TFT_YELLOW, cSmsBg);
      tft.drawCentreString(_popupData.title, 160, 85, 4);
      tft.setTextColor(TFT_WHITE, cSmsBg);
      tft.drawCentreString(_popupData.message, 160, 135, 2);
      return;
    }

    // =========================================================================
    // STATE_NAVIGATION: EXACT 100% REPLICA OF TARGET DESIGN (IMAGE 3)
    // =========================================================================
    uint16_t cCardBg = tft.color565(19, 27, 38);   // Pure Dark Charcoal (#131B26)
    uint16_t cPillBg = tft.color565(11, 17, 26);   // Deep Black Pill (#0B111A)
    uint16_t cBorder = tft.color565(32, 45, 61);   // Subtle Border (#202D3D)
    uint16_t cSubText = tft.color565(148, 163, 184); // Light Grey (#94A3B8)
    uint16_t cDimGrey = tft.color565(100, 116, 139); // Dim Grey (#64748B)

    // 1. TOP HARDWARE STATUS BAR (y: 0 to 22)
    tft.fillRect(0, 0, 320, 22, TFT_BLACK);
    tft.setTextColor(TFT_CYAN, TFT_BLACK);
    tft.drawString("* ESP32 BLE", 10, 4, 2);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.drawCentreString("11:54", 160, 4, 2);
    tft.setTextColor(TFT_GREEN, TFT_BLACK);
    tft.drawString("100%", 265, 4, 2);
    tft.drawRect(298, 6, 14, 8, TFT_GREEN);
    tft.fillRect(300, 8, 10, 4, TFT_GREEN);

    // 2. LEFT 50%: LIVE MINI MAP CANVAS (x: 4, y: 24, w: 148, h: 212)
    // NO FAKE VIRTUAL MAP! ONLY real streamed JPEG from iOS App!
    if (!isStreamingActive) {
      tft.drawRoundRect(4, 24, 148, 212, 12, TFT_CYAN);
      tft.fillRoundRect(6, 26, 144, 208, 10, tft.color565(14, 20, 28)); // Dark waiting background

      tft.setTextColor(TFT_CYAN, tft.color565(14, 20, 28));
      tft.drawCentreString("CHO STREAM MAP", 78, 100, 2);
      tft.setTextColor(TFT_GREEN, tft.color565(14, 20, 28));
      tft.drawCentreString("20 FPS BLE", 78, 124, 2);

      // MAP LIVE Badge (Bottom-left pill)
      tft.fillRoundRect(10, 208, 56, 18, 4, TFT_BLACK);
      tft.setTextColor(TFT_GREEN, TFT_BLACK);
      tft.drawString("MAP LIVE", 14, 211, 1);
    }

    // 3. RIGHT 50%: HUD NAVIGATION CARDS (x: 158, y: 24, w: 158, h: 212)
    tft.fillRoundRect(158, 24, 158, 212, 12, cCardBg);
    tft.drawRoundRect(158, 24, 158, 212, 12, cBorder);

    // --- SECTION A: Maneuver Icon + Turn Distance + Speed (y: 30 to 86) ---
    _drawManeuverArrow(164, 30, _navData.turnCode);

    // Distance text (e.g. "208m")
    tft.setTextColor(TFT_WHITE, cCardBg);
    char distStr[16];
    if (_navData.distMeters >= 1000) {
      snprintf(distStr, sizeof(distStr), "%.1f km", (float)_navData.distMeters / 1000.0);
    } else {
      snprintf(distStr, sizeof(distStr), "%dm", _navData.distMeters);
    }
    tft.drawString(distStr, 218, 30, 4);

    // Speed text (e.g. "0 km/h")
    tft.setTextColor(TFT_CYAN, cCardBg);
    char spdStr[16];
    snprintf(spdStr, sizeof(spdStr), "%d km/h", _navData.speedKmh);
    tft.drawString(spdStr, 218, 56, 2);

    // --- SECTION B: Street Name Pill Card (y: 88 to 136) ---
    tft.fillRoundRect(164, 88, 146, 44, 8, cPillBg);
    tft.drawRoundRect(164, 88, 146, 44, 8, tft.color565(30, 41, 59));
    tft.setTextColor(TFT_YELLOW, cPillBg);
    tft.drawString(_navData.streetName, 170, 102, 2);

    // --- SECTION C: ETA & Total Distance (y: 146 to 226) ---
    // Sub-labels
    tft.setTextColor(cDimGrey, cCardBg);
    tft.drawString("DU KIEN", 168, 152, 1);

    tft.setTextColor(cSubText, cCardBg);
    char totDistStr[16];
    if (_navData.totalDistMeters >= 1000) {
      snprintf(totDistStr, sizeof(totDistStr), "%.1f km", (float)_navData.totalDistMeters / 1000.0);
    } else {
      snprintf(totDistStr, sizeof(totDistStr), "%d m", _navData.totalDistMeters);
    }
    tft.drawRightString(totDistStr, 304, 152, 1);

    // Main values
    tft.setTextColor(TFT_CYAN, cCardBg);
    tft.drawString(_navData.arrivalTime, 168, 172, 4);

    tft.setTextColor(TFT_GREEN, cCardBg);
    char etaStr[16];
    snprintf(etaStr, sizeof(etaStr), "%d ph", _navData.etaMinutes);
    tft.drawRightString(etaStr, 304, 172, 4);
  }
#endif
};

#endif
