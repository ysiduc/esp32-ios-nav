#ifndef DISPLAY_UI_H
#define DISPLAY_UI_H

#include <Arduino.h>
#include <SPIFFS.h>
#include <Preferences.h>

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
extern TFT_eSprite marqueeSpr;
extern U8g2_for_TFT_eSPI u8f_marquee;
#endif

#include "icons.h"

enum DisplayState {
  STATE_STANDBY_WATCHFACE, // Màn 1: Chờ kết nối (kết nối BLE ngoài app, không waybar, nhiều kiểu watchface)
  STATE_APP_IDLE_MAP,      // Màn 2: Chờ navigation (đã kết nối BLE trong app, minimap trái + nhạc phải, không waybar)
  STATE_NAVIGATION         // Màn 3: Đang dẫn đường (waybar trên hiển thị nhạc + pin chuẩn + popup 5s)
};

struct RoutePoint {
  int8_t dx;
  int8_t dy;
};

struct NavStateData {
  uint8_t turnCode = 0;
  uint16_t distMeters = 0;
  uint16_t totalDistMeters = 0;
  uint8_t speedKmh = 0;
  uint8_t etaMinutes = 0;
  char streetName[48] = "";
  char arrivalTime[16] = "12:00";
  char currentTime[16] = "12:00";
  uint8_t batteryLevel = 85;
  bool isConnected = false;    // System Bluetooth connected
  bool isNavigating = false;
  char songTitle[48] = "";
  char songArtist[32] = "";
  uint16_t songElapsedSec = 0;
  uint16_t songDurationSec = 0;
  uint8_t routePointCount = 0;
  RoutePoint routePoints[32];
  int16_t heading = 0;
};

struct NotificationPopup {
  char app[16] = "";     // "call", "sms", "zalo", "messenger", "telegram", "bell"
  char title[48] = "";
  char message[96] = "";
  unsigned long expireMillis = 0;
  bool isCall = false;
  bool active = false;
};

class DisplayManager {
private:
  DisplayState _currentState = STATE_STANDBY_WATCHFACE;
  NavStateData _navData;
  NotificationPopup _popupData;

  bool _needFullRedraw = true;
  bool _isAppConnected = false;
  bool _fullScreenStreamActive = false;
  unsigned long _lastRenderTime = 0;

  // Watchface selection (0 = Digital Minimal, 1 = Analog Sport, 2 = Info Dashboard, 3 = Cyberpunk Neon)
  uint8_t _watchfaceStyle = 0;

  // Real-time Clock & Date
  uint8_t _clockHour = 12;
  uint8_t _clockMin = 0;
  uint8_t _clockSec = 0;
  uint8_t _clockDay = 9;
  uint8_t _clockMonth = 11;
  uint16_t _clockYear = 2026;
  uint8_t _clockDayOfWeek = 1; // 1 = Thứ Hai ... 7 = Chủ Nhật
  unsigned long _lastClockTick = 0;
  bool _clockValid = true;

  // Music marquee scroll
  int _songScrollOffset = 0;
  unsigned long _lastSongScrollTime = 0;
  unsigned long _songScrollPauseUntil = 0;

  // Cached state for flicker-free rendering
  DisplayState _lastState = (DisplayState)255;
  uint8_t _lastWatchfaceStyle = 255;
  uint8_t _lastDrawnHour = 255;
  uint8_t _lastDrawnMin = 255;
  uint8_t _lastDrawnSec = 255;
  uint8_t _lastDrawnDay = 255;
  uint8_t _lastDrawnBat = 255;
  char _lastDrawnSong[48] = "";
  char _lastDrawnArtist[32] = "";
  bool _lastDrawnBleState = false;

  // Minimap cached state
  bool _minimapDrawn = false;

public:
  void init() {
#if defined(DISPLAY_TFT_ST7789)
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
    u8f.setFont(u8g2_font_unifont_t_vietnamese1);

    marqueeSpr.createSprite(146, 24);
    u8f_marquee.begin(marqueeSpr);
    u8f_marquee.setFontMode(0);
    u8f_marquee.setFontDirection(0);
    u8f_marquee.setFont(u8g2_font_unifont_t_vietnamese1);

    // Load saved watchface style
    Preferences prefs;
    prefs.begin("nav_ui", true);
    _watchfaceStyle = prefs.getUChar("wf_style", 0) % 4;
    prefs.end();

    _needFullRedraw = true;
#endif
  }

  void setWatchfaceStyle(uint8_t style) {
    _watchfaceStyle = style % 4;
    Preferences prefs;
    prefs.begin("nav_ui", false);
    prefs.putUChar("wf_style", _watchfaceStyle);
    prefs.end();
    _needFullRedraw = true;
    Serial.printf("[UI] Watchface style set to %d\n", _watchfaceStyle);
  }

  uint8_t getWatchfaceStyle() const {
    return _watchfaceStyle;
  }

  void getClock(uint8_t &h, uint8_t &m) const {
    h = _clockHour;
    m = _clockMin;
  }

  void setTime(uint8_t hour, uint8_t minute, uint8_t second = 0) {
    _clockHour = hour % 24;
    _clockMin = minute % 60;
    _clockSec = second % 60;
    _lastClockTick = millis();
    _clockValid = true;
    char timeStr[16];
    snprintf(timeStr, sizeof(timeStr), "%02d:%02d", _clockHour, _clockMin);
    strncpy(_navData.currentTime, timeStr, sizeof(_navData.currentTime) - 1);
    _navData.currentTime[sizeof(_navData.currentTime) - 1] = '\0';
  }

