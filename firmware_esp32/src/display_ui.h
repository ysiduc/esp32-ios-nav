#ifndef DISPLAY_UI_H
#define DISPLAY_UI_H

#include <Arduino.h>
#include <SPIFFS.h>

#if defined(DISPLAY_OLED_SSD1306)
#include <U8g2lib.h>
#include <Wire.h>
extern U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2;

#elif defined(DISPLAY_TFT_ST7789)
#include <TFT_eSPI.h>
#include <U8g2_for_TFT_eSPI.h>
#include <TJpg_Decoder.h>
extern U8g2_for_TFT_eSPI u8f;

extern TFT_eSPI tft;
#endif

#include "icons.h"

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
  bool isNavigating = false;
  char songTitle[48] = "";
  char songArtist[32] = "";
  uint8_t routePointCount = 0;
  RoutePoint routePoints[32];
  int16_t heading = 0;
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
  bool _lastIsNavigating = false;
  bool _lastStreamingState = false;
  unsigned long _lastRenderTime = 0;
  uint32_t _songScrollTick = 0;

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
    u8f.begin(tft);
    u8f.setFontMode(0);
    u8f.setFontDirection(0);
    _drawPairingScreenTft();
#endif
  }

  void setNavData(uint8_t turn, uint16_t dist, uint16_t totalDist, uint8_t speed, uint8_t eta, const char* street, const char* arrival = "18:26", const char* clock = "18:25", uint8_t battery = 89, const RoutePoint* pts = nullptr, uint8_t ptCount = 0, bool isNav = false, int16_t head = 0) {
    if (_navData.isNavigating != isNav) {
      _needFullRedraw = true;
    }
    _navData.turnCode = turn;
    _navData.distMeters = dist;
    _navData.totalDistMeters = totalDist;
    _navData.speedKmh = speed;
    _navData.etaMinutes = eta;
    _navData.isNavigating = isNav;
    _navData.heading = head;

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

  void setSongInfo(const char* song, const char* artist) {
    if (song != nullptr && strlen(song) > 0 && strcmp(song, "CHUA PHAT NHAC") != 0) {
      strncpy(_navData.songTitle, song, sizeof(_navData.songTitle) - 1);
      _navData.songTitle[sizeof(_navData.songTitle) - 1] = '\0';
    } else if (song == nullptr || strlen(song) == 0 || strcmp(song, "CHUA PHAT NHAC") == 0) {
      _navData.songTitle[0] = '\0';
    }
    if (artist != nullptr && strlen(artist) > 0 && strcmp(artist, "MO NHAC TREN IPHONE") != 0) {
      strncpy(_navData.songArtist, artist, sizeof(_navData.songArtist) - 1);
      _navData.songArtist[sizeof(_navData.songArtist) - 1] = '\0';
    } else if (artist == nullptr || strlen(artist) == 0) {
      _navData.songArtist[0] = '\0';
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

  void showCallAlert(const char* callerName, const char* phoneOrMsg = nullptr) {
    strncpy(_popupData.title, callerName, sizeof(_popupData.title) - 1);
    if (phoneOrMsg != nullptr && phoneOrMsg[0] != '\0') {
      strncpy(_popupData.message, phoneOrMsg, sizeof(_popupData.message) - 1);
    } else {
      _popupData.message[0] = '\0';
    }
    _popupData.expireMillis = millis() + 10000;
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

  void dismissAlert() {
    if (_currentState == STATE_POPUP_CALL || _currentState == STATE_POPUP_SMS) {
      _currentState = _navData.isConnected ? STATE_NAVIGATION : STATE_PAIRING_WAIT;
      _needFullRedraw = true;
    }
  }

  bool isCallActive() const {
    return _currentState == STATE_POPUP_CALL;
  }

  const char* getCallerName() const {
    return _popupData.title;
  }

  void forceRedraw() {
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
    if (_needFullRedraw || millis() - _lastRenderTime > 250) {
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
  
  void _drawUtf8String(const char* str, int x, int y, uint16_t fgColor, uint16_t bgColor, const uint8_t* font = u8g2_font_unifont_t_vietnamese1) {
    u8f.setFont(font);
    u8f.setForegroundColor(fgColor);
    u8f.setBackgroundColor(bgColor);
    // Hard clamp: if in the right HUD card, never draw to the left of x = 168 (protects minimap)
    if (x >= 140 && x < 168) x = 168;
    u8f.setCursor(x, y + 13);
    u8f.print(str);
  }

  void _drawCentreUtf8String(const char* str, int cx, int y, uint16_t fgColor, uint16_t bgColor, const uint8_t* font = u8g2_font_unifont_t_vietnamese1) {
    u8f.setFont(font);
    u8f.setForegroundColor(fgColor);
    u8f.setBackgroundColor(bgColor);
    int w = u8f.getUTF8Width(str);
    int startX = cx - (w / 2);
    // Hard clamp: if in the right HUD card, never draw to the left of x = 168 (protects minimap)
    if (cx >= 164 && startX < 168) startX = 168;
    u8f.setCursor(startX, y + 13);
    u8f.print(str);
  }

  void _drawPairingScreenTft() {
    if (SPIFFS.exists("/bg_wait.jpg")) {
      File f = SPIFFS.open("/bg_wait.jpg", "r");
      if (f) {
        size_t fSize = f.size();
        f.close();
        if (fSize > 500) {
          JRESULT res = TJpgDec.drawFsJpg(0, 0, "/bg_wait.jpg");
          if (res == JDR_OK) {
            // Top status bar overlay
            tft.setTextColor(TFT_WHITE, TFT_BLACK);
            tft.drawString("* ysiduc", 10, 4, 2);
            char batStr[16];
            snprintf(batStr, sizeof(batStr), "%d%%", _navData.batteryLevel);
            tft.drawString(batStr, 270, 4, 2);

            // Bottom Glass Banner
            uint16_t cBarBg = tft.color565(11, 17, 26);
            tft.fillRoundRect(20, 202, 280, 32, 8, cBarBg);
            tft.drawRoundRect(20, 202, 280, 32, 8, TFT_CYAN);
            _drawCentreUtf8String("CHỜ KẾT NỐI BLUETOOTH...", 160, 208, TFT_CYAN, cBarBg);
            return;
          } else {
            Serial.printf("[SPIFFS] /bg_wait.jpg decode failed (rc=%d), removing corrupt file.\n", res);
            SPIFFS.remove("/bg_wait.jpg");
          }
        } else {
          Serial.println("[SPIFFS] /bg_wait.jpg incomplete (<500B), removing.");
          SPIFFS.remove("/bg_wait.jpg");
        }
      }
    }

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

  /// Draw Mini Maneuver Icon for HUD Card (fits inside 26px pill)
  void _drawMiniTurnIcon(int cx, int cy, uint8_t turnCode) {
    if (turnCode == 5 || turnCode == 6 || turnCode == 7) {
      // MINI TURN LEFT
      tft.fillRect(cx + 3, cy - 3, 2, 8, TFT_CYAN);
      tft.fillRect(cx - 5, cy - 3, 8, 2, TFT_CYAN);
      tft.fillTriangle(cx - 7, cy - 2, cx - 3, cy - 6, cx - 3, cy + 2, TFT_CYAN);
    }
    else if (turnCode == 1 || turnCode == 2 || turnCode == 3) {
      // MINI TURN RIGHT
      tft.fillRect(cx - 5, cy - 3, 2, 8, TFT_CYAN);
      tft.fillRect(cx - 3, cy - 3, 8, 2, TFT_CYAN);
      tft.fillTriangle(cx + 7, cy - 2, cx + 3, cy - 6, cx + 3, cy + 2, TFT_CYAN);
    }
    else if (turnCode == 4) {
      // MINI U-TURN
      tft.fillRect(cx + 3, cy - 2, 2, 7, TFT_CYAN);
      tft.fillRect(cx - 3, cy - 4, 7, 2, TFT_CYAN);
      tft.fillRect(cx - 3, cy - 2, 2, 7, TFT_CYAN);
      tft.fillTriangle(cx - 2, cy + 6, cx - 5, cy + 2, cx + 1, cy + 2, TFT_CYAN);
    }
    else if (turnCode == 9) {
      // MINI DESTINATION FLAG
      tft.fillRect(cx - 4, cy - 5, 2, 11, TFT_WHITE);
      tft.fillTriangle(cx - 2, cy - 5, cx + 5, cy - 2, cx - 2, cy + 1, TFT_CYAN);
    }
    else {
      // MINI STRAIGHT
      tft.fillRect(cx - 1, cy - 2, 2, 9, TFT_CYAN);
      tft.fillTriangle(cx, cy - 6, cx - 4, cy - 1, cx + 4, cy - 1, TFT_CYAN);
    }
  }

  /// Draw High-Definition Realistic Standby Vector Map when JPEG stream is inactive
  void _renderStandbyVectorMap() {
    if (!_navData.isNavigating && SPIFFS.exists("/bg_map.jpg")) {
      File f = SPIFFS.open("/bg_map.jpg", "r");
      if (f) {
        size_t fSize = f.size();
        f.close();
        if (fSize > 500) {
          extern bool g_clipMapOnly;
          g_clipMapOnly = true;
          JRESULT res = TJpgDec.drawFsJpg(6, 26, "/bg_map.jpg");
          g_clipMapOnly = false;
          if (res == JDR_OK) {
            tft.drawRoundRect(4, 24, 148, 212, 12, TFT_CYAN);
            return;
          } else {
            Serial.printf("[SPIFFS] /bg_map.jpg decode failed (rc=%d), removing corrupt file.\n", res);
            SPIFFS.remove("/bg_map.jpg");
          }
        } else {
          Serial.println("[SPIFFS] /bg_map.jpg incomplete (<500B), removing.");
          SPIFFS.remove("/bg_map.jpg");
        }
      }
    }

    // -------------------------------------------------------------------------
    // ULTRA-DETAILED REALISTIC VECTOR MAP (Dark Apple Maps / Goong Map Engine)
    // -------------------------------------------------------------------------
    uint16_t cMapBg       = tft.color565(11, 16, 24);    // Deep dark navy-slate
    uint16_t cWater       = tft.color565(14, 52, 92);    // Sông Lừ / River deep cyan-blue
    uint16_t cWaterShore  = tft.color565(22, 78, 130);   // River bank / shoreline ripple
    uint16_t cGreen       = tft.color565(13, 30, 22);    // Parks & green belts
    uint16_t cGreenBorder = tft.color565(20, 48, 34);    // Green park perimeter
    uint16_t cBlock       = tft.color565(18, 26, 38);    // Urban building footprint
    uint16_t cBlockBorder = tft.color565(28, 40, 58);    // Building 3D outline
    uint16_t cBlockRoof   = tft.color565(24, 34, 48);    // Building roof bevel
    uint16_t cSecRoad     = tft.color565(22, 32, 46);    // Secondary road surface
    uint16_t cSecCasing   = tft.color565(15, 22, 32);    // Secondary road casing
    uint16_t cAsphalt     = tft.color565(28, 40, 58);    // Main road asphalt casing
    uint16_t cSurface     = tft.color565(38, 52, 74);    // Main road smooth surface
    uint16_t cLaneMark    = tft.color565(130, 150, 175); // Dashed white lane markings & zebra
    uint16_t cRouteHalo   = tft.color565(0, 110, 185);   // Vibrant electric route halo
    uint16_t cRouteCore   = tft.color565(0, 240, 255);   // Neon cyan core route
    uint16_t cRadar       = tft.color565(18, 28, 42);    // Radar distance range rings
    uint16_t cPill        = tft.color565(12, 20, 32);    // HUD glass pill

    // 1. Base Canvas Container
    tft.drawRoundRect(4, 24, 148, 212, 12, TFT_CYAN);
    tft.fillRoundRect(6, 26, 144, 208, 10, cMapBg);

    int cx = 78;
    int cy = 155;

    // 2. Natural River / Waterway (e.g. Sông Lừ)
    // Blue water body flowing diagonally and along the flank
    tft.fillTriangle(6, 75, 34, 108, 6, 120, cWater);
    tft.fillRect(6, 85, 26, 35, cWater);
    tft.fillTriangle(6, 120, 34, 108, 30, 168, cWater);
    tft.fillTriangle(6, 120, 30, 168, 12, 185, cWater);
    tft.fillRect(8, 172, 22, 48, cWater);
    // Shoreline ripple lines
    tft.drawLine(34, 108, 30, 168, cWaterShore);
    tft.drawLine(35, 109, 31, 169, cWaterShore);
    tft.drawLine(30, 172, 30, 225, cWaterShore);
    tft.drawLine(31, 172, 31, 225, cWaterShore);

    // 3. Parks & Green Belts
    // Riverside Park (x: 8..34, y: 32..65)
    tft.fillRoundRect(8, 32, 26, 32, 4, cGreen);
    tft.drawRoundRect(8, 32, 26, 32, 4, cGreenBorder);
    tft.fillCircle(16, 44, 2, tft.color565(32, 85, 52));
    tft.fillCircle(24, 52, 2, tft.color565(32, 85, 52));
    // Urban Park (x: 104..142, y: 155..198)
    tft.fillRoundRect(104, 155, 38, 42, 6, cGreen);
    tft.drawRoundRect(104, 155, 38, 42, 6, cGreenBorder);
    tft.fillCircle(116, 168, 2, tft.color565(32, 85, 52));
    tft.fillCircle(128, 178, 3, tft.color565(32, 85, 52));

    // 4. Urban Building Footprint Blocks (e.g. A4, A5, N26A)
    // Block 1 (Top-Right Apartment Complex A5)
    tft.fillRoundRect(90, 36, 48, 30, 3, cBlock);
    tft.drawRoundRect(90, 36, 48, 30, 3, cBlockBorder);
    tft.fillRect(94, 40, 40, 5, cBlockRoof);
    // Block 2 (Mid-Right Residential Plot A4)
    tft.fillRoundRect(96, 78, 44, 28, 3, cBlock);
    tft.drawRoundRect(96, 78, 44, 28, 3, cBlockBorder);
    tft.drawFastHLine(100, 92, 36, cBlockBorder);
    // Block 3 (Mid-Right High-Rise N26A)
    tft.fillRoundRect(94, 118, 46, 26, 3, cBlock);
    tft.drawRoundRect(94, 118, 46, 26, 3, cBlockBorder);
    tft.fillRect(98, 122, 38, 5, cBlockRoof);
    // Block 4 (Lower-Right Villa Block)
    tft.fillRoundRect(98, 206, 42, 20, 3, cBlock);
    tft.drawRoundRect(98, 206, 42, 20, 3, cBlockBorder);
    // Block 5 (Lower-Left Settlement)
    tft.fillRoundRect(36, 185, 26, 35, 3, cBlock);
    tft.drawRoundRect(36, 185, 26, 35, 3, cBlockBorder);

    // 5. Road Network & Intersections
    // Cross Street 1 (Major 4-way Intersection, ~45m ahead at y = 114)
    tft.fillRect(8, 108, 138, 13, cSecCasing);
    tft.fillRect(8, 110, 138, 9, cSecRoad);
    // Concrete bridge railings over river on left flank (x: 8 to 36)
    tft.drawFastHLine(8, 108, 28, tft.color565(95, 115, 140));
    tft.drawFastHLine(8, 120, 28, tft.color565(95, 115, 140));
    // Pedestrian Zebra Crosswalk at Intersection
    for (int zx = 60; zx <= 68; zx += 2) {
      tft.drawFastVLine(zx, 110, 9, cLaneMark);
    }
    for (int zx = 88; zx <= 96; zx += 2) {
      tft.drawFastVLine(zx, 110, 9, cLaneMark);
    }

    // Cross Street 2 (Secondary Avenue at y = 72)
    tft.fillRect(40, 68, 106, 9, cSecCasing);
    tft.fillRect(40, 70, 106, 6, cSecRoad);

    // Residential Alley 3 (Lower connection at y = 175)
    tft.fillRect(34, 172, 50, 7, cSecCasing);
    tft.fillRect(34, 174, 50, 4, cSecRoad);

    // Distance Range Radar Rings (50m, 100m)
    tft.drawCircle(cx, cy, 45, cRadar);
    tft.drawCircle(cx, cy, 90, cRadar);
    tft.drawFastHLine(cx - 65, cy, 130, cRadar);
    tft.drawFastVLine(cx, cy - 110, 170, cRadar);
    tft.setTextColor(tft.color565(60, 76, 98), cMapBg);
    tft.drawString("50m", cx + 47, cy - 7, 1);
    tft.drawString("100m", cx + 70, cy - 7, 1);

    // 6. Dynamic Vector Route Corridor
    if (_navData.routePointCount >= 2) {
      int ptsX[32];
      int ptsY[32];
      for (uint8_t i = 0; i < _navData.routePointCount; i++) {
        ptsX[i] = constrain(cx + _navData.routePoints[i].dx, 12, 142);
        ptsY[i] = constrain(cy - _navData.routePoints[i].dy, 32, 224);
      }

      // Pass 1: Wide Asphalt Roadbed (Width ~14px)
      for (uint8_t i = 0; i < _navData.routePointCount; i++) {
        tft.fillCircle(ptsX[i], ptsY[i], 7, cAsphalt);
      }
      for (uint8_t i = 1; i < _navData.routePointCount; i++) {
        for (int off = -6; off <= 6; off++) {
          tft.drawLine(ptsX[i-1] + off, ptsY[i-1], ptsX[i] + off, ptsY[i], cAsphalt);
          tft.drawLine(ptsX[i-1], ptsY[i-1] + off, ptsX[i], ptsY[i] + off, cAsphalt);
        }
      }

      // Pass 2: Inner Smooth Road Surface (Width ~10px)
      for (uint8_t i = 0; i < _navData.routePointCount; i++) {
        tft.fillCircle(ptsX[i], ptsY[i], 5, cSurface);
      }
      for (uint8_t i = 1; i < _navData.routePointCount; i++) {
        for (int off = -4; off <= 4; off++) {
          tft.drawLine(ptsX[i-1] + off, ptsY[i-1], ptsX[i] + off, ptsY[i], cSurface);
          tft.drawLine(ptsX[i-1], ptsY[i-1] + off, ptsX[i], ptsY[i] + off, cSurface);
        }
      }

      // Pass 3: Route Halo (Width ~6px)
      for (uint8_t i = 1; i < _navData.routePointCount; i++) {
        for (int off = -2; off <= 2; off++) {
          tft.drawLine(ptsX[i-1] + off, ptsY[i-1], ptsX[i] + off, ptsY[i], cRouteHalo);
          tft.drawLine(ptsX[i-1], ptsY[i-1] + off, ptsX[i], ptsY[i] + off, cRouteHalo);
        }
      }

      // Pass 4: Brilliant Neon Cyan Core Route (Width ~3px)
      for (uint8_t i = 1; i < _navData.routePointCount; i++) {
        tft.drawLine(ptsX[i-1], ptsY[i-1], ptsX[i], ptsY[i], cRouteCore);
        tft.drawLine(ptsX[i-1] - 1, ptsY[i-1], ptsX[i] - 1, ptsY[i], cRouteCore);
        tft.drawLine(ptsX[i-1] + 1, ptsY[i-1], ptsX[i] + 1, ptsY[i], cRouteCore);
        tft.drawLine(ptsX[i-1], ptsY[i-1] - 1, ptsX[i], ptsY[i] - 1, cRouteCore);
        tft.drawLine(ptsX[i-1], ptsY[i-1] + 1, ptsX[i], ptsY[i] + 1, cRouteCore);
      }

      // Pass 5: White Directional Traffic Flow Chevrons (Every ~25px)
      for (uint8_t i = 1; i < _navData.routePointCount; i++) {
        int mx = (ptsX[i-1] + ptsX[i]) / 2;
        int my = (ptsY[i-1] + ptsY[i]) / 2;
        tft.fillCircle(mx, my, 2, TFT_WHITE);
      }

      // Pass 6: Destination Pin
      int last = _navData.routePointCount - 1;
      tft.fillCircle(ptsX[last], ptsY[last], 6, TFT_RED);
      tft.fillCircle(ptsX[last], ptsY[last], 4, TFT_YELLOW);
      tft.fillCircle(ptsX[last], ptsY[last], 2, TFT_WHITE);
    } else {
      // Fallback Smooth Curved Corridor
      int endX = cx;
      int endY = 48;
      if (_navData.turnCode == 5 || _navData.turnCode == 6 || _navData.turnCode == 7) {
        endX = 22; endY = 95; // Turn Left
      } else if (_navData.turnCode == 1 || _navData.turnCode == 2 || _navData.turnCode == 3) {
        endX = 134; endY = 95; // Turn Right
      }

      // Asphalt base
      for (int off = -7; off <= 7; off++) {
        tft.drawLine(cx + off, 220, cx + off, 130, cAsphalt);
        tft.drawLine(cx + off, 130, endX + off, endY, cAsphalt);
      }
      // Road surface
      for (int off = -5; off <= 5; off++) {
        tft.drawLine(cx + off, 220, cx + off, 130, cSurface);
        tft.drawLine(cx + off, 130, endX + off, endY, cSurface);
      }
      // Cyan Halo & Core
      for (int off = -2; off <= 2; off++) {
        tft.drawLine(cx + off, 220, cx + off, 130, cRouteHalo);
        tft.drawLine(cx + off, 130, endX + off, endY, cRouteHalo);
      }
      tft.drawLine(cx, 220, cx, 130, cRouteCore);
      tft.drawLine(cx - 1, 220, cx - 1, 130, cRouteCore);
      tft.drawLine(cx + 1, 220, cx + 1, 130, cRouteCore);
      tft.drawLine(cx, 130, endX, endY, cRouteCore);
      tft.drawLine(cx - 1, 130, endX - 1, endY, cRouteCore);
      tft.drawLine(cx + 1, 130, endX + 1, endY, cRouteCore);

      tft.fillCircle(endX, endY, 5, TFT_RED);
      tft.fillCircle(endX, endY, 3, TFT_YELLOW);
      tft.fillCircle(endX, endY, 1, TFT_WHITE);
    }

    // 7. Maneuver Turn Badge Floating on Road Surface (if navigating)
    if (_navData.isNavigating && _navData.distMeters > 0) {
      int badgeX = (_navData.turnCode == 6 || _navData.turnCode == 5 || _navData.turnCode == 7) ? 38 : ((_navData.turnCode == 2 || _navData.turnCode == 1 || _navData.turnCode == 3) ? 104 : cx);
      int badgeY = 110;
      tft.fillRoundRect(badgeX - 22, badgeY - 10, 44, 18, 4, tft.color565(18, 26, 40));
      tft.drawRoundRect(badgeX - 22, badgeY - 10, 44, 18, 4, tft.color565(250, 204, 21));
      char mBuf[12];
      snprintf(mBuf, sizeof(mBuf), "%dm", _navData.distMeters < 999 ? _navData.distMeters : 999);
      tft.setTextColor(tft.color565(250, 204, 21), tft.color565(18, 26, 40));
      tft.drawCentreString(mBuf, badgeX, badgeY - 5, 1);
    }

    // 8. Vehicle Cockpit Indicator (Precision Chevron at cx, cy pointing straight UP)
    tft.drawCircle(cx, cy, 14, tft.color565(0, 110, 185));
    tft.drawCircle(cx, cy, 22, tft.color565(0, 50, 90));
    // High-contrast vehicle chevron
    tft.fillTriangle(cx, cy - 11, cx - 8, cy + 8, cx + 8, cy + 8, tft.color565(0, 70, 140)); // shadow
    tft.fillTriangle(cx, cy - 10, cx - 7, cy + 7, cx + 7, cy + 7, TFT_CYAN);
    tft.fillCircle(cx, cy + 1, 2, TFT_WHITE);

    // 9. North Compass Rose (Top-Right Corner at x: 136, y: 38)
    tft.fillCircle(136, 38, 8, tft.color565(15, 23, 36));
    tft.drawCircle(136, 38, 8, tft.color565(40, 56, 78));
    tft.fillTriangle(136, 32, 134, 38, 138, 38, TFT_RED);
    tft.fillTriangle(136, 44, 134, 38, 138, 38, tft.color565(120, 140, 160));
    tft.setTextColor(TFT_RED, tft.color565(15, 23, 36));
    tft.drawString("N", 134, 30, 1);

    // 10. Live HUD Pill Overlay at Top of Minimap
    tft.fillRoundRect(10, 28, 136, 24, 6, cPill);
    tft.drawRoundRect(10, 28, 136, 24, 6, tft.color565(36, 52, 76));

    if (_navData.isNavigating) {
      _drawMiniTurnIcon(22, 40, _navData.turnCode);

      char distBuf[16];
      if (_navData.distMeters >= 1000) {
        snprintf(distBuf, sizeof(distBuf), "%.1fkm", _navData.distMeters / 1000.0);
      } else {
        snprintf(distBuf, sizeof(distBuf), "%dm", _navData.distMeters);
      }
      tft.setTextColor(tft.color565(250, 204, 21), cPill);
      tft.drawString(distBuf, 34, 33, 2);

      // Clean street name preview on right of pill
      tft.setTextColor(TFT_WHITE, cPill);
      char cleanSt[14];
      strncpy(cleanSt, _navData.streetName, 12);
      cleanSt[12] = '\0';
      tft.drawString(cleanSt, 74, 34, 1);

      tft.fillCircle(136, 40, 3, TFT_GREEN);
    } else {
      tft.setTextColor(tft.color565(148, 163, 184), cPill);
      tft.drawCentreString("CHEDO CHO - GPS", 78, 33, 1);
      tft.fillCircle(136, 40, 3, TFT_CYAN);
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
      _drawCentreUtf8String("CUỘC GỌI ĐẾN", 160, 32, TFT_GREEN, cCallBg);
      _drawCentreUtf8String(_popupData.title, 160, 80, TFT_WHITE, cCallBg);
      if (_popupData.message[0] != '\0') {
        _drawCentreUtf8String(_popupData.message, 160, 125, TFT_YELLOW, cCallBg);
      }
      _drawCentreUtf8String("Apple ANCS Thông báo", 160, 175, TFT_CYAN, cCallBg);
      return;
    }

    if (_currentState == STATE_POPUP_SMS) {
      uint16_t cSmsBg = tft.color565(11, 25, 44);
      tft.fillRoundRect(15, 20, 290, 200, 16, cSmsBg);
      tft.drawRoundRect(15, 20, 290, 200, 16, TFT_CYAN);
      _drawCentreUtf8String("TIN NHẮN MỚI", 160, 35, TFT_CYAN, cSmsBg);
      _drawCentreUtf8String(_popupData.title, 160, 85, TFT_YELLOW, cSmsBg);
      _drawCentreUtf8String(_popupData.message, 160, 135, TFT_WHITE, cSmsBg);
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

    // Detect Navigation Mode or Streaming State Transitions
    if (_lastIsNavigating != _navData.isNavigating || _lastStreamingState != isStreamingActive) {
      _lastIsNavigating = _navData.isNavigating;
      _lastStreamingState = isStreamingActive;
      _needFullRedraw = true;
    }

    if (_needFullRedraw) {
      tft.fillScreen(TFT_BLACK);

      // Part 1: * ysiduc (x: 4 to 68)
      tft.setTextColor(TFT_CYAN, TFT_BLACK);
      tft.drawString("* ysiduc", 4, 4, 2);

      // Part 5: Real Clock (x: 234 to 274)
      tft.setTextColor(TFT_WHITE, TFT_BLACK);
      tft.drawCentreString(_navData.currentTime, 254, 4, 2);

      // Part 6: Battery & Icon (x: 278 to 316)
      tft.setTextColor(TFT_GREEN, TFT_BLACK);
      char batStr[16];
      snprintf(batStr, sizeof(batStr), "%d%%", _navData.batteryLevel);
      tft.drawString(batStr, 276, 4, 2);
      tft.drawRect(300, 6, 14, 8, TFT_GREEN);
      int batFill = (_navData.batteryLevel * 10) / 100;
      if (batFill < 1) batFill = 1;
      if (batFill > 10) batFill = 10;
      tft.fillRect(302, 8, batFill, 4, TFT_GREEN);

      // Map border container
      tft.drawRoundRect(4, 24, 148, 212, 12, TFT_CYAN);

      // Right Card Box Framework
      tft.fillRoundRect(158, 24, 158, 212, 12, cCardBg);
      tft.drawRoundRect(158, 24, 158, 212, 12, cBorder);
    } else {
      // Partial updates: refresh clock
      tft.setTextColor(TFT_WHITE, TFT_BLACK);
      tft.drawCentreString(_navData.currentTime, 254, 4, 2);
    }

    _songScrollTick++;

    // Marquee Song Title & Artist: Only wipe the scrolling text area strictly inside x: 72..232
    tft.fillRect(72, 0, 160, 22, TFT_BLACK);

    bool hasSong = (strlen(_navData.songTitle) > 0 && strcmp(_navData.songTitle, "CHUA PHAT NHAC") != 0);
    if (hasSong) {
      String fullSong = String("♫ ") + _navData.songTitle;
      if (strlen(_navData.songArtist) > 0) {
        fullSong += String(" - ") + _navData.songArtist;
      }
      fullSong += "       ";

      int maxVisibleChars = 14;
      if (fullSong.length() <= maxVisibleChars) {
        _drawCentreUtf8String(fullSong.c_str(), 152, 3, tft.color565(250, 204, 21), TFT_BLACK);
      } else {
        int offset = (_songScrollTick / 3) % fullSong.length();
        String wrapped = fullSong.substring(offset) + fullSong.substring(0, offset);
        String displayChunk = wrapped.substring(0, maxVisibleChars);
        _drawUtf8String(displayChunk.c_str(), 74, 3, tft.color565(250, 204, 21), TFT_BLACK);
      }
    } else {
      _drawCentreUtf8String("-- Chưa phát nhạc --", 152, 3, tft.color565(100, 116, 139), TFT_BLACK);
    }

    // 2. LEFT 50%: LIVE MINI MAP CANVAS (x: 4, y: 24, w: 148, h: 212)
    if (!isStreamingActive) {
      _renderStandbyVectorMap();
    }

    // 3. RIGHT 50%: HUD NAVIGATION OR STANDBY MUSIC DASHBOARD (x: 158, y: 24, w: 158, h: 212)
    if (_needFullRedraw) {
      tft.fillRoundRect(158, 24, 158, 212, 12, cCardBg);
      tft.drawRoundRect(158, 24, 158, 212, 12, cBorder);
    }

    if (!_navData.isNavigating) {
      // =======================================================================
      // STANDBY / IDLE DASHBOARD MODE: Clock, ysiduc, Current Song & Artist
      // =======================================================================
      // A. Large Elegant Digital Clock (y: 32 to 58)
      tft.setTextColor(TFT_WHITE, cCardBg);
      tft.drawCentreString(_navData.currentTime, 237, 34, 4);

      // B. ysiduc Driver / Status Tag (y: 64 to 86)
      tft.fillRoundRect(172, 64, 130, 22, 6, cPillBg);
      tft.drawRoundRect(172, 64, 130, 22, 6, tft.color565(0, 132, 255));
      tft.setTextColor(TFT_CYAN, cPillBg);
      tft.drawCentreString("* ysiduc", 237, 68, 2);

      // C. Media / Music Player Card (y: 94 to 174)
      tft.fillRoundRect(164, 94, 146, 80, 8, cPillBg);
      tft.drawRoundRect(164, 94, 146, 80, 8, tft.color565(30, 41, 59));

      bool hasSong = (strlen(_navData.songTitle) > 0 && strcmp(_navData.songTitle, "CHUA PHAT NHAC") != 0);

      if (hasSong) {
        // Clear inner text area of media card strictly inside x: 166..308
        tft.fillRect(166, 114, 142, 34, cPillBg);

        _drawUtf8String("[>] Đang phát", 172, 98, TFT_YELLOW, cPillBg);

        // Song Title strictly clamped within 130px width, starting >= 170
        String songStr = String(_navData.songTitle);
        int songW = u8f.getUTF8Width(songStr.c_str());
        if (songW <= 130) {
          int startX = 237 - (songW / 2);
          if (startX < 170) startX = 170;
          _drawUtf8String(songStr.c_str(), startX, 115, TFT_WHITE, cPillBg);
        } else {
          String fullS = songStr + "       ";
          int offset = (_songScrollTick / 2) % fullS.length();
          String wrapped = fullS.substring(offset) + fullS.substring(0, offset);
          while (wrapped.length() > 0 && u8f.getUTF8Width(wrapped.c_str()) > 130) {
            wrapped = wrapped.substring(0, wrapped.length() - 1);
          }
          _drawUtf8String(wrapped.c_str(), 170, 115, TFT_WHITE, cPillBg);
        }

        // Artist Name strictly clamped within 130px width, starting >= 170
        String artistStr = String(_navData.songArtist);
        int artistW = u8f.getUTF8Width(artistStr.c_str());
        if (artistW <= 130) {
          int startX = 237 - (artistW / 2);
          if (startX < 170) startX = 170;
          _drawUtf8String(artistStr.c_str(), startX, 133, cSubText, cPillBg);
        } else {
          String fullA = artistStr + "       ";
          int offset = (_songScrollTick / 2) % fullA.length();
          String wrapped = fullA.substring(offset) + fullA.substring(0, offset);
          while (wrapped.length() > 0 && u8f.getUTF8Width(wrapped.c_str()) > 130) {
            wrapped = wrapped.substring(0, wrapped.length() - 1);
          }
          _drawUtf8String(wrapped.c_str(), 170, 133, cSubText, cPillBg);
        }

        // Sound Equalizer Bars (active cyan)
        uint16_t cEq = TFT_CYAN;
        int eqHeights[] = {4, 10, 16, 12, 6, 14, 18, 8, 12, 6};
        for (int b = 0; b < 10; b++) {
          int bx = 188 + (b * 10);
          int by = 166 - eqHeights[b];
          tft.fillRect(bx, by, 5, eqHeights[b], cEq);
        }
      } else {
        _drawUtf8String("[--] Chưa phát", 172, 98, cSubText, cPillBg);
        _drawCentreUtf8String("Mở nhạc trên ĐT", 237, 115, cSubText, cPillBg);
        _drawCentreUtf8String("Spotify / Apple Music", 237, 133, cDimGrey, cPillBg);

        // Dim flat equalizer bars
        uint16_t cDim = tft.color565(30, 41, 59);
        for (int b = 0; b < 10; b++) {
          int bx = 188 + (b * 10);
          tft.fillRect(bx, 164, 5, 2, cDim);
        }
      }

      // D. Bottom Status: "Sẵn sàng di chuyển" (y: 186)
      _drawCentreUtf8String("Sẵn sàng di chuyển", 237, 186, TFT_GREEN, cCardBg);

    } else {
      // =======================================================================
      // ACTIVE NAVIGATION MODE: Maneuver Icon + Distance + Speed + Street + ETA
      // =======================================================================
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

      _drawCentreUtf8String(_navData.streetName, 237, 97, TFT_YELLOW, cPillBg);

      // --- SECTION C: ETA & Total Distance (y: 136 to 226) ---
      tft.fillRect(164, 136, 146, 78, cCardBg);

      // Sub-labels (y: 146)
      _drawUtf8String("Dự kiến", 168, 146, cDimGrey, cCardBg);

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
  }
#endif
};

#endif
