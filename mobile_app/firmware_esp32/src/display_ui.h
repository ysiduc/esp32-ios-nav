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

struct RoutePoint {
  int8_t dx;
  int8_t dy;
};

struct NavStateData {
  uint8_t turnCode = 6;       // 6 = Turn Left, 2 = Turn Right, 0 = Straight
  uint16_t distMeters = 209;
  uint16_t totalDistMeters = 300;
  uint8_t speedKmh = 0;
  uint8_t etaMinutes = 1;
  char streetName[48] = "CAU SONG LU";
  char arrivalTime[16] = "18:26";
  char currentTime[16] = "18:25";
  uint8_t batteryLevel = 89;
  bool isConnected = false;
  uint8_t routePointCount = 0;
  RoutePoint routePoints[32];
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

  void setNavData(uint8_t turn, uint16_t dist, uint16_t totalDist, uint8_t speed, uint8_t eta, const char* street, const char* arrival = "18:26", const char* clock = "18:25", uint8_t battery = 89, const RoutePoint* pts = nullptr, uint8_t ptCount = 0) {
    _navData.turnCode = turn;
    _navData.distMeters = dist;
    _navData.totalDistMeters = totalDist;
    _navData.speedKmh = speed;
    _navData.etaMinutes = eta;
    strncpy(_navData.streetName, street, sizeof(_navData.streetName) - 1);
    _navData.streetName[sizeof(_navData.streetName) - 1] = '\0';
    if (arrival != nullptr && strlen(arrival) > 0) {
      strncpy(_navData.arrivalTime, arrival, sizeof(_navData.arrivalTime) - 1);
      _navData.arrivalTime[sizeof(_navData.arrivalTime) - 1] = '\0';
    }
    if (clock != nullptr && strlen(clock) > 0) {
      strncpy(_navData.currentTime, clock, sizeof(_navData.currentTime) - 1);
      _navData.currentTime[sizeof(_navData.currentTime) - 1] = '\0';
    }
    if (battery > 0 && battery <= 100) {
      _navData.batteryLevel = battery;
    }

    if (pts != nullptr && ptCount > 0) {
      _navData.routePointCount = ptCount > 32 ? 32 : ptCount;
      memcpy(_navData.routePoints, pts, _navData.routePointCount * sizeof(RoutePoint));
    }

    if (_currentState != STATE_POPUP_CALL && _currentState != STATE_POPUP_SMS) {
      if (_currentState != STATE_NAVIGATION) {
        _needFullRedraw = true;
      }
      _currentState = STATE_NAVIGATION;
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
    if (_needFullRedraw || millis() - _lastRenderTime > 400) {
      if (_needFullRedraw) {
        tft.fillScreen(TFT_BLACK);
      }
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

    // Top Status bar (Header: * ysiduc | Current Clock | Battery)
    tft.setTextColor(TFT_CYAN, TFT_BLACK);
    tft.drawString("* ysiduc", 10, 4, 2);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.drawCentreString(_navData.currentTime, 160, 4, 2);
    tft.setTextColor(TFT_GREEN, TFT_BLACK);
    char batStr[16];
    snprintf(batStr, sizeof(batStr), "%d%%", _navData.batteryLevel);
    tft.drawString(batStr, 260, 4, 2);
    tft.drawRect(298, 6, 14, 8, TFT_GREEN);
    tft.fillRect(300, 8, 10, 4, TFT_GREEN);

    // Center Main Card (Dark Navy Charcoal)
    uint16_t cCardBg = tft.color565(17, 24, 36);
    tft.fillRoundRect(14, 26, 292, 202, 12, cCardBg);
    tft.drawRoundRect(14, 26, 292, 202, 12, TFT_CYAN);

    tft.setTextColor(TFT_CYAN, cCardBg);
    tft.drawCentreString("YSIDUC SMART NAVIGATOR", 160, 42, 4);

    tft.setTextColor(TFT_GREEN, cCardBg);
    tft.drawCentreString("STREAM MAP 20 FPS (HD RETINA)", 160, 76, 2);

    tft.setTextColor(TFT_WHITE, cCardBg);
    tft.drawString("1. Mo App tren dien thoai", 34, 110, 2);
    tft.drawString("2. Ket noi Bluetooth: ysiduc_NAV", 34, 138, 2);
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
      // TURN LEFT
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

  /// Draw High-Definition Standby Vector Map when JPEG stream is inactive
  void _renderStandbyVectorMap() {
    uint16_t cMapBg = tft.color565(11, 17, 26);     // Dark Cyber Navy
    uint16_t cGrid = tft.color565(22, 34, 50);      // Subtle Road Grid
    uint16_t cRoute = tft.color565(0, 240, 255);    // Vibrant Cyan Route
    uint16_t cGlow = tft.color565(0, 80, 140);      // Outer Route Glow

    // 1. Map container & border
    tft.drawRoundRect(4, 24, 148, 212, 12, TFT_CYAN);
    tft.fillRoundRect(6, 26, 144, 208, 10, cMapBg);

    // 2. Perspective Road Grid
    for (int gx = 24; gx < 144; gx += 28) {
      tft.drawFastVLine(6 + gx, 28, 204, cGrid);
    }
    for (int gy = 24; gy < 208; gy += 28) {
      tft.drawFastHLine(8, 26 + gy, 140, cGrid);
    }

    // 3. Dynamic Vector Route: Draw Real Road Geometry from GPS Route Points
    int cx = 78;
    int cy = 150;

    if (_navData.routePointCount >= 2) {
      int prevX = cx;
      int prevY = cy;
      for (uint8_t i = 0; i < _navData.routePointCount; i++) {
        int px = cx + (int)(_navData.routePoints[i].dx * 0.7);
        int py = cy - (int)(_navData.routePoints[i].dy * 0.7);
        px = constrain(px, 12, 140);
        py = constrain(py, 32, 215);

        tft.drawLine(prevX, prevY, px, py, cGlow);
        tft.drawLine(prevX - 1, prevY, px - 1, py, cRoute);
        tft.drawLine(prevX + 1, prevY, px + 1, py, cRoute);

        prevX = px;
        prevY = py;
      }
      // Destination flag/dot at the end of real road path
      tft.fillCircle(prevX, prevY, 5, TFT_YELLOW);
      tft.fillCircle(prevX, prevY, 2, TFT_WHITE);
    } else {
      // Dynamic Turn Maneuver Curve fallback
      if (_navData.turnCode == 5 || _navData.turnCode == 6 || _navData.turnCode == 7) {
        // TURN LEFT
        tft.drawLine(cx, 215, cx, 95, cGlow);
        tft.drawLine(cx - 1, 215, cx - 1, 95, cRoute);
        tft.drawLine(cx + 1, 215, cx + 1, 95, cRoute);
        tft.drawLine(cx, 95, 24, 95, cGlow);
        tft.drawLine(cx, 94, 24, 94, cRoute);
        tft.drawLine(cx, 96, 24, 96, cRoute);
        tft.fillCircle(24, 95, 5, TFT_YELLOW);
        tft.fillCircle(24, 95, 2, TFT_WHITE);
      }
      else if (_navData.turnCode == 1 || _navData.turnCode == 2 || _navData.turnCode == 3) {
        // TURN RIGHT
        tft.drawLine(cx, 215, cx, 95, cGlow);
        tft.drawLine(cx - 1, 215, cx - 1, 95, cRoute);
        tft.drawLine(cx + 1, 215, cx + 1, 95, cRoute);
        tft.drawLine(cx, 95, 132, 95, cGlow);
        tft.drawLine(cx, 94, 132, 94, cRoute);
        tft.drawLine(cx, 96, 132, 96, cRoute);
        tft.fillCircle(132, 95, 5, TFT_YELLOW);
        tft.fillCircle(132, 95, 2, TFT_WHITE);
      }
      else {
        // STRAIGHT
        tft.drawLine(cx, 215, cx, 42, cGlow);
        tft.drawLine(cx - 1, 215, cx - 1, 42, cRoute);
        tft.drawLine(cx + 1, 215, cx + 1, 42, cRoute);
        tft.fillCircle(cx, 42, 5, TFT_YELLOW);
        tft.fillCircle(cx, 42, 2, TFT_WHITE);
      }
    }

    // 4. Vehicle Navigation Marker (Cyan triangle + radar pulse)
    tft.drawCircle(cx, cy, 14, tft.color565(0, 100, 160));
    tft.drawCircle(cx, cy, 22, tft.color565(0, 50, 90));

    // Arrow pointing up / heading
    tft.fillTriangle(cx, cy - 10, cx - 8, cy + 8, cx + 8, cy + 8, TFT_CYAN);
    tft.fillCircle(cx, cy + 1, 3, TFT_WHITE);

    // 5. GPS Radar Pulse Indicator (Top Right)
    tft.fillCircle(134, 38, 4, TFT_GREEN);
    tft.setTextColor(TFT_GREEN, cMapBg);
    tft.drawString("GPS", 112, 34, 1);
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
    // STATE_NAVIGATION: EXACT 100% REPLICA OF TARGET DESIGN
    // =========================================================================
    uint16_t cCardBg = tft.color565(19, 27, 38);   // Pure Dark Charcoal (#131B26)
    uint16_t cPillBg = tft.color565(11, 17, 26);   // Deep Black Pill (#0B111A)
    uint16_t cBorder = tft.color565(32, 45, 61);   // Subtle Border (#202D3D)
    uint16_t cSubText = tft.color565(148, 163, 184); // Light Grey (#94A3B8)
    uint16_t cDimGrey = tft.color565(100, 116, 139); // Dim Grey (#64748B)

    // 1. TOP HARDWARE STATUS BAR (y: 0 to 22): * ysiduc | Real Clock | Real Battery
    tft.fillRect(0, 0, 320, 22, TFT_BLACK);
    tft.setTextColor(TFT_CYAN, TFT_BLACK);
    tft.drawString("* ysiduc", 10, 4, 2);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.drawCentreString(_navData.currentTime, 160, 4, 2);
    tft.setTextColor(TFT_GREEN, TFT_BLACK);
    char batStr[16];
    snprintf(batStr, sizeof(batStr), "%d%%", _navData.batteryLevel);
    tft.drawString(batStr, 260, 4, 2);
    tft.drawRect(298, 6, 14, 8, TFT_GREEN);
    int batFill = (_navData.batteryLevel * 10) / 100;
    if (batFill < 1) batFill = 1;
    if (batFill > 10) batFill = 10;
    tft.fillRect(300, 8, batFill, 4, TFT_GREEN);

    // Clean any leftover pixels between boxes
    tft.fillRect(152, 24, 6, 216, TFT_BLACK);

    // 2. LEFT 50%: LIVE MINI MAP CANVAS (x: 4, y: 24, w: 148, h: 212)
    if (!isStreamingActive) {
      _renderStandbyVectorMap();
    } else {
      // Map border container
      tft.drawRoundRect(4, 24, 148, 212, 12, TFT_CYAN);
    }

    // 3. RIGHT 50%: HUD NAVIGATION CARDS (x: 158, y: 24, w: 158, h: 212)
    tft.fillRoundRect(158, 24, 158, 212, 12, cCardBg);
    tft.drawRoundRect(158, 24, 158, 212, 12, cBorder);

    // --- SECTION A: Maneuver Icon + Turn Distance + Speed (y: 30 to 82) ---
    _drawManeuverArrow(164, 30, _navData.turnCode);

    // Clear distance text area
    tft.fillRect(216, 30, 94, 26, cCardBg);
    tft.setTextColor(TFT_WHITE, cCardBg);
    char distStr[16];
    if (_navData.distMeters >= 1000) {
      snprintf(distStr, sizeof(distStr), "%.1f km", (float)_navData.distMeters / 1000.0);
    } else {
      snprintf(distStr, sizeof(distStr), "%dm", _navData.distMeters);
    }
    tft.drawString(distStr, 218, 30, 4);

    // Clear speed text area
    tft.fillRect(216, 56, 94, 20, cCardBg);
    tft.setTextColor(TFT_CYAN, cCardBg);
    char spdStr[16];
    snprintf(spdStr, sizeof(spdStr), "%d km/h", _navData.speedKmh);
    tft.drawString(spdStr, 218, 56, 2);

    // --- SECTION B: Street Name Pill Card (y: 86 to 126) ---
    tft.fillRoundRect(164, 86, 146, 38, 8, cPillBg);
    tft.drawRoundRect(164, 86, 146, 38, 8, tft.color565(30, 41, 59));

    char upperStreet[48];
    strncpy(upperStreet, _navData.streetName, sizeof(upperStreet) - 1);
    upperStreet[sizeof(upperStreet) - 1] = '\0';
    for (int i = 0; upperStreet[i]; i++) {
      upperStreet[i] = toupper((unsigned char)upperStreet[i]);
    }
    tft.setTextColor(TFT_YELLOW, cPillBg);
    tft.drawCentreString(upperStreet, 237, 98, 2);

    // --- SECTION C: ETA & Total Distance (y: 136 to 226) ---
    tft.fillRect(164, 136, 146, 78, cCardBg);

    // Sub-labels (y: 146)
    tft.setTextColor(cDimGrey, cCardBg);
    tft.drawString("DU KIEN", 168, 146, 1);

    tft.setTextColor(cSubText, cCardBg);
    char totDistStr[16];
    snprintf(totDistStr, sizeof(totDistStr), "%.1f km", (float)_navData.totalDistMeters / 1000.0);
    tft.drawRightString(totDistStr, 304, 146, 2);

    // Main values (y: 166)
    tft.setTextColor(TFT_CYAN, cCardBg);
    tft.drawString(_navData.arrivalTime, 168, 166, 4);

    tft.setTextColor(TFT_GREEN, cCardBg);
    char etaStr[16];
    snprintf(etaStr, sizeof(etaStr), "%d ph", _navData.etaMinutes);
    tft.drawRightString(etaStr, 304, 166, 4);
  }
#endif
};

#endif
