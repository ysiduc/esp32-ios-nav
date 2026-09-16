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

  void _drawThickLine(int x1, int y1, int x2, int y2, uint16_t color, int width = 1) {
    if (width <= 1) {
      tft.drawLine(x1, y1, x2, y2, color);
      return;
    }
    if (width == 2) {
      tft.drawLine(x1, y1, x2, y2, color);
      if (abs(x2 - x1) > abs(y2 - y1)) {
        tft.drawLine(x1, y1 + 1, x2, y2 + 1, color);
      } else {
        tft.drawLine(x1 + 1, y1, x2 + 1, y2, color);
      }
      return;
    }
    tft.drawLine(x1, y1, x2, y2, color);
    if (abs(x2 - x1) > abs(y2 - y1)) {
      tft.drawLine(x1, y1 - 1, x2, y2 - 1, color);
      tft.drawLine(x1, y1 + 1, x2, y2 + 1, color);
    } else {
      tft.drawLine(x1 - 1, y1, x2 - 1, y2, color);
      tft.drawLine(x1 + 1, y1, x2 + 1, y2, color);
    }
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
    // ULTRA-DETAILED CIRCULAR RADAR VECTOR ROAD NETWORK (Automotive / Motorcycle HUD)
    // -------------------------------------------------------------------------
    uint16_t cMapBg       = tft.color565(15, 23, 42);    // Deep Dark Slate (#0F172A)
    uint16_t cCardFrame   = tft.color565(30, 41, 59);    // Subtle boundary (#1E293B)
    uint16_t cRoadWhite   = TFT_WHITE;                   // Bright White Main Arterial / Route (#FFFFFF)
    uint16_t cRoadSlate   = tft.color565(203, 213, 225); // Crisp Light Slate Alleys (#CBD5E1)
    uint16_t cPillBg      = tft.color565(11, 17, 26);    // HUD pill background

    // 1. Clear Left Container Card
    tft.drawRoundRect(4, 24, 148, 212, 12, cCardFrame);
    tft.fillRoundRect(6, 26, 144, 208, 10, TFT_BLACK);

    int cx = 78;
    int cy = 120;
    int R  = 66;

    // 2. Base Circular Radar Viewport
    tft.fillCircle(cx, cy, R - 2, cMapBg);

    // 3. Right Arterial Avenue (Prominent Curved White Road from reference photo)
    _drawThickLine(cx + 20, cy - 64, cx + 26, cy - 35, cRoadWhite, 3);
    _drawThickLine(cx + 26, cy - 35, cx + 38, cy + 5,  cRoadWhite, 3);
    _drawThickLine(cx + 38, cy + 5,  cx + 52, cy + 40, cRoadWhite, 3);
    _drawThickLine(cx + 52, cy + 40, cx + 62, cy + 56, cRoadWhite, 3);

    // Side Alleys Branching Right from Arterial Avenue
    _drawThickLine(cx + 34, cy - 8,  cx + 58, cy - 5,  cRoadSlate, 2);
    _drawThickLine(cx + 42, cy + 14, cx + 62, cy + 18, cRoadSlate, 2);
    _drawThickLine(cx + 48, cy + 32, cx + 64, cy + 36, cRoadSlate, 2);
    _drawThickLine(cx + 54, cy + 48, cx + 65, cy + 50, cRoadSlate, 2);

    // 4. Main Central Road Corridor
    _drawThickLine(cx,     cy + 55, cx,     cy + 22, cRoadWhite, 3);
    _drawThickLine(cx,     cy + 22, cx - 2, cy - 22, cRoadWhite, 3);
    _drawThickLine(cx - 2, cy - 22, cx - 3, cy - 64, cRoadWhite, 3);

    // 5. Maneuver Intersection at (cx - 2, cy - 22)
    // Left Branch:
    _drawThickLine(cx - 2,  cy - 22, cx - 38, cy - 14, cRoadWhite, 3);
    _drawThickLine(cx - 38, cy - 14, cx - 46, cy + 8,  cRoadWhite, 3);
    _drawThickLine(cx - 46, cy + 8,  cx - 64, cy + 18, cRoadSlate, 2);
    // Right Branch:
    _drawThickLine(cx - 2,  cy - 22, cx + 28, cy - 35, cRoadWhite, 3);
    _drawThickLine(cx + 28, cy - 35, cx + 34, cy - 62, cRoadSlate, 2);

    // 6. Dense Side Streets & Alleys on the Left
    // Upper-left network:
    _drawThickLine(cx - 22, cy - 18, cx - 24, cy - 42, cRoadSlate, 2);
    _drawThickLine(cx - 24, cy - 42, cx - 50, cy - 40, cRoadSlate, 2);
    _drawThickLine(cx - 50, cy - 40, cx - 62, cy - 46, cRoadSlate, 2);
    _drawThickLine(cx - 24, cy - 42, cx - 25, cy - 62, cRoadSlate, 2);
    _drawThickLine(cx - 40, cy - 41, cx - 41, cy - 24, cRoadSlate, 2);

    // Mid-left network:
    _drawThickLine(cx,      cy + 6,  cx - 32, cy + 10, cRoadSlate, 2);
    _drawThickLine(cx - 32, cy + 10, cx - 46, cy + 8,  cRoadSlate, 2);
    _drawThickLine(cx - 34, cy + 10, cx - 35, cy + 32, cRoadSlate, 2);

    // Lower-left network:
    _drawThickLine(cx,      cy + 32, cx - 28, cy + 42, cRoadSlate, 2);
    _drawThickLine(cx - 28, cy + 42, cx - 50, cy + 36, cRoadSlate, 2);
    _drawThickLine(cx - 50, cy + 36, cx - 64, cy + 46, cRoadSlate, 2);
    _drawThickLine(cx - 28, cy + 42, cx - 30, cy + 58, cRoadSlate, 2);

    // 7. Dense Side Streets & Alleys on the Right
    _drawThickLine(cx,      cy - 4,  cx + 24, cy - 7,  cRoadSlate, 2);
    _drawThickLine(cx + 6,  cy + 18, cx + 28, cy + 2,  cRoadSlate, 2);
    _drawThickLine(cx + 28, cy + 2,  cx + 38, cy + 4,  cRoadSlate, 2);
    _drawThickLine(cx + 12, cy + 35, cx + 34, cy + 18, cRoadSlate, 2);
    _drawThickLine(cx + 34, cy + 18, cx + 42, cy + 22, cRoadSlate, 2);
    _drawThickLine(cx + 16, cy + 50, cx + 38, cy + 34, cRoadSlate, 2);
    _drawThickLine(cx + 38, cy + 34, cx + 48, cy + 42, cRoadSlate, 2);

    // 8. Active Route Corridor Highlight & Waypoints
    if (_navData.isNavigating) {
      // Highlight the active approach route with brilliant cyan core
      _drawThickLine(cx, cy + 22, cx - 2, cy - 22, TFT_CYAN, 3);

      // Highlight the turn branch based on turnCode
      if (_navData.turnCode == 5 || _navData.turnCode == 6 || _navData.turnCode == 7) {
        // Left turn branch
        _drawThickLine(cx - 2,  cy - 22, cx - 38, cy - 14, TFT_CYAN, 3);
        _drawThickLine(cx - 38, cy - 14, cx - 46, cy + 8,  TFT_CYAN, 3);
      } else if (_navData.turnCode == 1 || _navData.turnCode == 2 || _navData.turnCode == 3) {
        // Right turn branch
        _drawThickLine(cx - 2,  cy - 22, cx + 28, cy - 35, TFT_CYAN, 3);
      } else {
        // Straight
        _drawThickLine(cx - 2,  cy - 22, cx - 3,  cy - 64, TFT_CYAN, 3);
      }

      // Waypoint Target Node at intersection (cx - 2, cy - 22) -> Exact Cyan Concentric Ring as in Photo
      tft.drawCircle(cx - 2, cy - 22, 6, TFT_CYAN);
      tft.drawCircle(cx - 2, cy - 22, 5, TFT_CYAN);
      tft.fillCircle(cx - 2, cy - 22, 2, TFT_WHITE);
    }

    // 9. User Vehicle Location Pin at (cx, cy + 22) -> Exact White Concentric Ring as in Photo
    tft.drawCircle(cx, cy + 22, 7, TFT_WHITE);
    tft.drawCircle(cx, cy + 22, 6, TFT_WHITE);
    tft.drawCircle(cx, cy + 22, 3, TFT_WHITE);
    tft.fillCircle(cx, cy + 22, 1, TFT_WHITE);
    // Direction pointer tip pointing forward
    tft.fillTriangle(cx, cy + 12, cx - 4, cy + 16, cx + 4, cy + 16, TFT_WHITE);

    // 10. Re-stroke Crisp White Outer Circular Frame Ring
    tft.drawCircle(cx, cy, R,     TFT_WHITE);
    tft.drawCircle(cx, cy, R - 1, TFT_WHITE);
    tft.drawCircle(cx, cy, R + 1, tft.color565(51, 65, 85));

    // 11. Top Overlay: Maneuver Distance or Heading Pill (y: 28..50)
    tft.fillRoundRect(12, 28, 132, 22, 6, cPillBg);
    tft.drawRoundRect(12, 28, 132, 22, 6, tft.color565(40, 56, 78));
    if (_navData.isNavigating) {
      _drawMiniTurnIcon(24, 39, _navData.turnCode);

      char distBuf[16];
      if (_navData.distMeters >= 1000) {
        snprintf(distBuf, sizeof(distBuf), "%.1fkm", _navData.distMeters / 1000.0);
      } else {
        snprintf(distBuf, sizeof(distBuf), "%dm", _navData.distMeters);
      }
      tft.setTextColor(tft.color565(250, 204, 21), cPillBg);
      tft.drawString(distBuf, 36, 32, 2);

      // Status indicator dot
      tft.fillCircle(136, 39, 3, TFT_GREEN);
    } else {
      tft.setTextColor(TFT_CYAN, cPillBg);
      tft.drawString("* ysiduc NAV", 20, 32, 2);
      tft.fillCircle(136, 39, 3, TFT_CYAN);
    }

    // 12. Bottom Overlay: Street Name Pill (y: 194..226)
    tft.fillRoundRect(12, 194, 132, 28, 6, cPillBg);
    tft.drawRoundRect(12, 194, 132, 28, 6, tft.color565(30, 41, 59));
    if (_navData.isNavigating && strlen(_navData.streetName) > 0) {
      _drawCentreUtf8String(_navData.streetName, 78, 201, TFT_YELLOW, cPillBg);
    } else {
      _drawCentreUtf8String("SẴN SÀNG", 78, 201, TFT_GREEN, cPillBg);
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