  void setDate(uint8_t day, uint8_t month, uint16_t year, uint8_t dow) {
    _clockDay = (day >= 1 && day <= 31) ? day : _clockDay;
    _clockMonth = (month >= 1 && month <= 12) ? month : _clockMonth;
    _clockYear = (year >= 2020 && year <= 2099) ? year : _clockYear;
    _clockDayOfWeek = (dow >= 1 && dow <= 7) ? dow : 1;
  }

  void updateClock(const char* clockStr) {
    if (clockStr && strlen(clockStr) >= 4) {
      int h = 0, m = 0;
      if (sscanf(clockStr, "%d:%d", &h, &m) == 2) {
        if (h != _clockHour || m != _clockMin) {
          _clockHour = h % 24;
          _clockMin = m % 60;
          char timeStr[16];
          snprintf(timeStr, sizeof(timeStr), "%02d:%02d", _clockHour, _clockMin);
          strncpy(_navData.currentTime, timeStr, sizeof(_navData.currentTime) - 1);
          _navData.currentTime[sizeof(_navData.currentTime) - 1] = '\0';
          _lastClockTick = millis();
          _clockValid = true;
        }
      }
    }
  }

  // Exact 100% Phone Battery update without artificial drop simulation
  void updateBattery(uint8_t bat) {
    if (bat == 0 || bat > 100) return;
    _navData.batteryLevel = bat;
  }

  void setSongInfo(const char* song, const char* artist, uint16_t elapsedSec = 0, uint16_t durationSec = 0) {
    if (song != nullptr && strlen(song) > 0 && strcmp(song, "CHUA PHAT NHAC") != 0) {
      strncpy(_navData.songTitle, song, sizeof(_navData.songTitle) - 1);
      _navData.songTitle[sizeof(_navData.songTitle) - 1] = '\0';
    } else if (song != nullptr && (strlen(song) == 0 || strcmp(song, "CHUA PHAT NHAC") == 0)) {
      _navData.songTitle[0] = '\0';
    }

    if (artist != nullptr && strlen(artist) > 0 && strcmp(artist, "MO NHAC TREN IPHONE") != 0) {
      strncpy(_navData.songArtist, artist, sizeof(_navData.songArtist) - 1);
      _navData.songArtist[sizeof(_navData.songArtist) - 1] = '\0';
    } else if (artist != nullptr && strlen(artist) == 0) {
      _navData.songArtist[0] = '\0';
    }

    if (elapsedSec > 0 || durationSec > 0) {
      _navData.songElapsedSec = elapsedSec;
      _navData.songDurationSec = durationSec;
    }
  }

  void setBleConnected(bool connected) {
    if (_navData.isConnected != connected) {
      _navData.isConnected = connected;
    }
    if (!connected) {
      _isAppConnected = false;
      _currentState = STATE_STANDBY_WATCHFACE;
      _needFullRedraw = true;
    }
  }

  void setAppConnected(bool connected) {
    if (_isAppConnected != connected) {
      _isAppConnected = connected;
      if (connected) {
        _currentState = _navData.isNavigating ? STATE_NAVIGATION : STATE_APP_IDLE_MAP;
      } else {
        _currentState = STATE_STANDBY_WATCHFACE;
        _fullScreenStreamActive = false;
      }
      _needFullRedraw = true;
    }
  }

  bool isAppConnected() const {
    return _isAppConnected;
  }

  bool isNavigating() const {
    return _navData.isNavigating;
  }

  void setFullScreenStream(bool active) {
    if (!_isAppConnected) {
      _fullScreenStreamActive = false;
      if (_currentState != STATE_STANDBY_WATCHFACE) {
        _currentState = STATE_STANDBY_WATCHFACE;
        _needFullRedraw = true;
      }
      return;
    }
    if (_fullScreenStreamActive != active) {
      _fullScreenStreamActive = active;
      if (active) {
        _currentState = STATE_NAVIGATION;
      } else {
        _currentState = _navData.isNavigating ? STATE_NAVIGATION : STATE_APP_IDLE_MAP;
      }
      _needFullRedraw = true;
    }
  }

  void setNavData(uint8_t turn, uint16_t dist, uint16_t totalDist, uint8_t speed, uint8_t eta,
                  const char* street, const char* arrival = "12:00", const char* clock = "12:00",
                  uint8_t battery = 85, const RoutePoint* pts = nullptr, uint8_t ptCount = 0,
                  bool isNav = false, int16_t head = 0) {
    if (_navData.isNavigating != isNav) {
      _navData.isNavigating = isNav;
      _currentState = isNav ? STATE_NAVIGATION : (_isAppConnected ? STATE_APP_IDLE_MAP : STATE_STANDBY_WATCHFACE);
      _needFullRedraw = true;
    }

    _navData.turnCode = turn;
    _navData.distMeters = dist;
    _navData.totalDistMeters = totalDist;
    _navData.speedKmh = speed;
    _navData.etaMinutes = eta;
    _navData.heading = head;

    if (street) strncpy(_navData.streetName, street, sizeof(_navData.streetName) - 1);
    if (arrival) strncpy(_navData.arrivalTime, arrival, sizeof(_navData.arrivalTime) - 1);
    if (clock && strlen(clock) > 0) strncpy(_navData.currentTime, clock, sizeof(_navData.currentTime) - 1);
    if (battery > 0 && battery <= 100) _navData.batteryLevel = battery;

    if (pts != nullptr && ptCount > 0) {
      _navData.routePointCount = ptCount > 32 ? 32 : ptCount;
      memcpy(_navData.routePoints, pts, _navData.routePointCount * sizeof(RoutePoint));
    }
  }

