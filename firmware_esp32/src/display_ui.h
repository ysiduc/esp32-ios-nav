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
  char currentTime[16] = "--:--";
  uint8_t batteryLevel = 85;
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
  bool _isAppConnected = false;
  bool _pairingBgDrawn = false;
  uint8_t _clockHour = 0;
  uint8_t _clockMin = 0;
  uint8_t _clockSec = 0;
  unsigned long _lastClockTick = 0;
  bool _clockValid = false;

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
    if (clock != nullptr && strlen(clock) > 0) {
      strncpy(_navData.currentTime, clock, sizeof(_navData.currentTime) - 1);
      _navData.currentTime[sizeof(_navData.currentTime) - 1] = '\0';
    }
    if (arrival != nullptr && strlen(arrival) > 0 && strcmp(arrival, "18:26") != 0) {
      strncpy(_navData.arrivalTime, arrival, sizeof(_navData.arrivalTime) - 1);
      _navData.arrivalTime[sizeof(_navData.arrivalTime) - 1] = '\0';
    } else if (clock != nullptr && strlen(clock) > 0) {
      int ch = 0, cm = 0;
      if (sscanf(clock, "%d:%d", &ch, &cm) == 2) {
        int totalMin = ch * 60 + cm + eta;
        int arrH = (totalMin / 60) % 24;
        int arrM = totalMin % 60;
        snprintf(_navData.arrivalTime, sizeof(_navData.arrivalTime), "%02d:%02d", arrH, arrM);
      } else {
        strncpy(_navData.arrivalTime, "18:26", sizeof(_navData.arrivalTime) - 1);
      }
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
      _isAppConnected = true;
      _pairingBgDrawn = false;
    }
  }

  void setSongInfo(const char* song, const char* artist) {
    bool changed = false;
    if (song != nullptr && strlen(song) > 0 && strcmp(song, "CHUA PHAT NHAC") != 0) {
      if (strcmp(_navData.songTitle, song) != 0) {
        strncpy(_navData.songTitle, song, sizeof(_navData.songTitle) - 1);
        _navData.songTitle[sizeof(_navData.songTitle) - 1] = '\0';
        changed = true;
      }
    } else if (song == nullptr || strlen(song) == 0 || strcmp(song, "CHUA PHAT NHAC") == 0) {
      if (_navData.songTitle[0] != '\0') {
        _navData.songTitle[0] = '\0';
        changed = true;
      }
    }
    if (artist != nullptr && strlen(artist) > 0 && strcmp(artist, "MO NHAC TREN IPHONE") != 0) {
      if (strcmp(_navData.songArtist, artist) != 0) {
        strncpy(_navData.songArtist, artist, sizeof(_navData.songArtist) - 1);
        _navData.songArtist[sizeof(_navData.songArtist) - 1] = '\0';
        changed = true;
      }
    } else if (artist == nullptr || strlen(artist) == 0) {
      if (_navData.songArtist[0] != '\0') {
        _navData.songArtist[0] = '\0';
        changed = true;
      }
    }
    if (changed) {
      _needFullRedraw = true;
    }
  }

  void setBleConnected(bool connected) {
    if (_navData.isConnected != connected) {
      _needFullRedraw = true;
    }
    _navData.isConnected = connected;
    if (!connected) {
      _isAppConnected = false;
      if (_currentState == STATE_NAVIGATION && !_navData.isNavigating) {
        _currentState = STATE_PAIRING_WAIT;
        _pairingBgDrawn = false;
        _needFullRedraw = true;
      }
    }
    // When connected == true: remain in STATE_PAIRING_WAIT until App explicitly connects!
  }

  void setAppConnected(bool connected) {
    _isAppConnected = connected;
    if (connected) {
      _currentState = STATE_NAVIGATION;
      _pairingBgDrawn = false;
      _needFullRedraw = true;
    } else {
      if (!_navData.isNavigating) {
        _currentState = STATE_PAIRING_WAIT;
        _pairingBgDrawn = false;
        _needFullRedraw = true;
      }
    }
  }

  bool isAppConnected() const {
    return _isAppConnected;
  }

  void setTime(uint8_t hour, uint8_t minute, uint8_t second = 0) {
    _clockHour = hour % 24;
    _clockMin = minute % 60;
    _clockSec = second % 60;
    _lastClockTick = millis();
    _clockValid = true;
    char timeStr[16];
    snprintf(timeStr, sizeof(timeStr), "%02d:%02d", _clockHour, _clockMin);
    if (strcmp(_navData.currentTime, timeStr) != 0) {
      strncpy(_navData.currentTime, timeStr, sizeof(_navData.currentTime) - 1);
      _navData.currentTime[sizeof(_navData.currentTime) - 1] = '\0';
      _needFullRedraw = true;
    }
  }

  void updateClock(const char* clockStr) {
    if (clockStr && strlen(clockStr) >= 4) {
      int h = 0, m = 0;
      if (sscanf(clockStr, "%d:%d", &h, &m) == 2) {
        setTime(h, m, 0);
      }
    }
  }

  void updateBattery(uint8_t bat) {
    if (bat <= 100 && _navData.batteryLevel != bat) {
      _navData.batteryLevel = bat;
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
      _currentState = _isAppConnected ? STATE_NAVIGATION : STATE_PAIRING_WAIT;
      if (!_isAppConnected) _pairingBgDrawn = false;
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
    _pairingBgDrawn = false;
    _needFullRedraw = true;
  }

  void update(bool isStreamingActive = false) {
    // Real-time automatic clock ticker (counts second-by-second if disconnected or between BLE syncs)
    if (_clockValid) {
      if (millis() - _lastClockTick >= 1000) {
        uint32_t elapsedSec = (millis() - _lastClockTick) / 1000;
        _lastClockTick += elapsedSec * 1000;
        _clockSec += elapsedSec;
        if (_clockSec >= 60) {
          uint8_t addMin = _clockSec / 60;
          _clockSec %= 60;
          _clockMin += addMin;
          if (_clockMin >= 60) {
            _clockHour = (_clockHour + (_clockMin / 60)) % 24;
            _clockMin %= 60;
          }
          char newTime[16];
          snprintf(newTime, sizeof(newTime), "%02d:%02d", _clockHour, _clockMin);
          if (strcmp(_navData.currentTime, newTime) != 0) {
            strncpy(_navData.currentTime, newTime, sizeof(_navData.currentTime) - 1);
            _navData.currentTime[sizeof(_navData.currentTime) - 1] = '\0';
            _needFullRedraw = true;
          }
        }
      }
    }

    if ((_currentState == STATE_POPUP_CALL || _currentState == STATE_POPUP_SMS) && millis() > _popupData.expireMillis) {
      _currentState = _isAppConnected ? STATE_NAVIGATION : STATE_PAIRING_WAIT;
      if (!_isAppConnected) _pairingBgDrawn = false;
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

  void _drawThickLine(int x1, int y1, int x2, int y2, uint16_t color, int width = 1) {
    if (width <= 1) {
      tft.drawLine(x1, y1, x2, y2, color);
      return;
    }
    int halfW = width / 2;
    if (abs(x2 - x1) > abs(y2 - y1)) {
      for (int d = -halfW; d <= halfW; d++) {
        tft.drawLine(x1, y1 + d, x2, y2 + d, color);
      }
    } else {
      for (int d = -halfW; d <= halfW; d++) {
        tft.drawLine(x1 + d, y1, x2 + d, y2, color);
      }
    }
  }

  void _drawPairingScreenTft() {
    // 1. Draw Background Image (Decoded once to prevent flickering)
    if (!_pairingBgDrawn) {
      bool bgLoaded = false;
      if (SPIFFS.exists("/bg_wait.jpg")) {
        File f = SPIFFS.open("/bg_wait.jpg", "r");
        if (f) {
          size_t fSize = f.size();
          f.close();
          if (fSize > 500) {
            JRESULT res = TJpgDec.drawFsJpg(0, 0, "/bg_wait.jpg");
            if (res == JDR_OK) {
              bgLoaded = true;
            } else {
              Serial.printf("[SPIFFS] /bg_wait.jpg decode failed (rc=%d), removing.\n", res);
              SPIFFS.remove("/bg_wait.jpg");
            }
          } else {
            SPIFFS.remove("/bg_wait.jpg");
          }
        }
      }

      if (!bgLoaded) {
        tft.fillScreen(TFT_BLACK);
      }
      _pairingBgDrawn = true;
    }

    // 2. Top Dockbar (Height 24px, Dark Glass semi-transparent overlay)
    uint16_t cDockBg = tft.color565(8, 12, 18);
    tft.fillRect(0, 0, 320, 24, cDockBg);
    tft.drawFastHLine(0, 24, 320, tft.color565(25, 38, 55));

    // Left: #ysiduc (Cyan)
    tft.setTextColor(TFT_CYAN, cDockBg);
    tft.drawString("#ysiduc", 8, 4, 2);

    // Middle: Current Song Title from AMS (if playing)
    if (_navData.songTitle[0] != '\0') {
      String songDisplay = String(_navData.songTitle);
      if (u8f.getUTF8Width(songDisplay.c_str()) > 150) {
        while (songDisplay.length() > 0 && u8f.getUTF8Width((songDisplay + "...").c_str()) > 150) {
          // Safely remove bytes until not ending on a UTF-8 continuation byte
          do {
            songDisplay.remove(songDisplay.length() - 1);
          } while (songDisplay.length() > 0 && (songDisplay.charAt(songDisplay.length() - 1) & 0xC0) == 0x80);
        }
        songDisplay += "...";
      }
      _drawCentreUtf8String(songDisplay.c_str(), 144, 4, TFT_WHITE, cDockBg, u8g2_font_unifont_t_vietnamese1);
    }

    // Right: Current Time & Battery %
    tft.setTextColor(TFT_WHITE, cDockBg);
    tft.drawString(_navData.currentTime, 226, 4, 2);

    char batStr[16];
    if (_navData.batteryLevel > 0 && _navData.batteryLevel <= 100) {
      snprintf(batStr, sizeof(batStr), "%d%%", _navData.batteryLevel);
    } else {
      snprintf(batStr, sizeof(batStr), "85%%");
    }
    uint16_t cBat = (_navData.batteryLevel > 0 && _navData.batteryLevel <= 20) ? TFT_RED : TFT_GREEN;
    tft.setTextColor(cBat, cDockBg);
    tft.drawRightString(batStr, 298, 4, 2);

    // Battery Icon
    tft.drawRect(302, 7, 14, 10, cBat);
    tft.fillRect(316, 10, 2, 4, cBat);
    int fillW = constrain((_navData.batteryLevel * 10) / 100, 0, 10);
    if (fillW > 0) {
      tft.fillRect(304, 9, fillW, 6, cBat);
    }
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

  /// Draw High-Definition Real Vector Navigation Map (True Route Geometry & Corridor)
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
    // TRUE-TO-LIFE VECTOR NAVIGATION MAP (Garmin / Apple Maps HUD Style)
    // -------------------------------------------------------------------------
    uint16_t cMapBg       = tft.color565(11, 17, 26);    // Deep Dark Slate Navy (#0B111A)
    uint16_t cCardBorder  = tft.color565(32, 45, 61);    // Card edge outline (#202D3D)
    uint16_t cRadarRing   = tft.color565(20, 32, 48);    // Distance Range Rings (#142030)
    uint16_t cRadarText   = tft.color565(60, 80, 105);   // Scale labels (#3C5069)
    uint16_t cAsphaltBed  = tft.color565(28, 38, 54);    // Real Road Asphalt Bed (#1C2636)
    uint16_t cRoadBorder  = tft.color565(55, 75, 100);   // Crisp Road Casing Border (#374B64)
    uint16_t cRouteGlow   = tft.color565(0, 120, 180);   // Route Outer Glow (#0078B4)
    uint16_t cRouteActive = TFT_CYAN;                    // Brilliant Neon Cyan Route (#00F0FF)

    // 1. Clear & Fill Entire Left Rectangular Container Card (x: 4..152, y: 24..236)
    tft.drawRoundRect(4, 24, 148, 212, 12, cCardBorder);
    tft.fillRoundRect(6, 26, 144, 208, 10, cMapBg);

    // Coordinate Anchors
    const int minX = 7, maxX = 149;
    const int minY = 27, maxY = 233;
    const int cx = 78;

    if (_navData.isNavigating) {
      // -----------------------------------------------------------------------
      // ACTIVE NAVIGATION MODE: Real Route Geometry, Actual Turn & Road Corridor
      // -----------------------------------------------------------------------
      const int cy = 175; // Vehicle anchor position at lower 1/3

      // 2. Concentric Distance Range Rings (50m, 100m, 150m perspective)
      tft.drawCircle(cx, cy, 38, cRadarRing);
      tft.drawCircle(cx, cy, 74, cRadarRing);
      tft.drawCircle(cx, cy, 110, cRadarRing);
      tft.drawFastHLine(cx - 65, cy, 130, cRadarRing);
      tft.drawFastVLine(cx, minY + 6, maxY - minY - 12, cRadarRing);

      tft.setTextColor(cRadarText, cMapBg);
      tft.drawString("50m", cx + 41, cy - 8, 1);
      tft.drawString("100m", cx + 77, cy - 8, 1);

      // 3. Render Real Navigation Route & Cross Streets
      if (_navData.routePointCount >= 2) {
        // Collect valid forward-advancing GPS waypoints
        int px[32], py[32];
        px[0] = cx;
        py[0] = cy;
        uint8_t count = 1;

        for (uint8_t i = 1; i < _navData.routePointCount; i++) {
          if (_navData.routePoints[i].dy < -5) continue; // Skip backwards points
          px[count] = constrain(cx + _navData.routePoints[i].dx, minX + 6, maxX - 6);
          py[count] = constrain(cy - _navData.routePoints[i].dy, minY + 8, maxY - 4);
          count++;
        }

        if (count >= 2) {
          // Road behind vehicle extending to bottom of card
          _drawThickLine(cx, cy, cx, maxY - 4, cRoadBorder, 16);
          _drawThickLine(cx, cy, cx, maxY - 4, cAsphaltBed, 12);

          // Pass 1: Road Border Casings along actual route
          for (uint8_t i = 1; i < count; i++) {
            _drawThickLine(px[i - 1], py[i - 1], px[i], py[i], cRoadBorder, 16);
            tft.fillCircle(px[i], py[i], 8, cRoadBorder);
          }
          tft.fillCircle(px[0], py[0], 8, cRoadBorder);

          // Pass 2: Asphalt Road Bed along actual route
          for (uint8_t i = 1; i < count; i++) {
            _drawThickLine(px[i - 1], py[i - 1], px[i], py[i], cAsphaltBed, 12);
            tft.fillCircle(px[i], py[i], 6, cAsphaltBed);
          }
          tft.fillCircle(px[0], py[0], 6, cAsphaltBed);

          // Pass 3: Detect upcoming turn intersection & draw Cross Street
          int turnIdx = 1;
          int32_t maxDeflection = 0;
          for (uint8_t i = 1; i < count - 1; i++) {
            if (cy - py[i] < 16) continue; // Must be ahead of vehicle, not on top of location puck
            int32_t v1x = px[i] - px[i - 1];
            int32_t v1y = py[i] - py[i - 1];
            int32_t v2x = px[i + 1] - px[i];
            int32_t v2y = py[i + 1] - py[i];
            int32_t cross = abs(v1x * v2y - v1y * v2x);
            if (cross > 80) {
              turnIdx = i;
              break;
            }
            if (cross > maxDeflection) {
              maxDeflection = cross;
              turnIdx = i;
            }
          }
          if (cy - py[turnIdx] < 16 && count > 2) {
            turnIdx = count / 2;
          }
          int tx = px[turnIdx];
          int ty = py[turnIdx];

          // Draw cross street crossing through the intersection
          _drawThickLine(constrain(tx - 36, minX + 4, maxX - 4), ty, constrain(tx + 36, minX + 4, maxX - 4), ty, cRoadBorder, 14);
          _drawThickLine(constrain(tx - 36, minX + 4, maxX - 4), ty, constrain(tx + 36, minX + 4, maxX - 4), ty, cAsphaltBed, 10);

          // Pass 4: Glowing Neon Navigation Route Core
          for (uint8_t i = 1; i < count; i++) {
            _drawThickLine(px[i - 1], py[i - 1], px[i], py[i], cRouteGlow, 6);
          }
          for (uint8_t i = 1; i < count; i++) {
            _drawThickLine(px[i - 1], py[i - 1], px[i], py[i], cRouteActive, 4);
            _drawThickLine(px[i - 1], py[i - 1], px[i], py[i], TFT_WHITE, 1);
            tft.fillCircle(px[i], py[i], 2, cRouteActive);
          }

          // Pass 5: Direction Chevrons along route segments
          for (uint8_t i = 1; i < count; i++) {
            int mx = (px[i - 1] + px[i]) / 2;
            int my = (py[i - 1] + py[i]) / 2;
            int dx = px[i] - px[i - 1];
            int dy = py[i] - py[i - 1];
            if (abs(dy) > abs(dx)) {
              if (dy < -6) { // Going UP
                tft.fillTriangle(mx, my - 5, mx - 3, my + 1, mx + 3, my + 1, TFT_WHITE);
              }
            } else {
              if (dx < -6) { // Going LEFT
                tft.fillTriangle(mx - 5, my, mx + 1, my - 3, mx + 1, my + 3, TFT_WHITE);
              } else if (dx > 6) { // Going RIGHT
                tft.fillTriangle(mx + 5, my, mx - 1, my - 3, mx - 1, my + 3, TFT_WHITE);
              }
            }
          }

          // Pass 6: Maneuver Waypoint Node at the upcoming turn
          tft.drawCircle(tx, ty, 7, cRouteActive);
          tft.drawCircle(tx, ty, 6, cRouteActive);
          tft.fillCircle(tx, ty, 2, TFT_WHITE);
        }
      } else {
        // Fallback: Dynamic Real Intersection Corridor from turnCode and distMeters
        int turnY = constrain(cy - map(_navData.distMeters, 0, 400, 38, 115), minY + 20, cy - 35);

        // A. Main Approach Road Bed
        _drawThickLine(cx, maxY - 4, cx, turnY, cRoadBorder, 16);
        _drawThickLine(cx, maxY - 4, cx, turnY, cAsphaltBed, 12);

        // B. Cross Street at Intersection
        _drawThickLine(minX + 6, turnY, maxX - 6, turnY, cRoadBorder, 14);
        _drawThickLine(minX + 6, turnY, maxX - 6, turnY, cAsphaltBed, 10);

        // C. Straight continuation road past intersection
        _drawThickLine(cx, turnY, cx, minY + 8, cRoadBorder, 12);
        _drawThickLine(cx, turnY, cx, minY + 8, cAsphaltBed, 8);

        // D. Active Navigation Route
        _drawThickLine(cx, cy, cx, turnY, cRouteGlow, 6);
        _drawThickLine(cx, cy, cx, turnY, cRouteActive, 4);
        _drawThickLine(cx, cy, cx, turnY, TFT_WHITE, 1);

        // Direction arrow along approach
        int midY = (cy + turnY) / 2;
        tft.fillTriangle(cx, midY - 6, cx - 4, midY + 1, cx + 4, midY + 1, TFT_WHITE);

        // Turn branch based on turnCode
        if (_navData.turnCode == 5 || _navData.turnCode == 6 || _navData.turnCode == 7) {
          // TURN LEFT (90 deg turn onto cross street)
          _drawThickLine(cx, turnY, minX + 14, turnY, cRouteGlow, 6);
          _drawThickLine(cx, turnY, minX + 14, turnY, cRouteActive, 4);
          _drawThickLine(cx, turnY, minX + 14, turnY, TFT_WHITE, 1);
          tft.fillTriangle(minX + 18, turnY, minX + 26, turnY - 5, minX + 26, turnY + 5, TFT_WHITE);

        } else if (_navData.turnCode == 1 || _navData.turnCode == 2 || _navData.turnCode == 3) {
          // TURN RIGHT (90 deg turn onto cross street)
          _drawThickLine(cx, turnY, maxX - 14, turnY, cRouteGlow, 6);
          _drawThickLine(cx, turnY, maxX - 14, turnY, cRouteActive, 4);
          _drawThickLine(cx, turnY, maxX - 14, turnY, TFT_WHITE, 1);
          tft.fillTriangle(maxX - 18, turnY, maxX - 26, turnY - 5, maxX - 26, turnY + 5, TFT_WHITE);

        } else if (_navData.turnCode == 4) {
          // U-TURN
          _drawThickLine(cx, turnY, cx - 22, turnY, cRouteActive, 4);
          _drawThickLine(cx - 22, turnY, cx - 22, cy - 10, cRouteActive, 4);
          tft.fillTriangle(cx - 22, cy - 4, cx - 27, cy - 12, cx - 17, cy - 12, TFT_WHITE);

        } else if (_navData.turnCode == 8) {
          // ROUNDABOUT
          tft.drawCircle(cx, turnY, 14, cRouteActive);
          tft.drawCircle(cx, turnY, 13, cRouteActive);
          tft.fillCircle(cx, turnY, 6, cMapBg);

        } else {
          // STRAIGHT / KEEP AHEAD
          _drawThickLine(cx, turnY, cx, minY + 10, cRouteGlow, 6);
          _drawThickLine(cx, turnY, cx, minY + 10, cRouteActive, 4);
          _drawThickLine(cx, turnY, cx, minY + 10, TFT_WHITE, 1);
          tft.fillTriangle(cx, minY + 12, cx - 4, minY + 19, cx + 4, minY + 19, TFT_WHITE);
        }

        // Maneuver Waypoint Node at Intersection
        tft.drawCircle(cx, turnY, 7, cRouteActive);
        tft.drawCircle(cx, turnY, 6, cRouteActive);
        tft.fillCircle(cx, turnY, 2, TFT_WHITE);
      }

      // 4. Vehicle Navigation Location Puck (at cx, cy = 175 pointing UP)
      tft.drawCircle(cx, cy, 14, tft.color565(0, 50, 80));
      tft.fillCircle(cx, cy, 8, cRouteActive);
      tft.drawCircle(cx, cy, 8, TFT_WHITE);
      tft.drawCircle(cx, cy, 7, TFT_WHITE);
      tft.fillCircle(cx, cy, 3, TFT_CYAN);
      // Aerodynamic forward arrow tip pointing UP
      tft.fillTriangle(cx, cy - 10, cx - 4, cy - 3, cx + 4, cy - 3, TFT_WHITE);

      // 5. Bottom-Left Turn Distance Badge (e.g. "205m" in yellow)
      char distBadge[16];
      if (_navData.distMeters >= 1000) {
        snprintf(distBadge, sizeof(distBadge), "%.1fkm", _navData.distMeters / 1000.0);
      } else {
        snprintf(distBadge, sizeof(distBadge), "%dm", _navData.distMeters);
      }
      tft.setTextColor(tft.color565(250, 204, 21), cMapBg);
      tft.drawString(distBadge, 12, maxY - 16, 2);

    } else {
      // -----------------------------------------------------------------------
      // STANDBY / IDLE MODE: Clean Crossroad Intersection & Center Location Puck
      // -----------------------------------------------------------------------
      const int cy = 130;

      // Range rings
      tft.drawCircle(cx, cy, 45, cRadarRing);
      tft.drawCircle(cx, cy, 85, cRadarRing);

      // North-South Central Road
      _drawThickLine(cx, maxY - 4, cx, minY + 4, cRoadBorder, 16);
      _drawThickLine(cx, maxY - 4, cx, minY + 4, cAsphaltBed, 12);

      // East-West Crossroad
      _drawThickLine(minX + 4, cy, maxX - 4, cy, cRoadBorder, 16);
      _drawThickLine(minX + 4, cy, maxX - 4, cy, cAsphaltBed, 12);

      // Standby Location Puck
      tft.drawCircle(cx, cy, 12, tft.color565(0, 50, 80));
      tft.fillCircle(cx, cy, 7, cRouteActive);
      tft.drawCircle(cx, cy, 7, TFT_WHITE);
      tft.fillTriangle(cx, cy - 9, cx - 4, cy - 2, cx + 4, cy - 2, TFT_WHITE);

      tft.setTextColor(cRadarText, cMapBg);
      tft.drawCentreString("CHẾ ĐỘ CHỜ", cx, maxY - 20, 2);
    }

    // -------------------------------------------------------------------------
    // MINIMALIST OVERLAYS (No bulky pills, keeping entire map unobstructed)
    // -------------------------------------------------------------------------
    // Top-Left: Minimalist Compass North Indicator
    tft.setTextColor(TFT_CYAN, cMapBg);
    tft.drawString("N", 10, 30, 2);
    tft.fillTriangle(24, 31, 21, 39, 27, 39, TFT_CYAN);

    // Top-Right: Live GPS Status Dot
    tft.fillCircle(142, 34, 3, _navData.isNavigating ? TFT_GREEN : TFT_CYAN);

    // Bottom-Right: Subtle Map Scale Bar
    tft.setTextColor(cRadarText, cMapBg);
    tft.drawString("50m", 102, 222, 1);
    tft.drawFastHLine(124, 226, 20, cRadarText);
    tft.drawFastVLine(124, 223, 7,  cRadarText);
    tft.drawFastVLine(144, 223, 7,  cRadarText);
  }

  void _renderTft(bool isStreamingActive) {
    if (_currentState == STATE_PAIRING_WAIT) {
      if ((isStreamingActive && _isAppConnected) || _navData.isNavigating || _isAppConnected) {
        _currentState = STATE_NAVIGATION;
        _pairingBgDrawn = false;
        _needFullRedraw = true;
      } else {
        _drawPairingScreenTft();
        return;
      }
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

      // Sub-labels (y: 144)
      _drawUtf8String("Dự kiến", 168, 144, cDimGrey, cCardBg);

      tft.setTextColor(cSubText, cCardBg);
      char totDistStr[16];
      if (_navData.totalDistMeters >= 1000) {
        snprintf(totDistStr, sizeof(totDistStr), "%.1f km", (float)_navData.totalDistMeters / 1000.0);
      } else {
        snprintf(totDistStr, sizeof(totDistStr), "%dm", _navData.totalDistMeters);
      }
      tft.drawRightString(totDistStr, 304, 144, 2);

      // Main values (y: 166)
      tft.setTextColor(TFT_CYAN, cCardBg);
      tft.drawString(_navData.arrivalTime, 168, 166, 4);

      tft.setTextColor(TFT_GREEN, cCardBg);
      char etaStr[16];
      if (_navData.etaMinutes >= 60) {
        int h = _navData.etaMinutes / 60;
        int m = _navData.etaMinutes % 60;
        snprintf(etaStr, sizeof(etaStr), "%dh%02d", h, m);
      } else {
        snprintf(etaStr, sizeof(etaStr), "%d ph", _navData.etaMinutes);
      }
      tft.drawRightString(etaStr, 304, 166, _navData.etaMinutes >= 100 ? 2 : 4);
    }
  }
#endif
};

#endif
