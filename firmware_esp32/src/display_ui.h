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

enum AppSourceType : uint8_t {
  APP_SOURCE_SIM = 0,
  APP_SOURCE_ZALO = 1,
  APP_SOURCE_MESSENGER = 2,
  APP_SOURCE_SMS = 3,
  APP_SOURCE_OTHER = 4
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
  char title[64] = "";
  char message[128] = "";
  unsigned long expireMillis = 0;
  bool isCall = false;
  bool active = false;
  AppSourceType appSource = APP_SOURCE_OTHER;
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
  char _lastWaybarTime[16] = "";
  char _lastWaybarSong[64] = "";
  uint16_t _lastWaybarElapsed = 0xFFFF;
  uint8_t _lastWaybarBat = 255;
  char _lastDrawnArtist[32] = "";
  bool _lastDrawnBleState = false;

  // Minimap cached state
  bool _minimapDrawn = false;

  // Marquee (thả trôi) state
  struct Marquee { char text[96]; int textW; int off; unsigned long last; unsigned long pauseUntil; };
  Marquee _mqIdle = {"", 0, 0, 0, 0};
  Marquee _mqBar = {"", 0, 0, 0, 0};
  TFT_eSprite _wbSpr = TFT_eSprite(&tft);
  U8g2_for_TFT_eSPI _wbU8;
  bool _wbForce = true;
  uint16_t _lastIdleElapsed = 0xFFFF;

  // Last notification shown in the Màn 2 notification box
  NotificationPopup _notif;
  bool _notifShown = false;
  bool _notifDirty = true;
  bool _navPopupDirty = false;
  unsigned long _notifExpire = 0;

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

    _wbSpr.createSprite(168, 24);
    _wbU8.begin(_wbSpr);
    _wbU8.setFontMode(0);
    _wbU8.setFontDirection(0);
    _wbU8.setFont(u8g2_font_unifont_t_vietnamese1);

    marqueeSpr.createSprite(140, 24);
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