  // Unified Notification Popup (duration default 5000ms per request)
  void showNotificationPopup(const char* app, const char* title, const char* msg, bool isCall = false, uint32_t durationMs = 5000) {
    strncpy(_popupData.app, (app && strlen(app) > 0) ? app : (isCall ? "call" : "bell"), sizeof(_popupData.app) - 1);
    strncpy(_popupData.title, (title && strlen(title) > 0) ? title : (isCall ? "Cuộc gọi đến" : "Thông báo"), sizeof(_popupData.title) - 1);
    strncpy(_popupData.message, (msg && strlen(msg) > 0) ? msg : (isCall ? "Đang đổ chuông..." : ""), sizeof(_popupData.message) - 1);
    _popupData.isCall = isCall;
    _popupData.expireMillis = millis() + durationMs;
    _popupData.active = true;

    // Draw popup banner immediately
    _drawPopupBanner();
  }

  void showCallAlert(const char* callerName, const char* phoneOrMsg = nullptr) {
    showNotificationPopup("call", callerName, phoneOrMsg, true, 5000);
  }

  void showSmsAlert(const char* sender, const char* msg) {
    showNotificationPopup("sms", sender, msg, false, 5000);
  }

  void dismissPopup() {
    _popupData.active = false;
    _popupData.expireMillis = 0;
    _needFullRedraw = true;
  }

  bool isPopupActive() const {
    return _popupData.active && (millis() < _popupData.expireMillis);
  }

  void forceRedraw() {
    _needFullRedraw = true;
    _minimapDrawn = false;
  }

  // Called after JPEG frame decode in main.cpp
  void onFrameRendered() {
    if (isPopupActive()) {
      _drawPopupBanner();
    }
  }

  // Draw top waybar on Navigation screen (Màn 3)
  void drawWaybarIfNav() {
    if (_currentState == STATE_NAVIGATION && !isPopupActive()) {
      _drawWaybar();
    }
  }

  void update(bool isStreamingActive = false) {
    // If not connected to app, strictly stay in STATE_STANDBY_WATCHFACE
    if (!_isAppConnected && _currentState != STATE_STANDBY_WATCHFACE) {
      _currentState = STATE_STANDBY_WATCHFACE;
      _needFullRedraw = true;
    }

    // 1. Clock increment second-by-second
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
          strncpy(_navData.currentTime, newTime, sizeof(_navData.currentTime) - 1);
          _navData.currentTime[sizeof(_navData.currentTime) - 1] = '\0';
        }
      }
    }

    // 2. Check Popup expiration (auto dismiss after 5s)
    if (_popupData.active && millis() >= _popupData.expireMillis) {
      _popupData.active = false;
      _popupData.expireMillis = 0;
      _needFullRedraw = true;
    }

    // Check if state or watchface style changed
    if (_currentState != _lastState || _watchfaceStyle != _lastWatchfaceStyle) {
      _needFullRedraw = true;
    }

    // 3. Render appropriate screen based on state
    if (_currentState == STATE_STANDBY_WATCHFACE) {
      _renderStandbyWatchface();
    } else if (_currentState == STATE_APP_IDLE_MAP) {
      _renderAppIdleMap();
    } else { // STATE_NAVIGATION
      if (!isStreamingActive) {
        _renderNavigationHudFallback();
      }
    }

    // Draw popup banner overlay if active
    if (isPopupActive()) {
      _drawPopupBanner();
    }
  }