  void setNavigating(bool isNav) {
    if (_navData.isNavigating != isNav) {
      _navData.isNavigating = isNav;
      _currentState = isNav ? STATE_NAVIGATION : (_isAppConnected ? STATE_APP_IDLE_MAP : STATE_STANDBY_WATCHFACE);
      _needFullRedraw = true;
    }
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

  DisplayState getCurrentState() const {
    return _currentState;
  }

  bool isCallActive() const {
    return (_popupData.active && _popupData.isCall && millis() < _popupData.expireMillis) ||
           (_notifShown && _notif.isCall && millis() < _notifExpire);
  }

  // Unified Notification Popup (duration default 5000ms per request)
  void showNotificationPopup(const char* app, const char* title, const char* msg, bool isCall = false, uint32_t durationMs = 5000) {
    strncpy(_popupData.app, (app && strlen(app) > 0) ? app : (isCall ? "call" : "bell"), sizeof(_popupData.app) - 1);
    _popupData.app[sizeof(_popupData.app) - 1] = '\0';
    strncpy(_popupData.title, (title && strlen(title) > 0) ? title : (isCall ? "Cuộc gọi đến" : "Thông báo"), sizeof(_popupData.title) - 1);
    _popupData.title[sizeof(_popupData.title) - 1] = '\0';
    strncpy(_popupData.message, (msg && strlen(msg) > 0) ? msg : (isCall ? "Đang đổ chuông..." : ""), sizeof(_popupData.message) - 1);
    _popupData.message[sizeof(_popupData.message) - 1] = '\0';
    _popupData.isCall = isCall;
    _popupData.expireMillis = millis() + durationMs;
    _popupData.active = true;

    String a = String(_popupData.app);
    a.toLowerCase();
    if (a.indexOf("zalo") >= 0) _popupData.appSource = APP_SOURCE_ZALO;
    else if (a.indexOf("messenger") >= 0 || a.indexOf("orca") >= 0) _popupData.appSource = APP_SOURCE_MESSENGER;
    else if (a.indexOf("sms") >= 0 || a.indexOf("message") >= 0) _popupData.appSource = APP_SOURCE_SMS;
    else if (a.indexOf("call") >= 0 || a.indexOf("phone") >= 0 || isCall) _popupData.appSource = APP_SOURCE_SIM;
    else _popupData.appSource = APP_SOURCE_OTHER;

    // Set dirty flags for main loop thread to render safely - NEVER DRAW FROM BLE CALLBACK!
    _notif = _popupData;
    _notifShown = true;
    _notifDirty = true;
    _navPopupDirty = true;
    _notifExpire = millis() + durationMs;
    _wbForce = true;
  }

  void showCallAlert(const char* callerName, const char* phoneOrMsg = nullptr, AppSourceType app = APP_SOURCE_SIM) {
    const char* appStr = (app == APP_SOURCE_ZALO) ? "zalo" : ((app == APP_SOURCE_MESSENGER) ? "messenger" : "call");
    showNotificationPopup(appStr, callerName, phoneOrMsg, true, 60000);
  }

  void showSmsAlert(const char* sender, const char* msg, AppSourceType app = APP_SOURCE_SMS) {
    const char* appStr = (app == APP_SOURCE_ZALO) ? "zalo" : ((app == APP_SOURCE_MESSENGER) ? "messenger" : "sms");
    showNotificationPopup(appStr, sender, msg, false, 5000);
  }

  void updatePopupDetails(const char* title, const char* msg, AppSourceType app) {
    if (title && strlen(title) > 0) {
      strncpy(_popupData.title, title, sizeof(_popupData.title) - 1);
      _popupData.title[sizeof(_popupData.title) - 1] = '\0';
      strncpy(_notif.title, title, sizeof(_notif.title) - 1);
      _notif.title[sizeof(_notif.title) - 1] = '\0';
    }
    if (msg && strlen(msg) > 0) {
      strncpy(_popupData.message, msg, sizeof(_popupData.message) - 1);
      _popupData.message[sizeof(_popupData.message) - 1] = '\0';
      strncpy(_notif.message, msg, sizeof(_notif.message) - 1);
      _notif.message[sizeof(_notif.message) - 1] = '\0';
    }
    _popupData.appSource = app;
    _notif.appSource = app;
    _notifDirty = true;
    _navPopupDirty = true;
    _wbForce = true;
  }

  void dismissPopup() {
    bool wasActive = _popupData.active;
    _popupData.active = false;
    _popupData.expireMillis = 0;
    _navPopupDirty = false;
    if (_notifShown && _notif.isCall) {
      _notifShown = false;
      _notifDirty = true;
    }
    if (wasActive && (_currentState == STATE_NAVIGATION || _currentState == STATE_STANDBY_WATCHFACE)) {
      _needFullRedraw = true;
    }
  }

  void dismissAlert() {
    dismissPopup();
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
      if (_currentState == STATE_NAVIGATION) {
        if (_navPopupDirty) {
          _drawNavPopupCard();
          _navPopupDirty = false;
        }
      } else if (_currentState == STATE_STANDBY_WATCHFACE) {
        _drawPopupBanner();
      }
    }
  }