private:
  const char* _getDayOfWeekString(uint8_t dow) {
    switch (dow) {
      case 1: return "Thứ Hai";
      case 2: return "Thứ Ba";
      case 3: return "Thứ Tư";
      case 4: return "Thứ Năm";
      case 5: return "Thứ Sáu";
      case 6: return "Thứ Bảy";
      case 7: return "Chủ Nhật";
      default: return "Hôm nay";
    }
  }

  void _drawUtf8String(const char* str, int x, int y, uint16_t fgColor, uint16_t bgColor, const uint8_t* font = u8g2_font_unifont_t_vietnamese1) {
    u8f.setFont(font);
    u8f.setForegroundColor(fgColor);
    u8f.setBackgroundColor(bgColor);
    u8f.setCursor(x, y + 13);
    u8f.print(str);
  }

  void _drawCentreUtf8String(const char* str, int cx, int y, uint16_t fgColor, uint16_t bgColor, const uint8_t* font = u8g2_font_unifont_t_vietnamese1) {
    u8f.setFont(font);
    u8f.setForegroundColor(fgColor);
    u8f.setBackgroundColor(bgColor);
    int w = u8f.getUTF8Width(str);
    u8f.setCursor(cx - (w / 2), y + 13);
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

  // =========================================================================
  // POPUP BANNER (5 Seconds on Top for All Screens)
  // =========================================================================
  void _drawPopupBanner() {
    uint16_t cBg = tft.color565(15, 23, 42); // Deep Slate 900
    uint16_t cBorder;
    uint16_t cIconCircle;
    const uint8_t* iconBitmap = icon_bell_20x20;

    String appStr = String(_popupData.app);
    appStr.toLowerCase();

    if (_popupData.isCall || appStr == "call" || appStr == "phone") {
      cBorder = TFT_GREEN;
      cIconCircle = tft.color565(34, 197, 94);
      iconBitmap = icon_call_20x20;
    } else if (appStr.indexOf("zalo") >= 0) {
      cBorder = tft.color565(0, 136, 255);
      cIconCircle = tft.color565(0, 136, 255);
      iconBitmap = icon_zalo_20x20;
    } else if (appStr.indexOf("messenger") >= 0) {
      cBorder = tft.color565(168, 85, 247);
      cIconCircle = tft.color565(168, 85, 247);
      iconBitmap = icon_messenger_20x20;
    } else if (appStr.indexOf("telegram") >= 0) {
      cBorder = tft.color565(0, 175, 240);
      cIconCircle = tft.color565(0, 175, 240);
      iconBitmap = icon_telegram_20x20;
    } else if (appStr.indexOf("sms") >= 0) {
      cBorder = tft.color565(34, 197, 94);
      cIconCircle = tft.color565(34, 197, 94);
      iconBitmap = icon_sms_20x20;
    } else {
      cBorder = tft.color565(250, 204, 21);
      cIconCircle = tft.color565(234, 179, 8);
      iconBitmap = icon_bell_20x20;
    }

    // Outer card (x: 8, y: 6, w: 304, h: 48)
    tft.fillRoundRect(8, 6, 304, 48, 10, cBg);
    tft.drawRoundRect(8, 6, 304, 48, 10, cBorder);

    // Left App Icon (Circle 26px with centered 20x20 bitmap)
    tft.fillCircle(25, 30, 13, cIconCircle);
    tft.drawBitmap(15, 20, iconBitmap, 20, 20, TFT_WHITE);

    // Sender / Caller Title
    _drawUtf8String(_popupData.title, 45, 10, _popupData.isCall ? TFT_GREEN : TFT_YELLOW, cBg);

    // Message Body or Phone Number
    if (_popupData.message[0] != '\0') {
      _drawUtf8String(_popupData.message, 45, 28, TFT_WHITE, cBg);
    }
  }

  // =========================================================================
  // MÀN 1: STANDBY WATCHFACE (No Waybar, Multiple Styles, Flicker-Free)
  // =========================================================================
  void _renderStandbyWatchface() {
    if (_needFullRedraw) {
      tft.fillScreen(TFT_BLACK);

      // Check optional custom background image /bg_wait.jpg
      if (SPIFFS.exists("/bg_wait.jpg")) {
        File f = SPIFFS.open("/bg_wait.jpg", "r");
        if (f) {
          size_t fSize = f.size();
          f.close();
          if (fSize > 500) {
            TJpgDec.drawFsJpg(0, 0, "/bg_wait.jpg");
          }
        }
      }

      _lastState = _currentState;
      _lastWatchfaceStyle = _watchfaceStyle;
      _lastDrawnHour = 255;
      _lastDrawnMin = 255;
      _lastDrawnSec = 255;
      _lastDrawnDay = 255;
      _lastDrawnBat = 255;
      _lastDrawnBleState = !_navData.isConnected;
      _lastDrawnSong[0] = '\0';
      _needFullRedraw = false;

      _drawStaticWatchfaceLayout();
    }

    switch (_watchfaceStyle) {
      case 0:
        _updateWatchfaceDigitalMinimal();
        break;
      case 1:
        _updateWatchfaceAnalog();
        break;
      case 2:
        _updateWatchfaceDashboard();
        break;
      case 3:
        _updateWatchfaceCyberpunkNeon();
        break;
      default:
        _updateWatchfaceDigitalMinimal();
        break;
    }
  }

  void _drawStaticWatchfaceLayout() {
    if (_watchfaceStyle == 1) { // Analog
      const int cx = 160;
      const int cy = 118;
      const int r = 90;

      tft.drawCircle(cx, cy, r, tft.color565(51, 65, 85));
      tft.drawCircle(cx, cy, r - 1, tft.color565(30, 41, 59));

      for (int h = 0; h < 12; h++) {
        float angle = h * 30.0 * 0.0174533;
        int x1 = cx + (int)((r - 12) * sin(angle));
        int y1 = cy - (int)((r - 12) * cos(angle));
        int x2 = cx + (int)(r * sin(angle));
        int y2 = cy - (int)(r * cos(angle));
        _drawThickLine(x1, y1, x2, y2, TFT_WHITE, 2);
      }
    } else if (_watchfaceStyle == 2) { // Dashboard
      uint16_t cCardBg = tft.color565(19, 27, 38);
      uint16_t cBorder = tft.color565(32, 45, 61);

      tft.fillRoundRect(8, 10, 148, 220, 12, cCardBg);
      tft.drawRoundRect(8, 10, 148, 220, 12, cBorder);

      tft.fillRoundRect(164, 10, 148, 220, 12, cCardBg);
      tft.drawRoundRect(164, 10, 148, 220, 12, cBorder);

      tft.fillRoundRect(172, 50, 132, 110, 8, tft.color565(11, 17, 26));
    } else if (_watchfaceStyle == 3) { // Cyberpunk Neon
      uint16_t cNeonCyan = tft.color565(0, 240, 255);
      tft.drawRect(8, 8, 304, 224, cNeonCyan);
      tft.drawRect(10, 10, 300, 220, tft.color565(15, 35, 55));
      tft.drawRect(20, 125, 280, 8, tft.color565(30, 45, 65));
      tft.setTextColor(cNeonCyan, TFT_BLACK);
      tft.drawString("#ysiduc-s3", 24, 195, 2);
    }
  }

  // --- Style 0: Minimal Modern Digital (Flicker-Free) ---
  void _updateWatchfaceDigitalMinimal() {
    uint16_t cBg = TFT_BLACK;

    // 1. Bluetooth status icon top right
    if (_navData.isConnected != _lastDrawnBleState) {
      _lastDrawnBleState = _navData.isConnected;
      tft.drawBitmap(292, 10, icon_ble_16x16, 16, 16, _lastDrawnBleState ? TFT_CYAN : tft.color565(70, 80, 95));
    }

    // 2. Giant Digital Clock centered (update on minute change)
    if (_clockHour != _lastDrawnHour || _clockMin != _lastDrawnMin) {
      _lastDrawnHour = _clockHour;
      _lastDrawnMin = _clockMin;
      tft.setTextPadding(260);
      tft.setTextColor(TFT_WHITE, cBg);
      tft.drawCentreString(_navData.currentTime, 160, 55, 7);
      tft.setTextPadding(0);
    }

    // 3. Date in Vietnamese (update on day change)
    if (_clockDay != _lastDrawnDay) {
      _lastDrawnDay = _clockDay;
      tft.fillRect(10, 130, 300, 26, cBg);
      char dateStr[64];
      snprintf(dateStr, sizeof(dateStr), "%s, %02d/%02d/%04d",
               _getDayOfWeekString(_clockDayOfWeek), _clockDay, _clockMonth, _clockYear);
      _drawCentreUtf8String(dateStr, 160, 130, tft.color565(148, 163, 184), cBg);
    }

    // 4. Media info at bottom (update on song change)
    if (strcmp(_navData.songTitle, _lastDrawnSong) != 0) {
      strncpy(_lastDrawnSong, _navData.songTitle, sizeof(_lastDrawnSong) - 1);
      tft.fillRect(20, 175, 280, 42, cBg);
      if (_navData.songTitle[0] != '\0') {
        tft.fillRoundRect(30, 175, 260, 36, 8, tft.color565(15, 23, 42));
        tft.drawRoundRect(30, 175, 260, 36, 8, tft.color565(30, 41, 59));
        String fullSong = String(_navData.songTitle);
        if (_navData.songArtist[0] != '\0') fullSong += " • " + String(_navData.songArtist);
        _drawCentreUtf8String(fullSong.c_str(), 160, 185, tft.color565(250, 204, 21), tft.color565(15, 23, 42));
      }
    }
  }

  // --- Style 1: Classic Analog Clock (Flicker-Free) ---
  void _updateWatchfaceAnalog() {
    const int cx = 160;
    const int cy = 118;

    if (_clockSec != _lastDrawnSec || _clockMin != _lastDrawnMin || _clockHour != _lastDrawnHour) {
      _lastDrawnSec = _clockSec;
      _lastDrawnMin = _clockMin;
      _lastDrawnHour = _clockHour;

      tft.fillCircle(cx, cy, 76, TFT_BLACK);

      float hAngle = (_clockHour % 12 + _clockMin / 60.0) * 30.0 * 0.0174533;
      float mAngle = (_clockMin + _clockSec / 60.0) * 6.0 * 0.0174533;
      float sAngle = _clockSec * 6.0 * 0.0174533;

      int hx = cx + (int)(48 * sin(hAngle));
      int hy = cy - (int)(48 * cos(hAngle));
      _drawThickLine(cx, cy, hx, hy, TFT_WHITE, 4);

      int mx = cx + (int)(68 * sin(mAngle));
      int my = cy - (int)(68 * cos(mAngle));
      _drawThickLine(cx, cy, mx, my, TFT_CYAN, 3);

      int sx = cx + (int)(74 * sin(sAngle));
      int sy = cy - (int)(74 * cos(sAngle));
      int tailX = cx - (int)(14 * sin(sAngle));
      int tailY = cy + (int)(14 * cos(sAngle));
      _drawThickLine(tailX, tailY, sx, sy, tft.color565(239, 68, 68), 1);
      tft.fillCircle(cx, cy, 4, tft.color565(239, 68, 68));
    }

    if (_clockDay != _lastDrawnDay) {
      _lastDrawnDay = _clockDay;
      tft.fillRoundRect(cx + 40, cy - 10, 42, 20, 4, tft.color565(30, 41, 59));
      char dayBadge[10];
      snprintf(dayBadge, sizeof(dayBadge), "%02d/%02d", _clockDay, _clockMonth);
      tft.setTextColor(TFT_WHITE, tft.color565(30, 41, 59));
      tft.drawString(dayBadge, cx + 44, cy - 6, 2);
    }
  }

  // --- Style 2: Info Dashboard (Flicker-Free) ---
  void _updateWatchfaceDashboard() {
    uint16_t cCardBg = tft.color565(19, 27, 38);

    if (_clockHour != _lastDrawnHour || _clockMin != _lastDrawnMin) {
      _lastDrawnHour = _clockHour;
      _lastDrawnMin = _clockMin;
      tft.setTextPadding(130);
      tft.setTextColor(TFT_WHITE, cCardBg);
      tft.drawCentreString(_navData.currentTime, 82, 40, 6);
      tft.setTextPadding(0);
    }

    if (_clockSec != _lastDrawnSec) {
      _lastDrawnSec = _clockSec;
      char secStr[10];
      snprintf(secStr, sizeof(secStr), ":%02d", _clockSec);
      tft.setTextPadding(70);
      tft.setTextColor(TFT_CYAN, cCardBg);
      tft.drawCentreString(secStr, 82, 95, 4);
      tft.setTextPadding(0);
    }

    if (_clockDay != _lastDrawnDay) {
      _lastDrawnDay = _clockDay;
      tft.fillRect(12, 138, 140, 52, cCardBg);
      _drawCentreUtf8String(_getDayOfWeekString(_clockDayOfWeek), 82, 140, TFT_YELLOW, cCardBg);
      char dateStr[20];
      snprintf(dateStr, sizeof(dateStr), "%02d/%02d/%04d", _clockDay, _clockMonth, _clockYear);
      tft.setTextColor(tft.color565(148, 163, 184), cCardBg);
      tft.drawCentreString(dateStr, 82, 165, 2);
    }

    if (_navData.isConnected != _lastDrawnBleState) {
      _lastDrawnBleState = _navData.isConnected;
      tft.fillRect(172, 16, 130, 24, cCardBg);
      if (_lastDrawnBleState) {
        tft.fillCircle(180, 26, 4, TFT_GREEN);
        _drawUtf8String("BLE Đã kết nối", 192, 18, TFT_GREEN, cCardBg);
      }
    }

    if (strcmp(_navData.songTitle, _lastDrawnSong) != 0) {
      strncpy(_lastDrawnSong, _navData.songTitle, sizeof(_lastDrawnSong) - 1);
      tft.fillRect(174, 52, 128, 68, tft.color565(11, 17, 26));
      if (_navData.songTitle[0] != '\0') {
        _drawUtf8String("[>] Đang phát", 178, 56, TFT_YELLOW, tft.color565(11, 17, 26));
        _drawCentreUtf8String(_navData.songTitle, 238, 76, TFT_WHITE, tft.color565(11, 17, 26));
        _drawCentreUtf8String(_navData.songArtist, 238, 96, tft.color565(148, 163, 184), tft.color565(11, 17, 26));
      }
    }

    static unsigned long lastEqDash = 0;
    if (millis() - lastEqDash > 300) {
      lastEqDash = millis();
      tft.fillRect(182, 126, 108, 26, tft.color565(11, 17, 26));
      if (_navData.songTitle[0] != '\0') {
        static uint8_t eqIdx = 0;
        eqIdx = (eqIdx + 1) % 3;
        int eqPatterns[3][8] = {
          {4, 12, 18, 10, 14, 20, 8, 16},
          {14, 6, 12, 18, 8, 14, 18, 10},
          {8, 18, 10, 14, 20, 12, 14, 6}
        };
        for (int b = 0; b < 8; b++) {
          int h = eqPatterns[eqIdx][b];
          tft.fillRect(186 + (b * 12), 148 - h, 6, h, TFT_CYAN);
        }
      }
    }

    if (_navData.batteryLevel != _lastDrawnBat) {
      _lastDrawnBat = _navData.batteryLevel;
      char batStr[16];
      snprintf(batStr, sizeof(batStr), "Pin: %d%%", _navData.batteryLevel);
      tft.setTextPadding(120);
      tft.setTextColor(_navData.batteryLevel <= 20 ? TFT_RED : TFT_GREEN, cCardBg);
      tft.drawCentreString(batStr, 238, 185, 4);
      tft.setTextPadding(0);
    }
  }

  // --- Style 3: Cyberpunk Sport Neon (Flicker-Free) ---
  void _updateWatchfaceCyberpunkNeon() {
    uint16_t cNeonCyan = tft.color565(0, 240, 255);
    uint16_t cNeonYellow = tft.color565(250, 204, 21);

    if (_clockHour != _lastDrawnHour || _clockMin != _lastDrawnMin) {
      _lastDrawnHour = _clockHour;
      _lastDrawnMin = _clockMin;
      tft.setTextPadding(260);
      tft.setTextColor(cNeonYellow, TFT_BLACK);
      tft.drawCentreString(_navData.currentTime, 160, 40, 7);
      tft.setTextPadding(0);
    }

    if (_clockSec != _lastDrawnSec) {
      _lastDrawnSec = _clockSec;
      int progressW = map(_clockSec, 0, 59, 0, 280);
      tft.fillRect(20 + progressW, 125, 280 - progressW, 8, tft.color565(30, 45, 65));
      if (progressW > 0) {
        tft.fillRect(20, 125, progressW, 8, cNeonCyan);
      }
    }

    if (_clockDay != _lastDrawnDay) {
      _lastDrawnDay = _clockDay;
      tft.fillRect(20, 150, 280, 24, TFT_BLACK);
      char dateStr[64];
      snprintf(dateStr, sizeof(dateStr), "%s  //  %02d.%02d.%04d",
               _getDayOfWeekString(_clockDayOfWeek), _clockDay, _clockMonth, _clockYear);
      _drawCentreUtf8String(dateStr, 160, 150, TFT_WHITE, TFT_BLACK);
    }

    if (_navData.batteryLevel != _lastDrawnBat) {
      _lastDrawnBat = _navData.batteryLevel;
      char batStr[16];
      snprintf(batStr, sizeof(batStr), "PWR %d%%", _navData.batteryLevel);
      tft.setTextPadding(100);
      tft.setTextColor(cNeonCyan, TFT_BLACK);
      tft.drawRightString(batStr, 296, 195, 2);
      tft.setTextPadding(0);
    }
  }

  // =========================================================================
  // MÀN 2: APP IDLE MAP (No Waybar, Minimap Left + Media & Clock Right, Flicker-Free)
  // =========================================================================
  void _renderAppIdleMap() {
    uint16_t cCardBg = tft.color565(19, 27, 38);
    uint16_t cPillBg = tft.color565(11, 17, 26);
    uint16_t cBorder = tft.color565(32, 45, 61);

    if (_needFullRedraw) {
      tft.fillScreen(TFT_BLACK);
      _lastState = _currentState;
      _needFullRedraw = false;
      _lastDrawnHour = 255;
      _lastDrawnMin = 255;
      _lastDrawnSec = 255;
      _lastDrawnDay = 255;
      _lastDrawnBat = 255;
      _lastDrawnSong[0] = '\0';

      // 1. LEFT 50%: LIVE STANDBY MINIMAP (x: 4, y: 6, w: 148, h: 228)
      _renderStandbyVectorMap();

      // 2. RIGHT 50%: HUD CARD (x: 158, y: 6, w: 158, h: 228)
      tft.fillRoundRect(158, 6, 158, 228, 12, cCardBg);
      tft.drawRoundRect(158, 6, 158, 228, 12, cBorder);

      tft.fillRoundRect(164, 72, 146, 96, 8, cPillBg);
      tft.drawRoundRect(164, 72, 146, 96, 8, tft.color565(30, 41, 59));

      tft.fillRoundRect(164, 178, 146, 44, 8, cPillBg);
      tft.drawRoundRect(164, 178, 146, 44, 8, tft.color565(30, 41, 59));
      char batStr[16];
      snprintf(batStr, sizeof(batStr), "Pin iPhone: %d%%", _navData.batteryLevel);
      _drawCentreUtf8String(batStr, 237, 192, _navData.batteryLevel <= 20 ? TFT_RED : TFT_GREEN, cPillBg);
    }

    // Dynamic partial updates:
    // A. Big Digital Clock
    if (_clockHour != _lastDrawnHour || _clockMin != _lastDrawnMin) {
      _lastDrawnHour = _clockHour;
      _lastDrawnMin = _clockMin;
      tft.setTextPadding(140);
      tft.setTextColor(TFT_WHITE, cCardBg);
      tft.drawCentreString(_navData.currentTime, 237, 14, 4);
      tft.setTextPadding(0);
    }

    // B. Day & Date in Vietnamese
    if (_clockDay != _lastDrawnDay) {
      _lastDrawnDay = _clockDay;
      tft.fillRect(160, 44, 154, 24, cCardBg);
      char dateStr[32];
      snprintf(dateStr, sizeof(dateStr), "%s, %02d/%02d", _getDayOfWeekString(_clockDayOfWeek), _clockDay, _clockMonth);
      _drawCentreUtf8String(dateStr, 237, 45, tft.color565(148, 163, 184), cCardBg);
    }

    // C. Media / Music Player Card
    if (strcmp(_navData.songTitle, _lastDrawnSong) != 0) {
      strncpy(_lastDrawnSong, _navData.songTitle, sizeof(_lastDrawnSong) - 1);
      tft.fillRect(166, 74, 142, 66, cPillBg);
      bool hasSong = (strlen(_navData.songTitle) > 0 && strcmp(_navData.songTitle, "CHUA PHAT NHAC") != 0);
      if (hasSong) {
        _drawUtf8String("[>] Đang phát", 172, 78, TFT_YELLOW, cPillBg);
        _drawCentreUtf8String(_navData.songTitle, 237, 98, TFT_WHITE, cPillBg);
        _drawCentreUtf8String(_navData.songArtist, 237, 118, tft.color565(148, 163, 184), cPillBg);
      } else {
        _drawUtf8String("[--] Chưa phát", 172, 78, tft.color565(100, 116, 139), cPillBg);
      }
    }

    // Sound Equalizer Bars (animated)
    static unsigned long lastEqTick = 0;
    if (millis() - lastEqTick > 250) {
      lastEqTick = millis();
      bool hasSong = (strlen(_navData.songTitle) > 0 && strcmp(_navData.songTitle, "CHUA PHAT NHAC") != 0);
      tft.fillRect(186, 140, 105, 22, cPillBg);
      if (hasSong) {
        static uint8_t eqFrame = 0;
        eqFrame = (eqFrame + 1) % 4;
        int eqHeights[4][10] = {
          {4, 10, 16, 12, 6, 14, 18, 8, 12, 6},
          {8, 14, 8, 16, 12, 6, 10, 14, 8, 10},
          {12, 6, 12, 8, 16, 18, 6, 10, 14, 8},
          {6, 16, 10, 14, 8, 12, 16, 6, 10, 14}
        };
        for (int b = 0; b < 10; b++) {
          int bx = 188 + (b * 10);
          int h = eqHeights[eqFrame][b];
          tft.fillRect(bx, 160 - h, 5, h, TFT_CYAN);
        }
      } else {
        for (int b = 0; b < 10; b++) {
          tft.fillRect(188 + (b * 10), 158, 5, 2, tft.color565(30, 41, 59));
        }
      }
    }
  }

  // --- Vector Minimap for Standby Map Mode (Full height y: 6..234) ---
  void _renderStandbyVectorMap() {
    uint16_t cMapBg       = tft.color565(11, 17, 26);
    uint16_t cCardBorder  = TFT_CYAN;
    uint16_t cRadarRing   = tft.color565(20, 32, 48);
    uint16_t cRadarText   = tft.color565(60, 80, 105);
    uint16_t cAsphaltBed  = tft.color565(28, 38, 54);
    uint16_t cRoadBorder  = tft.color565(55, 75, 100);
    uint16_t cRouteActive = TFT_CYAN;

    tft.drawRoundRect(4, 6, 148, 228, 12, cCardBorder);
    tft.fillRoundRect(6, 8, 144, 224, 10, cMapBg);

    const int minX = 7, maxX = 149;
    const int minY = 9, maxY = 231;
    const int cx = 78;
    const int cy = 125;

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

    // Compass N
    tft.setTextColor(TFT_CYAN, cMapBg);
    tft.drawString("N", 12, 14, 2);
    tft.fillTriangle(26, 15, 23, 23, 29, 23, TFT_CYAN);

    // Live GPS Status Dot
    tft.fillCircle(142, 18, 3, TFT_GREEN);
  }

  // =========================================================================
  // MÀN 3 FALLBACK HUD (When WebSocket stream is not yet transmitting)
  // =========================================================================
  void _renderNavigationHudFallback() {
    if (_needFullRedraw) {
      tft.fillScreen(TFT_BLACK);
      _drawWaybar();
      _renderStandbyVectorMap();
      tft.fillRoundRect(158, 28, 158, 206, 12, tft.color565(19, 27, 38));
      tft.drawRoundRect(158, 28, 158, 206, 12, tft.color565(32, 45, 61));
      _needFullRedraw = false;
      _lastState = _currentState;
    }

    // Distance
    tft.setTextColor(TFT_WHITE, tft.color565(19, 27, 38));
    char distStr[16];
    if (_navData.distMeters >= 1000) {
      snprintf(distStr, sizeof(distStr), "%.1f km", _navData.distMeters / 1000.0);
    } else {
      snprintf(distStr, sizeof(distStr), "%dm", _navData.distMeters);
    }
    tft.setTextPadding(120);
    tft.drawString(distStr, 172, 40, 4);

    // Speed
    char spdStr[16];
    snprintf(spdStr, sizeof(spdStr), "%d km/h", _navData.speedKmh);
    tft.setTextColor(TFT_CYAN, tft.color565(19, 27, 38));
    tft.drawString(spdStr, 172, 70, 2);
    tft.setTextPadding(0);

    // Street Name
    tft.fillRoundRect(164, 100, 146, 38, 8, tft.color565(11, 17, 26));
    _drawCentreUtf8String(_navData.streetName, 237, 110, TFT_YELLOW, tft.color565(11, 17, 26));

    // ETA
    char etaStr[16];
    snprintf(etaStr, sizeof(etaStr), "%d ph  •  %s", _navData.etaMinutes, _navData.arrivalTime);
    _drawCentreUtf8String(etaStr, 237, 160, TFT_GREEN, tft.color565(19, 27, 38));
  }

  // Waybar for Navigation Screen (y: 0..24)
  void _drawWaybar() {
    uint16_t cBarBg = tft.color565(8, 12, 18);
    tft.fillRect(0, 0, 320, 24, cBarBg);
    tft.drawFastHLine(0, 24, 320, tft.color565(25, 38, 55));

    // Left: Song Info with Playback Time
    if (_navData.songTitle[0] != '\0') {
      char songDesc[80];
      if (_navData.songDurationSec > 0 || _navData.songElapsedSec > 0) {
        int elM = _navData.songElapsedSec / 60;
        int elS = _navData.songElapsedSec % 60;
        if (_navData.songDurationSec > 0) {
          int durM = _navData.songDurationSec / 60;
          int durS = _navData.songDurationSec % 60;
          snprintf(songDesc, sizeof(songDesc), "♪ %s [%02d:%02d/%02d:%02d]", _navData.songTitle, elM, elS, durM, durS);
        } else {
          snprintf(songDesc, sizeof(songDesc), "♪ %s [%02d:%02d]", _navData.songTitle, elM, elS);
        }
      } else {
        snprintf(songDesc, sizeof(songDesc), "♪ %s", _navData.songTitle);
      }
      _drawUtf8String(songDesc, 6, 4, tft.color565(250, 204, 21), cBarBg);
    } else {
      tft.setTextColor(TFT_CYAN, cBarBg);
      tft.drawString("#ysiduc", 6, 4, 2);
    }

    // Right: Clock & Battery
    tft.setTextColor(TFT_WHITE, cBarBg);
    tft.drawString(_navData.currentTime, 226, 4, 2);

    char batStr[16];
    snprintf(batStr, sizeof(batStr), "%d%%", _navData.batteryLevel);
    uint16_t cBat = _navData.batteryLevel <= 20 ? TFT_RED : TFT_GREEN;
    tft.setTextColor(cBat, cBarBg);
    tft.drawRightString(batStr, 298, 4, 2);

    // Battery icon
    tft.drawRect(302, 7, 14, 10, cBat);
    tft.fillRect(316, 10, 2, 4, cBat);
    tft.fillRect(304, 9, 10, 6, cBarBg);
    int fillW = constrain((_navData.batteryLevel * 10) / 100, 0, 10);
    if (fillW > 0) tft.fillRect(304, 9, fillW, 6, cBat);
  }
};

#endif // DISPLAY_UI_H