  // Draw top waybar on Navigation screen (Màn 3)
  void drawWaybarIfNav() {
    _wbForce = true;
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

    // 2. Check Popup expiration (auto dismiss after expiry)
    if (_popupData.active && millis() >= _popupData.expireMillis) {
      _popupData.active = false;
      _popupData.expireMillis = 0;
      _navPopupDirty = false;
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
      if (isStreamingActive && _needFullRedraw) {
        _wbForce = true;
        _needFullRedraw = false;
        _lastState = _currentState;
      }
      // Waybar at y: 0..24 is ALWAYS visible and updated, never hidden by popup
      _updateWaybar(_wbForce);
      _wbForce = false;
    }

    // Draw popup if active
    if (isPopupActive()) {
      if (_currentState == STATE_NAVIGATION) {
        if (_navPopupDirty) {
          _drawNavPopupCard();
          _navPopupDirty = false;
        }
      } else if (_currentState == STATE_STANDBY_WATCHFACE) {
        static unsigned long lastBanner = 0;
        if (millis() - lastBanner > 400) {
          lastBanner = millis();
          _drawPopupBanner();
        }
      }
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
    if (str == nullptr || str[0] == '\0') return;
    u8f.setFont(font);
    u8f.setForegroundColor(fgColor);
    u8f.setBackgroundColor(bgColor);
    u8f.setCursor(x, y + 13);
    u8f.print(str);
  }

  void _drawCentreUtf8String(const char* str, int cx, int y, uint16_t fgColor, uint16_t bgColor, const uint8_t* font = u8g2_font_unifont_t_vietnamese1) {
    if (str == nullptr || str[0] == '\0') return;
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
  // POPUP CARD CHO MÀN 3 (ĐANG DẪN ĐƯỜNG):
  // Dưới Waybar (y: 28), bên phải (x: 160), ngang hàng ô chỉ hướng (w: 156, h: 58)
  // =========================================================================
  void _drawNavPopupCard() {
    const int px = 160;
    const int py = 28;
    const int pw = 156;
    const int ph = 58;

    uint16_t cBg = tft.color565(15, 23, 42); // Deep Slate 900
    uint16_t cBorder;
    uint16_t cIconCircle;
    const uint8_t* iconBitmap = icon_bell_20x20;
    _notifStyle(_popupData, cBorder, cIconCircle, iconBitmap);

    // Xóa sạch vùng đệm 160x64 MCU block để chống sót pixel từ map
    tft.fillRect(160, 25, 160, 63, tft.color565(11, 17, 26));

    // Outer card
    tft.fillRoundRect(px, py, pw, ph, 8, cBg);
    tft.drawRoundRect(px, py, pw, ph, 8, cBorder);
    if (_popupData.isCall) {
      tft.drawRoundRect(px + 1, py + 1, pw - 2, ph - 2, 7, cBorder);
    }

    // Left App Icon (Circle 24px with centered 20x20 bitmap)
    const int iconCx = px + 17;
    const int iconCy = py + (ph / 2);
    tft.fillCircle(iconCx, iconCy, 12, cIconCircle);
    tft.drawBitmap(iconCx - 10, iconCy - 10, iconBitmap, 20, 20, TFT_WHITE);

    // Text area: x = px + 34 = 194. Max text width = pw - 38 = 118px.
    const int textX = px + 34;
    const int maxW = pw - 38;

    char titleLine[48];
    _fitUtf8(_popupData.title, titleLine, sizeof(titleLine), maxW);

    if (_popupData.message[0] != '\0') {
      _drawUtf8String(titleLine, textX, py + 8, _popupData.isCall ? TFT_GREEN : TFT_YELLOW, cBg);

      char msgLine[48];
      _fitUtf8(_popupData.message, msgLine, sizeof(msgLine), maxW);
      _drawUtf8String(msgLine, textX, py + 28, TFT_WHITE, cBg);
    } else {
      _drawUtf8String(titleLine, textX, py + 18, _popupData.isCall ? TFT_GREEN : TFT_YELLOW, cBg);
    }
  }

  // =========================================================================
  // POPUP BANNER (Cho Màn 1 Standby Watchface)
  // =========================================================================
  void _drawPopupBanner() {
    uint16_t cBg = tft.color565(15, 23, 42); // Deep Slate 900
    uint16_t cBorder;
    uint16_t cIconCircle;
    const uint8_t* iconBitmap = icon_bell_20x20;
    _notifStyle(_popupData, cBorder, cIconCircle, iconBitmap);

    // Outer card (x: 8, y: 4, w: 304, h: 48)
    tft.fillRoundRect(8, 4, 304, 48, 10, cBg);
    tft.drawRoundRect(8, 4, 304, 48, 10, cBorder);
    if (_popupData.isCall) {
      tft.drawRoundRect(9, 5, 302, 46, 9, cBorder);
    }

    // Left App Icon (Circle 26px with centered 20x20 bitmap)
    tft.fillCircle(24, 28, 13, cIconCircle);
    tft.drawBitmap(14, 18, iconBitmap, 20, 20, TFT_WHITE);

    // Sender / Caller Title
    char tLine[64];
    _fitUtf8(_popupData.title, tLine, sizeof(tLine), 250);
    _drawUtf8String(tLine, 44, 8, _popupData.isCall ? TFT_GREEN : TFT_YELLOW, cBg);

    // Message Body or Phone Number
    if (_popupData.message[0] != '\0') {
      char mLine[64];
      _fitUtf8(_popupData.message, mLine, sizeof(mLine), 250);
      _drawUtf8String(mLine, 44, 26, TFT_WHITE, cBg);
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
    bool musicRedraw = false;

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
      _lastIdleElapsed = 0xFFFF;
      _mqIdle.text[0] = '\0';
      _notifDirty = true;
      musicRedraw = true;

      _renderStandbyVectorMap();

      tft.fillRoundRect(158, 6, 158, 228, 12, cCardBg);
      tft.drawRoundRect(158, 6, 158, 228, 12, cBorder);

      // Music pill (compact height: 40px, x164 y80 w146 h40)
      tft.fillRoundRect(164, 80, 146, 40, 8, cPillBg);
      tft.drawRoundRect(164, 80, 146, 40, 8, tft.color565(30, 41, 59));

      // Notification pill (expanded height: 106px, x164 y124 w146 h106)
      _drawNotifBox();
    }

    if (_clockHour != _lastDrawnHour || _clockMin != _lastDrawnMin) {
      _lastDrawnHour = _clockHour;
      _lastDrawnMin = _clockMin;
      tft.setTextPadding(140);
      tft.setTextColor(TFT_WHITE, cCardBg);
      tft.drawCentreString(_navData.currentTime, 237, 14, 4);
      tft.setTextPadding(0);
    }

    if (_clockDay != _lastDrawnDay) {
      _lastDrawnDay = _clockDay;
      tft.fillRect(160, 44, 154, 26, cCardBg);
      char dateStr[32];
      snprintf(dateStr, sizeof(dateStr), "%s, %02d/%02d", _getDayOfWeekString(_clockDayOfWeek), _clockDay, _clockMonth);
      _drawCentreUtf8String(dateStr, 237, 46, tft.color565(148, 163, 184), cCardBg);
      tft.drawFastHLine(172, 74, 130, cBorder);
    }

    // Music: "Tên bài • Tác giả" thả trôi trên 1 dòng + thời gian phát
    bool hasSong = (strlen(_navData.songTitle) > 0 && strcmp(_navData.songTitle, "CHUA PHAT NHAC") != 0);
    bool songChanged = (strcmp(_navData.songTitle, _lastDrawnSong) != 0);
    if (songChanged) {
      strncpy(_lastDrawnSong, _navData.songTitle, sizeof(_lastDrawnSong) - 1);
      _lastDrawnSong[sizeof(_lastDrawnSong) - 1] = '\0';
      musicRedraw = true;
      tft.fillRect(166, 82, 142, 36, cPillBg);
      _mqIdle.text[0] = '\0';
      _lastIdleElapsed = 0xFFFF;
      if (!hasSong) {
        _drawCentreUtf8String("Chưa phát nhạc", 237, 92, tft.color565(100, 116, 139), cPillBg);
      }
    }
    if (hasSong) {
      char full[100];
      if (_navData.songArtist[0] != '\0') snprintf(full, sizeof(full), "%s • %s", _navData.songTitle, _navData.songArtist);
      else snprintf(full, sizeof(full), "%s", _navData.songTitle);
      _marquee(_mqIdle, marqueeSpr, u8f_marquee, 167, 82, full, tft.color565(250, 204, 21), cPillBg, musicRedraw);

      uint16_t elKey = (_navData.songElapsedSec > 0 || _navData.songDurationSec > 0) ? _navData.songElapsedSec : 0xFFFE;
      if (_lastIdleElapsed != elKey) {
        _lastIdleElapsed = elKey;
        tft.fillRect(166, 102, 142, 16, cPillBg);
        if (elKey != 0xFFFE) {
          char timeStr[32];
          int elM = _navData.songElapsedSec / 60, elS = _navData.songElapsedSec % 60;
          if (_navData.songDurationSec > 0) {
            snprintf(timeStr, sizeof(timeStr), "%02d:%02d / %02d:%02d", elM, elS,
                     _navData.songDurationSec / 60, _navData.songDurationSec % 60);
          } else {
            snprintf(timeStr, sizeof(timeStr), "%02d:%02d", elM, elS);
          }
          _drawCentreUtf8String(timeStr, 237, 102, TFT_CYAN, cPillBg);
        }
      }
    }

    // Notification box (messages / calls)
    if (_notifShown && millis() > _notifExpire) {
      _notifShown = false;
      _notifDirty = true;
    }
    if (_notifDirty) {
      _notifDirty = false;
      _drawNotifBox();
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
      _wbForce = true;
      tft.fillRoundRect(4, 28, 148, 206, 12, tft.color565(11, 17, 26));
      tft.drawRoundRect(4, 28, 148, 206, 12, TFT_CYAN);
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

  // Cắt chuỗi UTF-8 cho vừa chiều rộng maxW (px). Trả về số byte giữ lại.
  int _fitUtf8(const char* in, char* out, size_t outSz, int maxW) {
    if (in == nullptr || in[0] == '\0' || out == nullptr || outSz <= 1) {
      if (out && outSz > 0) out[0] = '\0';
      return 0;
    }
    strncpy(out, in, outSz - 1);
    out[outSz - 1] = '\0';
    u8f.setFont(u8g2_font_unifont_t_vietnamese1);
    int n = strlen(out);
    while (n > 0 && u8f.getUTF8Width(out) > maxW) {
      n--;
      while (n > 0 && (((uint8_t)out[n]) & 0xC0) == 0x80) n--;
      out[n] = '\0';
    }
    return n;
  }

  // Chữ thả trôi trong sprite (cuộn ngang khi dài hơn khung, đứng yên + căn giữa khi ngắn)
  void _marquee(Marquee& m, TFT_eSprite& spr, U8g2_for_TFT_eSPI& u8, int x, int y,
                const char* text, uint16_t fg, uint16_t bg, bool force) {
    if (text == nullptr) text = "";
    if (strcmp(text, m.text) != 0) {
      strncpy(m.text, text, sizeof(m.text) - 1);
      m.text[sizeof(m.text) - 1] = '\0';
      u8.setFont(u8g2_font_unifont_t_vietnamese1);
      m.textW = u8.getUTF8Width(m.text);
      m.off = 0;
      m.pauseUntil = millis() + 1500;
      force = true;
    }
    const int w = spr.width();
    u8.setForegroundColor(fg);
    u8.setBackgroundColor(bg);
    if (m.textW <= w) {
      if (force) {
        spr.fillSprite(bg);
        u8.setCursor((w - m.textW) / 2, 17);
        u8.print(m.text);
        spr.pushSprite(x, y);
      }
      return;
    }
    unsigned long now = millis();
    if (!force) {
      if (now < m.pauseUntil || now - m.last < 45) return;
      m.last = now;
      m.off += 2;
      if (m.off >= m.textW + 28) {
        m.off = 0;
        m.pauseUntil = now + 1200;
      }
    }
    spr.fillSprite(bg);
    u8.setCursor(-m.off, 17);
    u8.print(m.text);
    u8.setCursor(-m.off + m.textW + 28, 17);
    u8.print(m.text);
    spr.pushSprite(x, y);
  }

  // Waybar Màn 3 (y: 0..24): giờ (trái) | tên bài hát thả trôi (giữa) | pin (phải).
  // Chỉ vẽ lại phần thay đổi => không nháy.
  void _updateWaybar(bool force) {
    const uint16_t cBarBg = tft.color565(8, 12, 18);
    if (force) {
      tft.fillRect(0, 0, 320, 24, cBarBg);
      tft.drawFastHLine(0, 24, 320, tft.color565(25, 38, 55));
      _lastWaybarTime[0] = '\0';
      _lastWaybarElapsed = 0xFFFF;
      _lastWaybarBat = 255;
      _lastWaybarSong[0] = '\1';
      _mqBar.text[0] = '\0';
    }

    if (strcmp(_lastWaybarTime, _navData.currentTime) != 0) {
      strncpy(_lastWaybarTime, _navData.currentTime, sizeof(_lastWaybarTime) - 1);
      tft.setTextColor(TFT_WHITE, cBarBg);
      tft.setTextPadding(44);
      tft.drawString(_navData.currentTime, 6, 4, 2);
      tft.setTextPadding(0);
    }

    if (_lastWaybarBat != _navData.batteryLevel) {
      _lastWaybarBat = _navData.batteryLevel;
      char batStr[8];
      snprintf(batStr, sizeof(batStr), "%d%%", _navData.batteryLevel);
      uint16_t cBat = _navData.batteryLevel <= 20 ? TFT_RED : TFT_GREEN;
      tft.setTextColor(cBat, cBarBg);
      tft.setTextPadding(34);
      tft.drawRightString(batStr, 290, 4, 2);
      tft.setTextPadding(0);
      tft.drawRect(294, 6, 20, 11, cBat);
      tft.fillRect(314, 9, 2, 5, cBat);
      tft.fillRect(296, 8, 16, 7, cBarBg);
      int fillW = constrain((_navData.batteryLevel * 16) / 100, 0, 16);
      if (fillW > 0) tft.fillRect(296, 8, fillW, 7, cBat);
    }

    bool hasSong = (_navData.songTitle[0] != '\0' && strcmp(_navData.songTitle, "CHUA PHAT NHAC") != 0);
    bool hasElapsed = hasSong && (_navData.songElapsedSec > 0 || _navData.songDurationSec > 0);
    uint16_t elKey = hasElapsed ? _navData.songElapsedSec : 0xFFFE;
    if (_lastWaybarElapsed != elKey) {
      _lastWaybarElapsed = elKey;
      if (hasElapsed) {
        char t[12];
        snprintf(t, sizeof(t), "%02d:%02d", _navData.songElapsedSec / 60, _navData.songElapsedSec % 60);
        tft.setTextColor(TFT_CYAN, cBarBg);
        tft.setTextPadding(42);
        tft.drawString(t, 226, 4, 2);
        tft.setTextPadding(0);
      } else {
        tft.fillRect(224, 2, 46, 20, cBarBg);
      }
    }

    if (hasSong) {
      char full[100];
      if (_navData.songArtist[0] != '\0') snprintf(full, sizeof(full), "%s • %s", _navData.songTitle, _navData.songArtist);
      else snprintf(full, sizeof(full), "%s", _navData.songTitle);
      _marquee(_mqBar, _wbSpr, _wbU8, 54, 0, full, tft.color565(250, 204, 21), cBarBg, false);
    } else if (_lastWaybarSong[0] != '\0') {
      _lastWaybarSong[0] = '\0';
      _mqBar.text[0] = '\0';
      tft.fillRect(54, 0, 168, 24, cBarBg);
    }
  }

  void _notifStyle(const NotificationPopup& n, uint16_t& border, uint16_t& circle, const uint8_t*& icon) {
    String a = String(n.app);
    a.toLowerCase();
    if (n.isCall || n.appSource == APP_SOURCE_SIM || a == "call" || a == "phone") {
      border = TFT_GREEN; circle = tft.color565(34, 197, 94); icon = icon_call_20x20;
    } else if (n.appSource == APP_SOURCE_ZALO || a.indexOf("zalo") >= 0) {
      border = tft.color565(0, 136, 255); circle = border; icon = icon_zalo_20x20;
    } else if (n.appSource == APP_SOURCE_MESSENGER || a.indexOf("messenger") >= 0 || a.indexOf("orca") >= 0) {
      border = tft.color565(168, 85, 247); circle = border; icon = icon_messenger_20x20;
    } else if (a.indexOf("telegram") >= 0) {
      border = tft.color565(0, 175, 240); circle = border; icon = icon_telegram_20x20;
    } else if (n.appSource == APP_SOURCE_SMS || a.indexOf("sms") >= 0 || a.indexOf("message") >= 0) {
      border = tft.color565(34, 197, 94); circle = border; icon = icon_sms_20x20;
    } else {
      border = tft.color565(250, 204, 21); circle = tft.color565(234, 179, 8); icon = icon_bell_20x20;
    }
  }

  void _drawWrappedUtf8String(const char* text, int startX, int startY, int maxWidth, int maxLines, uint16_t fgColor, uint16_t bgColor, int lineHeight = 19) {
    if (text == nullptr || text[0] == '\0') return;

    u8f.setFont(u8g2_font_unifont_t_vietnamese1);
    u8f.setForegroundColor(fgColor);
    u8f.setBackgroundColor(bgColor);

    char currentLine[128];
    currentLine[0] = '\0';
    int lineCount = 0;
    int curY = startY;

    const char* ptr = text;
    while (*ptr != '\0' && lineCount < maxLines) {
      while (*ptr == ' ') ptr++;
      if (*ptr == '\0') break;

      char word[64];
      int wordLen = 0;
      while (*ptr != '\0' && *ptr != ' ' && wordLen < (int)sizeof(word) - 1) {
        word[wordLen++] = *ptr++;
      }
      word[wordLen] = '\0';

      char candidate[128];
      if (currentLine[0] == '\0') {
        strncpy(candidate, word, sizeof(candidate) - 1);
      } else {
        snprintf(candidate, sizeof(candidate), "%s %s", currentLine, word);
      }
      candidate[sizeof(candidate) - 1] = '\0';

      int w = u8f.getUTF8Width(candidate);
      if (w <= maxWidth) {
        strncpy(currentLine, candidate, sizeof(currentLine) - 1);
        currentLine[sizeof(currentLine) - 1] = '\0';
      } else {
        if (currentLine[0] != '\0') {
          u8f.setCursor(startX, curY + 13);
          u8f.print(currentLine);
          lineCount++;
          curY += lineHeight;
        }
        if (lineCount < maxLines) {
          strncpy(currentLine, word, sizeof(currentLine) - 1);
          currentLine[sizeof(currentLine) - 1] = '\0';
        } else {
          currentLine[0] = '\0';
          break;
        }
      }
    }

    if (currentLine[0] != '\0' && lineCount < maxLines) {
      if (*ptr != '\0') {
        strncat(currentLine, "...", sizeof(currentLine) - strlen(currentLine) - 1);
      }
      u8f.setCursor(startX, curY + 13);
      u8f.print(currentLine);
    }
  }

  // Ô thông báo (tin nhắn / cuộc gọi) mở rộng ở góc dưới phải Màn 2: x164 y124 w146 h106
  void _drawNotifBox() {
    const uint16_t cPill = tft.color565(11, 17, 26);
    if (_notifShown && millis() > _notifExpire) {
      _notifShown = false;
    }

    uint16_t border = tft.color565(30, 41, 59);
    uint16_t circle = 0;
    const uint8_t* icon = icon_bell_20x20;

    if (_notifShown) {
      _notifStyle(_notif, border, circle, icon);
    }

    tft.fillRoundRect(164, 124, 146, 106, 8, cPill);
    tft.drawRoundRect(164, 124, 146, 106, 8, border);
    if (_notifShown && _notif.isCall) {
      tft.drawRoundRect(165, 125, 144, 104, 7, border);
    }

    if (!_notifShown) {
      tft.fillCircle(237, 155, 12, tft.color565(20, 28, 40));
      tft.drawBitmap(227, 145, icon_bell_20x20, 20, 20, tft.color565(71, 85, 105));
      _drawCentreUtf8String("Chưa có thông báo", 237, 185, tft.color565(71, 85, 105), cPill);
      return;
    }

    // Header: App icon + Sender/Caller Title
    tft.fillCircle(181, 142, 12, circle);
    tft.drawBitmap(171, 132, icon, 20, 20, TFT_WHITE);

    char titleLine[64];
    _fitUtf8(_notif.title, titleLine, sizeof(titleLine), 104);
    _drawUtf8String(titleLine, 198, 133, _notif.isCall ? TFT_GREEN : TFT_YELLOW, cPill);

    tft.drawFastHLine(170, 158, 134, tft.color565(28, 38, 52));

    // Body: Lines 1, 2, 3
    if (_notif.isCall) {
      _drawUtf8String("Cuộc gọi đến", 172, 163, tft.color565(148, 163, 184), cPill);
      const char* phone = (_notif.message[0] != '\0') ? _notif.message : "Đang đổ chuông...";
      char pLine[64];
      _fitUtf8(phone, pLine, sizeof(pLine), 132);
      _drawUtf8String(pLine, 172, 183, TFT_WHITE, cPill);
      _drawUtf8String("Nhấc máy trên ĐT", 172, 203, tft.color565(100, 116, 139), cPill);
    } else {
      _drawWrappedUtf8String(_notif.message, 172, 163, 132, 3, TFT_WHITE, cPill, 19);
    }
  }
};

#endif // DISPLAY_UI_H
