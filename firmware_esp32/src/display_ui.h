#ifndef DISPLAY_UI_H
#define DISPLAY_UI_H

#include <Arduino.h>
#include <ArduinoJson.h>
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
#include "theme_backgrounds.h"

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

  // Watchface selection (0..5 built-in, 250 = custom ZIP theme on SPIFFS)
  uint8_t _watchfaceStyle = 0;
  // Idle map (Màn 2) theme selection (0..3 built-in, 250 = custom ZIP theme on SPIFFS)
  uint8_t _idleMapStyle = 0;
  uint8_t _brightnessPct = 100;
  uint8_t _previewScreenMode = 0; // 0=auto, 1=lock Màn 1, 2=preview Màn 2

  struct Man2Layout {
    bool hasBgJpg = false;
    bool drawPanelCard = true;
    uint16_t screenBg = 0x0000;
    // Minimap viewport (cropped from 144x224 JPEG centered inside)
    int16_t mapX = 6, mapY = 8, mapW = 144, mapH = 224, mapR = 10;
    uint16_t mapBorder = 0x3DF7;
    // Right/left HUD panel
    int16_t cardX = 158, cardY = 6, cardW = 158, cardH = 228, cardR = 12;
    uint16_t cardBg = 0x10C4, cardBorder = 0x2167;
    // Clock & Date
    bool clockVisible = true;
    int16_t clockX = 237, clockY = 14; uint8_t clockFont = 4; uint16_t clockColor = 0xFFFF;
    bool dateVisible = true;
    int16_t dateX = 237, dateY = 46; uint16_t dateColor = 0x9517;
    char dateFormat[12] = "vn_short";
    int16_t divX = 172, divY = 74, divW = 130;
    // Music pill
    bool songVisible = true;
    int16_t musicX = 164, musicY = 80, musicW = 146, musicH = 40;
    uint16_t musicBg = 0x0883, musicBorder = 0x1947, musicColor = 0xFE42, durColor = 0x07FF;
    // Notif box
    bool notifVisible = true;
    int16_t notifX = 164, notifY = 124, notifW = 146, notifH = 106;
    uint16_t notifBg = 0x0883, notifBorder = 0x1947, notifTitleColor = 0xFFE0, notifMsgColor = 0xFFFF;
  };
  Man2Layout _customMan2;
  bool _customMan2Loaded = false;
  bool _customMan2Dirty = true;

  struct CustomThemeBox {
    int16_t x = 0, y = 0, w = 0, h = 0, r = 0;
    uint16_t fill = 0, border = 0;
    bool hasFill = false, hasBorder = false;
  };
  struct CustomThemeLabel {
    char text[40] = {0};
    int16_t x = 0, y = 0, maxW = 140;
    uint16_t color = 0xFFFF;
    bool center = false;
    bool visible = false;
  };
  struct CustomThemeSpec {
    uint16_t bgColor = 0x0841;
    bool showWaybar = false;
    uint8_t boxCount = 0;
    CustomThemeBox boxes[6];
    uint8_t labelCount = 0;
    CustomThemeLabel labels[6];
    // Clock
    bool clockVisible = true;
    int16_t clockX = 20, clockY = 24;
    uint16_t clockColor = 0xFFE0;
    uint8_t clockFont = 6; // TFT_eSPI font 2,4,6,7
    bool clockCenter = false;
    // Date
    bool dateVisible = true;
    int16_t dateX = 22, dateY = 72;
    uint16_t dateColor = 0xFFFF;
    char dateFormat[12] = "vn_short";
    bool dateCenter = false;
    // Song
    bool songVisible = true;
    int16_t songX = 20, songY = 202, songW = 200;
    uint16_t songColor = 0xFEF1, songBgColor = 0x0841;
    // Duration
    bool durVisible = false;
    char durMode[12] = "ratio";
    int16_t durX = 232, durY = 202;
    uint16_t durColor = 0xFB40, durSecondary = 0xFFFF;
    // Notif title & message
    bool notifTitleVisible = true;
    int16_t notifTitleX = 180, notifTitleY = 44, notifTitleW = 120;
    uint16_t notifTitleColor = 0xFFE0;
    bool notifMsgVisible = true;
    int16_t notifMsgX = 180, notifMsgY = 64, notifMsgW = 120;
    uint8_t notifMsgLines = 4, notifMsgLineH = 16;
    uint16_t notifMsgColor = 0xFFFF;
  };
  CustomThemeSpec _customTheme;
  bool _customThemeLoaded = false;
  bool _customThemeDirty = true;

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
    Preferences prefs;
    prefs.begin("nav_ui", true);
    uint8_t savedStyle = prefs.getUChar("wf_style", 0);
    _watchfaceStyle = (savedStyle == 250) ? 250 : (savedStyle % 6);
    uint8_t savedM2 = prefs.getUChar("m2_style", 0);
    _idleMapStyle = (savedM2 == 250) ? 250 : (savedM2 % 4);
    _brightnessPct = constrain(prefs.getUChar("bl_pct", 100), 5, 100);
    prefs.end();

    #if defined(TFT_BL) && TFT_BL >= 0
    pinMode(TFT_BL, OUTPUT);
    digitalWrite(TFT_BL, LOW);
    #endif
    tft.init();
    #if defined(TFT_BL) && TFT_BL >= 0
    ledcSetup(0, 5000, 8);
    ledcAttachPin(TFT_BL, 0);
    _applyBrightnessPwm(_brightnessPct);
    #endif
    tft.setRotation(1); // Landscape 320x240
    tft.invertDisplay(false);
    tft.fillScreen(TFT_BLACK);
    u8f.begin(tft);
    u8f.setFontMode(0);
    u8f.setFontDirection(0);
    u8f.setFont(u8g2_font_unifont_t_vietnamese1);

    _wbSpr.createSprite(192, 24);
    _wbU8.begin(_wbSpr);
    _wbU8.setFontMode(0);
    _wbU8.setFontDirection(0);
    _wbU8.setFont(u8g2_font_unifont_t_vietnamese1);

    marqueeSpr.createSprite(140, 24);
    u8f_marquee.begin(marqueeSpr);
    u8f_marquee.setFontMode(0);
    u8f_marquee.setFontDirection(0);
    u8f_marquee.setFont(u8g2_font_unifont_t_vietnamese1);

    // Initial screen ready; saved style & brightness already loaded before tft.init()
    _needFullRedraw = true;
#endif
  }

  void setBrightness(uint8_t pct, bool persist = true) {
    _applyBrightnessPwm(pct);
    if (persist) {
      Preferences prefs;
      prefs.begin("nav_ui", false);
      prefs.putUChar("bl_pct", _brightnessPct);
      prefs.end();
    }
    Serial.printf("[UI] Brightness set to %d%%\n", _brightnessPct);
  }

  uint8_t getBrightness() const {
    return _brightnessPct;
  }

  void setWatchfaceStyle(uint8_t style) {
    _watchfaceStyle = (style == 250) ? 250 : (style % 6);
    Preferences prefs;
    prefs.begin("nav_ui", false);
    prefs.putUChar("wf_style", _watchfaceStyle);
    prefs.end();
    _needFullRedraw = true;
    Serial.printf("[UI] Watchface/Theme style set to %d\n", _watchfaceStyle);
  }

  void markCustomThemeReload() {
    _customThemeDirty = true;
    _customThemeLoaded = false;
    _needFullRedraw = true;
  }

  void setIdleMapStyle(uint8_t style) {
    _idleMapStyle = (style == 250) ? 250 : (style % 4);
    Preferences prefs;
    prefs.begin("nav_ui", false);
    prefs.putUChar("m2_style", _idleMapStyle);
    prefs.end();
    _needFullRedraw = true;
    Serial.printf("[UI] Idle map (Man 2) style set to %d\n", _idleMapStyle);
  }

  void markMan2ThemeReload() {
    _customMan2Dirty = true;
    _customMan2Loaded = false;
    _needFullRedraw = true;
  }

  void getIdleMinimapRect(int16_t& mx, int16_t& my, int16_t& mw, int16_t& mh, int16_t& br, uint16_t& borderCol) {
    Man2Layout l = _activeMan2Layout();
    mx = l.mapX;
    my = l.mapY;
    mw = l.mapW;
    mh = l.mapH;
    br = l.mapR;
    borderCol = l.mapBorder;
  }

  void setPreviewScreenMode(uint8_t mode) {
    _previewScreenMode = (mode <= 2) ? mode : 0;
    if (_previewScreenMode == 1) {
      _fullScreenStreamActive = false;
      _currentState = STATE_STANDBY_WATCHFACE;
    } else if (_previewScreenMode == 2) {
      _currentState = _navData.isNavigating ? STATE_NAVIGATION : STATE_APP_IDLE_MAP;
    } else {
      _currentState = _navData.isNavigating
          ? STATE_NAVIGATION
          : (_isAppConnected ? STATE_APP_IDLE_MAP : STATE_STANDBY_WATCHFACE);
    }
    _needFullRedraw = true;
    Serial.printf("[UI] Preview screen mode -> %d (state=%d)\n", _previewScreenMode, (int)_currentState);
  }

  void forceShowWatchfaceTheme() {
    _previewScreenMode = 1;
    _fullScreenStreamActive = false;
    _currentState = STATE_STANDBY_WATCHFACE;
    _needFullRedraw = true;
    Serial.println(F("[UI] Switched to Watchface/Theme display mode (Man 1)"));
  }

  void restoreIdleMap() {
    _previewScreenMode = 0;
    _isAppConnected = true;
    _currentState = _navData.isNavigating ? STATE_NAVIGATION : STATE_APP_IDLE_MAP;
    _needFullRedraw = true;
    Serial.println(F("[UI] Restored Idle Map state (Map Khoi)"));
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
      _previewScreenMode = 0;
      _navData.isNavigating = false;
      _fullScreenStreamActive = false;
      _currentState = STATE_STANDBY_WATCHFACE;
      _needFullRedraw = true;
    }
  }

  void setAppConnected(bool connected) {
    if (_isAppConnected != connected) {
      _isAppConnected = connected;
      if (connected) {
        _currentState = _navData.isNavigating
            ? STATE_NAVIGATION
            : (_previewScreenMode == 1 ? STATE_STANDBY_WATCHFACE : STATE_APP_IDLE_MAP);
      } else {
        _previewScreenMode = 0;
        _currentState = STATE_STANDBY_WATCHFACE;
        _navData.isNavigating = false;
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
    bool stateChanged = (_navData.isNavigating != isNav);
    _navData.isNavigating = isNav;
    if (isNav) _previewScreenMode = 0;
    DisplayState targetState = isNav
        ? STATE_NAVIGATION
        : (_previewScreenMode == 1
            ? STATE_STANDBY_WATCHFACE
            : ((_previewScreenMode == 2 || _isAppConnected) ? STATE_APP_IDLE_MAP : STATE_STANDBY_WATCHFACE));
    if (_currentState != targetState || stateChanged) {
      _currentState = targetState;
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
        _currentState = _navData.isNavigating
            ? STATE_NAVIGATION
            : (_previewScreenMode == 1 ? STATE_STANDBY_WATCHFACE : STATE_APP_IDLE_MAP);
      }
      _needFullRedraw = true;
    }
  }

  void setNavData(uint8_t turn, uint16_t dist, uint16_t totalDist, uint8_t speed, uint8_t eta,
                  const char* street, const char* arrival = "12:00", const char* clock = "12:00",
                  uint8_t battery = 85, const RoutePoint* pts = nullptr, uint8_t ptCount = 0,
                  bool isNav = false, int16_t head = 0) {
    bool stateChanged = (_navData.isNavigating != isNav);
    _navData.isNavigating = isNav;
    if (isNav) _previewScreenMode = 0;
    DisplayState targetState = isNav
        ? STATE_NAVIGATION
        : (_previewScreenMode == 1
            ? STATE_STANDBY_WATCHFACE
            : ((_previewScreenMode == 2 || _isAppConnected) ? STATE_APP_IDLE_MAP : STATE_STANDBY_WATCHFACE));
    if (_currentState != targetState || stateChanged) {
      _currentState = targetState;
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
    if (wasActive && (_currentState == STATE_NAVIGATION || (_currentState == STATE_STANDBY_WATCHFACE && _watchfaceStyle == 0))) {
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
        if (_watchfaceStyle == 0) {
          _drawPopupBanner();
        }
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
        // Chỉ hiện popup banner khi ở Theme 0 hoặc Theme 250 có bật waybar (không có khung notif riêng)
        if (_watchfaceStyle == 0 || (_watchfaceStyle == 250 && _customTheme.showWaybar && !_customTheme.notifMsgVisible)) {
          static unsigned long lastBanner = 0;
          if (millis() - lastBanner > 400) {
            lastBanner = millis();
            _drawPopupBanner();
          }
        }
      }
    }
  }

private:
  void _applyBrightnessPwm(uint8_t pct) {
    _brightnessPct = constrain(pct, 5, 100);
#if defined(DISPLAY_TFT_ST7789) && defined(TFT_BL) && TFT_BL >= 0
    uint8_t duty = (uint8_t)map((long)_brightnessPct, 0, 100, 0, 255);
    ledcWrite(0, duty);
#endif
  }

  uint16_t _parseHexColor565(const char* hexStr, uint16_t fallback) {
    if (!hexStr || hexStr[0] == '\0') return fallback;
    const char* p = hexStr;
    if (p[0] == '#') p++;
    else if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
    size_t len = strlen(p);
    if (len < 6) return fallback;
    char* endPtr = nullptr;
    uint32_t rgb = strtoul(p, &endPtr, 16);
    if (endPtr == p) return fallback;
    if (len == 8) rgb &= 0x00FFFFFF;
    uint8_t r = (rgb >> 16) & 0xFF;
    uint8_t g = (rgb >> 8) & 0xFF;
    uint8_t b = rgb & 0xFF;
    return tft.color565(r, g, b);
  }

  uint8_t _mapClockFont(int px, const char* family = "") {
    if (family && (strstr(family, "7seg") || strstr(family, "segment") || strstr(family, "mono")) && px >= 32) {
      return 7;
    }
    if (px >= 34) return 6;
    if (px >= 20) return 4;
    return 2;
  }

  void _loadCustomThemeSpec() {
    _customTheme = CustomThemeSpec();
    _customThemeLoaded = true;
    _customThemeDirty = false;
    if (!SPIFFS.exists("/custom_theme.json")) return;
    File f = SPIFFS.open("/custom_theme.json", "r");
    if (!f) return;
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, f);
    f.close();
    if (err) {
      Serial.printf("[UI] Failed parsing /custom_theme.json: %s\n", err.c_str());
      return;
    }
    _customTheme.bgColor = _parseHexColor565(doc["bgColor"] | "#0B111A", 0x0841);
    _customTheme.showWaybar = doc["showWaybar"] | false;

    if (doc["boxes"].is<JsonArray>()) {
      uint8_t idx = 0;
      for (JsonObject b : doc["boxes"].as<JsonArray>()) {
        if (idx >= 6) break;
        CustomThemeBox& dst = _customTheme.boxes[idx++];
        dst.x = b["x"] | 0;
        dst.y = b["y"] | 0;
        dst.w = b["w"] | 0;
        dst.h = b["h"] | 0;
        dst.r = b["r"] | 0;
        const char* fillStr = b["fill"] | "";
        const char* borderStr = b["border"] | "";
        dst.hasFill = (fillStr[0] != '\0');
        dst.hasBorder = (borderStr[0] != '\0');
        dst.fill = _parseHexColor565(fillStr, _customTheme.bgColor);
        dst.border = _parseHexColor565(borderStr, 0xFFFF);
      }
      _customTheme.boxCount = idx;
    }

    if (doc["labels"].is<JsonArray>()) {
      uint8_t idx = 0;
      for (JsonObject l : doc["labels"].as<JsonArray>()) {
        if (idx >= 6) break;
        CustomThemeLabel& dst = _customTheme.labels[idx++];
        dst.visible = l["visible"] | true;
        strncpy(dst.text, l["text"] | "", sizeof(dst.text) - 1);
        dst.text[sizeof(dst.text) - 1] = '\0';
        dst.x = l["x"] | 0;
        dst.y = l["y"] | 0;
        dst.maxW = l["maxW"] | 140;
        dst.color = _parseHexColor565(l["color"] | "#FFFFFF", 0xFFFF);
        dst.center = l["center"] | false;
      }
      _customTheme.labelCount = idx;
    }

    if (doc["clock"].is<JsonObject>()) {
      JsonObject c = doc["clock"];
      _customTheme.clockVisible = c["visible"] | true;
      _customTheme.clockX = c["x"] | 20;
      _customTheme.clockY = c["y"] | 24;
      _customTheme.clockColor = _parseHexColor565(c["color"] | "#FACC15", 0xFFE0);
      _customTheme.clockFont = _mapClockFont(c["fontSize"] | 42, c["font"] | "");
      _customTheme.clockCenter = c["center"] | false;
    }

    if (doc["date"].is<JsonObject>()) {
      JsonObject d = doc["date"];
      _customTheme.dateVisible = d["visible"] | true;
      _customTheme.dateX = d["x"] | 22;
      _customTheme.dateY = d["y"] | 72;
      _customTheme.dateColor = _parseHexColor565(d["color"] | "#FFFFFF", 0xFFFF);
      strncpy(_customTheme.dateFormat, d["format"] | "vn_short", sizeof(_customTheme.dateFormat) - 1);
      _customTheme.dateFormat[sizeof(_customTheme.dateFormat) - 1] = '\0';
      _customTheme.dateCenter = d["center"] | false;
    }

    if (doc["song"].is<JsonObject>()) {
      JsonObject s = doc["song"];
      _customTheme.songVisible = s["visible"] | true;
      _customTheme.songX = s["x"] | 20;
      _customTheme.songY = s["y"] | 202;
      _customTheme.songW = s["w"] | 200;
      _customTheme.songColor = _parseHexColor565(s["color"] | "#FEF08A", 0xFEF1);
      _customTheme.songBgColor = _parseHexColor565(s["bgColor"] | "#0B111A", _customTheme.bgColor);
    }

    if (doc["duration"].is<JsonObject>()) {
      JsonObject du = doc["duration"];
      _customTheme.durVisible = du["visible"] | false;
      strncpy(_customTheme.durMode, du["mode"] | "ratio", sizeof(_customTheme.durMode) - 1);
      _customTheme.durMode[sizeof(_customTheme.durMode) - 1] = '\0';
      _customTheme.durX = du["x"] | 232;
      _customTheme.durY = du["y"] | 202;
      _customTheme.durColor = _parseHexColor565(du["color"] | "#FB923C", 0xFB40);
      _customTheme.durSecondary = _parseHexColor565(du["secondaryColor"] | "#FFFFFF", 0xFFFF);
    }

    if (doc["notifTitle"].is<JsonObject>()) {
      JsonObject nt = doc["notifTitle"];
      _customTheme.notifTitleVisible = nt["visible"] | true;
      _customTheme.notifTitleX = nt["x"] | 180;
      _customTheme.notifTitleY = nt["y"] | 44;
      _customTheme.notifTitleW = nt["maxW"] | 120;
      _customTheme.notifTitleColor = _parseHexColor565(nt["color"] | "#FACC15", 0xFFE0);
    }

    if (doc["notifMsg"].is<JsonObject>()) {
      JsonObject nm = doc["notifMsg"];
      _customTheme.notifMsgVisible = nm["visible"] | true;
      _customTheme.notifMsgX = nm["x"] | 180;
      _customTheme.notifMsgY = nm["y"] | 64;
      _customTheme.notifMsgW = nm["maxW"] | 120;
      _customTheme.notifMsgLines = constrain((int)(nm["maxLines"] | 4), 1, 8);
      _customTheme.notifMsgLineH = constrain((int)(nm["lineHeight"] | 16), 12, 24);
      _customTheme.notifMsgColor = _parseHexColor565(nm["color"] | "#FFFFFF", 0xFFFF);
    }
    Serial.printf("[UI] Loaded /custom_theme.json (boxes=%d, labels=%d, waybar=%d)\n",
                  _customTheme.boxCount, _customTheme.labelCount, _customTheme.showWaybar);
  }

  void _loadCustomMan2Spec() {
    _customMan2 = Man2Layout();
    _customMan2Loaded = true;
    _customMan2Dirty = false;
    _customMan2.hasBgJpg = SPIFFS.exists("/custom_man2_bg.jpg");
    if (!SPIFFS.exists("/custom_man2.json")) return;
    File f = SPIFFS.open("/custom_man2.json", "r");
    if (!f) return;
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, f);
    f.close();
    if (err) {
      Serial.printf("[UI] Failed parsing /custom_man2.json: %s\n", err.c_str());
      return;
    }

    _customMan2.screenBg = _parseHexColor565(doc["bgColor"] | "#0B111A", 0x0841);
    _customMan2.drawPanelCard = doc["showPanel"] | true;

    if (doc["panel"].is<JsonObject>()) {
      JsonObject p = doc["panel"];
      _customMan2.cardX = p["x"] | 158;
      _customMan2.cardY = p["y"] | 6;
      _customMan2.cardW = p["w"] | 158;
      _customMan2.cardH = p["h"] | 228;
      _customMan2.cardR = p["r"] | 12;
      _customMan2.cardBg = _parseHexColor565(p["fill"] | "#131B26", _customMan2.cardBg);
      _customMan2.cardBorder = _parseHexColor565(p["border"] | "#202D3D", _customMan2.cardBorder);
    }

    if (doc["minimap"].is<JsonObject>()) {
      JsonObject m = doc["minimap"];
      _customMan2.mapX = constrain((int)(m["x"] | 6), 2, 300);
      _customMan2.mapY = constrain((int)(m["y"] | 8), 2, 220);
      _customMan2.mapW = constrain((int)(m["w"] | 144), 60, 144);
      _customMan2.mapH = constrain((int)(m["h"] | 224), 60, 224);
      _customMan2.mapR = m["r"] | 10;
      _customMan2.mapBorder = _parseHexColor565(m["border"] | "#38BDF8", _customMan2.mapBorder);
    }

    if (doc["clock"].is<JsonObject>()) {
      JsonObject c = doc["clock"];
      _customMan2.clockVisible = c["visible"] | true;
      _customMan2.clockX = c["x"] | 237;
      _customMan2.clockY = c["y"] | 14;
      _customMan2.clockColor = _parseHexColor565(c["color"] | "#FFFFFF", 0xFFFF);
      _customMan2.clockFont = _mapClockFont(c["fontSize"] | 26, c["font"] | "");
    }

    if (doc["date"].is<JsonObject>()) {
      JsonObject d = doc["date"];
      _customMan2.dateVisible = d["visible"] | true;
      _customMan2.dateX = d["x"] | 237;
      _customMan2.dateY = d["y"] | 46;
      _customMan2.dateColor = _parseHexColor565(d["color"] | "#94A3B8", _customMan2.dateColor);
      strncpy(_customMan2.dateFormat, d["format"] | "vn_short", sizeof(_customMan2.dateFormat) - 1);
      _customMan2.dateFormat[sizeof(_customMan2.dateFormat) - 1] = '\0';
    }

    if (doc["song"].is<JsonObject>()) {
      JsonObject s = doc["song"];
      _customMan2.songVisible = s["visible"] | true;
      _customMan2.musicX = s["boxX"] | _customMan2.cardX + 6;
      _customMan2.musicY = s["boxY"] | 80;
      _customMan2.musicW = constrain((int)(s["boxW"] | (_customMan2.cardW - 12)), 110, 152);
      _customMan2.musicH = s["boxH"] | 40;
      _customMan2.musicBg = _parseHexColor565(s["bgColor"] | "#0B111A", _customMan2.musicBg);
      _customMan2.musicBorder = _parseHexColor565(s["border"] | "#1E293B", _customMan2.musicBorder);
      _customMan2.musicColor = _parseHexColor565(s["color"] | "#FACC15", _customMan2.musicColor);
      _customMan2.durColor = _parseHexColor565(s["durColor"] | "#38BDF8", _customMan2.durColor);
    }

    if (doc["notif"].is<JsonObject>()) {
      JsonObject n = doc["notif"];
      _customMan2.notifVisible = n["visible"] | true;
      _customMan2.notifX = n["x"] | (_customMan2.cardX + 6);
      _customMan2.notifY = n["y"] | 124;
      _customMan2.notifW = constrain((int)(n["w"] | (_customMan2.cardW - 12)), 100, 160);
      _customMan2.notifH = constrain((int)(n["h"] | 106), 68, 130);
      _customMan2.notifBg = _parseHexColor565(n["fill"] | "#0B111A", _customMan2.notifBg);
      _customMan2.notifBorder = _parseHexColor565(n["border"] | "#1E293B", _customMan2.notifBorder);
      _customMan2.notifTitleColor = _parseHexColor565(n["titleColor"] | "#FACC15", 0xFFE0);
      _customMan2.notifMsgColor = _parseHexColor565(n["msgColor"] | "#FFFFFF", 0xFFFF);
    }
    _customMan2.divX = _customMan2.cardX + 14;
    _customMan2.divY = _customMan2.dateY + 26;
    _customMan2.divW = max(20, (int)_customMan2.cardW - 28);
  }

  Man2Layout _activeMan2Layout() {
    if (_idleMapStyle == 250) {
      if (_customMan2Dirty || !_customMan2Loaded) {
        _loadCustomMan2Spec();
      }
      return _customMan2;
    }

    Man2Layout l;
    l.screenBg = TFT_BLACK;
    l.mapX = 6; l.mapY = 8; l.mapW = 144; l.mapH = 224; l.mapR = 10;
    l.cardX = 158; l.cardY = 6; l.cardW = 158; l.cardH = 228; l.cardR = 12;

    switch (_idleMapStyle) {
      case 1: // Neon Cyber Map
        l.screenBg = tft.color565(5, 7, 20);
        l.mapBorder = tft.color565(236, 72, 153);
        l.cardBg = tft.color565(12, 16, 38);
        l.cardBorder = tft.color565(0, 240, 255);
        l.clockColor = tft.color565(0, 240, 255);
        l.clockFont = 7;
        l.dateColor = tft.color565(192, 132, 252);
        l.musicBg = tft.color565(9, 12, 28);
        l.musicBorder = tft.color565(236, 72, 153);
        l.musicColor = tft.color565(103, 232, 249);
        l.durColor = tft.color565(244, 114, 182);
        l.notifBg = tft.color565(9, 12, 28);
        l.notifBorder = tft.color565(0, 240, 255);
        break;
      case 2: // Sunflower Warm HUD
        l.screenBg = tft.color565(18, 14, 10);
        l.mapBorder = tft.color565(250, 204, 21);
        l.cardBg = tft.color565(34, 26, 18);
        l.cardBorder = tft.color565(217, 119, 6);
        l.clockColor = tft.color565(250, 204, 21);
        l.dateColor = tft.color565(253, 230, 138);
        l.musicBg = tft.color565(22, 17, 12);
        l.musicBorder = tft.color565(180, 83, 9);
        l.musicColor = tft.color565(254, 240, 138);
        l.durColor = tft.color565(251, 146, 60);
        l.notifBg = tft.color565(22, 17, 12);
        l.notifBorder = tft.color565(217, 119, 6);
        break;
      case 3: // Right-Hand Minimap
        l.screenBg = tft.color565(7, 12, 16);
        l.mapX = 170; l.mapY = 8;
        l.mapBorder = tft.color565(16, 185, 129);
        l.cardX = 4; l.cardY = 6; l.cardW = 158; l.cardH = 228;
        l.cardBg = tft.color565(14, 22, 30);
        l.cardBorder = tft.color565(30, 58, 72);
        l.clockX = 83; l.dateX = 83; l.divX = 18;
        l.clockColor = TFT_WHITE;
        l.dateColor = tft.color565(110, 231, 183);
        l.musicX = 10; l.musicY = 80; l.musicW = 146; l.musicH = 40;
        l.musicBg = tft.color565(9, 15, 22);
        l.musicBorder = tft.color565(16, 185, 129);
        l.durColor = tft.color565(52, 211, 153);
        l.notifX = 10; l.notifY = 124; l.notifW = 146; l.notifH = 106;
        l.notifBg = tft.color565(9, 15, 22);
        l.notifBorder = tft.color565(30, 58, 72);
        break;
      case 0:
      default:
        l.mapBorder = TFT_CYAN;
        break;
    }
    return l;
  }

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
  // Dưới Waybar (y: 28, cách Waybar 4px), bên phải (x: 152..316),
  // Chiều ngang dài ra (w: 164), chiều rộng/cao ngắn lại (h: 40)
  // =========================================================================
  void _drawNavPopupCard() {
    const int px = 152;
    const int py = 28;
    const int pw = 164;
    const int ph = 40;

    uint16_t cBg = tft.color565(15, 23, 42); // Deep Slate 900
    uint16_t cBorder;
    uint16_t cIconCircle;
    const uint8_t* iconBitmap = icon_bell_20x20;
    _notifStyle(_popupData, cBorder, cIconCircle, iconBitmap);

    // Outer card
    tft.fillRoundRect(px, py, pw, ph, 8, cBg);
    tft.drawRoundRect(px, py, pw, ph, 8, cBorder);
    if (_popupData.isCall) {
      tft.drawRoundRect(px + 1, py + 1, pw - 2, ph - 2, 7, cBorder);
    }

    // Left App Icon (Circle 20px with centered 20x20 bitmap)
    const int iconCx = px + 14;
    const int iconCy = py + (ph / 2);
    tft.fillCircle(iconCx, iconCy, 10, cIconCircle);
    tft.drawBitmap(iconCx - 10, iconCy - 10, iconBitmap, 20, 20, TFT_WHITE);

    // Text area: x = px + 28 = 180. Max text width = pw - 32 = 132px.
    const int textX = px + 28;
    const int maxW = pw - 32;

    char titleLine[48];
    _fitUtf8(_popupData.title, titleLine, sizeof(titleLine), maxW);

    if (_popupData.message[0] != '\0') {
      _drawUtf8String(titleLine, textX, py + 3, _popupData.isCall ? TFT_GREEN : TFT_YELLOW, cBg);

      char msgLine[48];
      _fitUtf8(_popupData.message, msgLine, sizeof(msgLine), maxW);
      _drawUtf8String(msgLine, textX, py + 19, TFT_WHITE, cBg);
    } else {
      _drawUtf8String(titleLine, textX, py + 11, _popupData.isCall ? TFT_GREEN : TFT_YELLOW, cBg);
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
  // MÀN 1: STANDBY WATCHFACE / 6 GIAO DIỆN MÔ PHỎNG (Styles 0..5)
  // =========================================================================
  void _drawUtf8StringTransparent(const char* str, int x, int y, uint16_t fgColor, const uint8_t* font = u8g2_font_unifont_t_vietnamese1) {
    if (str == nullptr || str[0] == '\0') return;
    u8f.setFont(font);
    u8f.setFontMode(1);
    u8f.setForegroundColor(fgColor);
    u8f.setCursor(x, y + 13);
    u8f.print(str);
    u8f.setFontMode(0);
  }

  void _drawCentreUtf8StringTransparent(const char* str, int cx, int y, uint16_t fgColor, const uint8_t* font = u8g2_font_unifont_t_vietnamese1) {
    if (str == nullptr || str[0] == '\0') return;
    u8f.setFont(font);
    u8f.setFontMode(1);
    u8f.setForegroundColor(fgColor);
    int w = u8f.getUTF8Width(str);
    u8f.setCursor(cx - (w / 2), y + 13);
    u8f.print(str);
    u8f.setFontMode(0);
  }

  void _drawTruncatedUtf8StringTransparent(const char* str, int x, int y, int maxW, uint16_t fgColor, const uint8_t* font = u8g2_font_unifont_t_vietnamese1) {
    if (str == nullptr || str[0] == '\0') return;
    u8f.setFont(font);
    u8f.setFontMode(1);
    u8f.setForegroundColor(fgColor);

    if (u8f.getUTF8Width(str) <= maxW) {
      u8f.setCursor(x, y + 13);
      u8f.print(str);
      u8f.setFontMode(0);
      return;
    }

    // Tên quá dài so với maxW -> Cắt ngắn và thêm '...'
    char buf[128];
    strncpy(buf, str, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    int dotW = u8f.getUTF8Width("...");
    int availW = maxW - dotW;
    if (availW < 10) availW = maxW;

    int len = strlen(buf);
    while (len > 0) {
      while (len > 0 && ((unsigned char)buf[len - 1] & 0xC0) == 0x80) {
        len--;
      }
      if (len > 0) len--;
      buf[len] = '\0';
      if (u8f.getUTF8Width(buf) <= availW) {
        break;
      }
    }

    strncat(buf, "...", sizeof(buf) - strlen(buf) - 1);
    u8f.setCursor(x, y + 13);
    u8f.print(buf);
    u8f.setFontMode(0);
  }

  void _drawWrappedUtf8StringTransparent(const char* text, int startX, int startY, int maxWidth, int maxLines, uint16_t fgColor, int lineHeight = 16) {
    if (!text || text[0] == '\0') return;
    u8f.setFont(u8g2_font_unifont_t_vietnamese1);
    u8f.setFontMode(1);
    u8f.setForegroundColor(fgColor);

    int lineCount = 0;
    const char* ptr = text;
    char lineBuf[96];

    while (*ptr != '\0' && lineCount < maxLines) {
      int lineLen = 0;
      lineBuf[0] = '\0';

      while (*ptr != '\0' && *ptr != '\n') {
        const char* nextWord = ptr;
        while (*nextWord != '\0' && *nextWord != ' ' && *nextWord != '\n') {
          nextWord++;
        }
        int wordLen = nextWord - ptr;

        char testBuf[96];
        if (lineLen > 0) {
          snprintf(testBuf, sizeof(testBuf), "%s %.*s", lineBuf, wordLen, ptr);
        } else {
          snprintf(testBuf, sizeof(testBuf), "%.*s", wordLen, ptr);
        }

        if (u8f.getUTF8Width(testBuf) > maxWidth) {
          if (lineLen == 0) {
            strncpy(lineBuf, testBuf, sizeof(lineBuf) - 1);
            ptr = nextWord;
            if (*ptr == ' ') ptr++;
          }
          break;
        }

        strncpy(lineBuf, testBuf, sizeof(lineBuf) - 1);
        lineLen = strlen(lineBuf);
        ptr = nextWord;
        if (*ptr == ' ') ptr++;
      }

      if (*ptr == '\n') ptr++;

      if (lineLen > 0) {
        u8f.setCursor(startX, startY + (lineCount * lineHeight) + 13);
        u8f.print(lineBuf);
        lineCount++;
      } else if (*ptr == '\0') {
        break;
      }
    }
    u8f.setFontMode(0);
  }

  void _drawSongTitle(const char* title, int x, int y, int w, int h, uint16_t fgColor, uint16_t bgColor, bool isRedraw) {
    if (!title || title[0] == '\0') return;

    u8f.setFont(u8g2_font_unifont_t_vietnamese1);
    int textW = u8f.getUTF8Width(title);

    if (textW <= w) {
      // Song title fits inside container! Only draw on full redraw (transparent, zero box)
      if (isRedraw) {
        _drawUtf8StringTransparent(title, x, y, fgColor);
      }
      return;
    }

    // Text is longer than container: Marquee scroll ("thả trôi") strictly inside viewport
    static unsigned long lastMarquee = 0;
    if (millis() - lastMarquee < 70 && !isRedraw) return;
    lastMarquee = millis();

    int gap = 28;
    int cycle = textW + gap;
    int offset = ((millis() / 60) % cycle);

    tft.setViewport(x, y, w, h);
    tft.fillRect(0, 0, w, h, bgColor);

    u8f.setFont(u8g2_font_unifont_t_vietnamese1);
    u8f.setFontMode(1);
    u8f.setForegroundColor(fgColor);

    u8f.setCursor(-offset, 13);
    u8f.print(title);

    if (w - (-offset + textW) > 0) {
      u8f.setCursor(-offset + cycle, 13);
      u8f.print(title);
    }

    u8f.setFontMode(0);
    tft.resetViewport();
  }

  // --- GIAO DIỆN 0: CUSTOM STATIC + WAYBAR ĐÁY ---
  void _drawDefaultWallpaper() {
    tft.fillRect(0, 0, 320, 240, tft.color565(15, 23, 42));
    tft.drawRoundRect(4, 4, 312, 208, 12, tft.color565(56, 189, 248));
    _drawCentreUtf8String("SAN SANG - DANG CHO KET NOI", 160, 95, tft.color565(56, 189, 248), tft.color565(15, 23, 42));
  }

  void _drawTheme0WaybarStatic() {
    tft.fillRect(0, 216, 320, 24, tft.color565(15, 23, 42));
    tft.drawFastHLine(0, 216, 320, tft.color565(51, 65, 85));
    tft.drawFastVLine(64, 218, 20, tft.color565(51, 65, 85));
  }

  void _updateTheme0CustomStatic(bool forceRedraw = false) {
    uint16_t cWb = tft.color565(15, 23, 42);

    if (forceRedraw || _clockHour != _lastDrawnHour || _clockMin != _lastDrawnMin) {
      _lastDrawnHour = _clockHour;
      _lastDrawnMin = _clockMin;
      char tBuf[16];
      snprintf(tBuf, sizeof(tBuf), "%02d:%02d", _clockHour, _clockMin);
      tft.fillRect(8, 219, 52, 18, cWb);
      tft.setTextColor(TFT_WHITE, cWb);
      tft.drawString(tBuf, 10, 220, 2);
    }

    // Phần nhạc kéo dài từ x: 70 đến 314 (rộng 244px), xóa bỏ hoàn toàn phần thông báo trên waybar
    const char* sTitle = (_navData.songTitle[0] != '\0') ? _navData.songTitle : "Nhac tat";
    _drawSongTitle(sTitle, 70, 220, 244, 16, tft.color565(254, 240, 138), cWb, forceRedraw);
  }

  // --- GIAO DIỆN 1: SUNFLOWER BENTO ---
  void _drawTheme1SunflowerContent(bool isRedraw) {
    if (isRedraw) {
      // 1. Clock (HH:mm - không hiện giây)
      char timeBuf[16];
      snprintf(timeBuf, sizeof(timeBuf), "%02d:%02d", _clockHour, _clockMin);
      tft.setTextColor(tft.color565(250, 204, 21)); // vàng tươi trong suốt
      tft.drawString(timeBuf, 20, 24, 6);

      // 2. Date
      char dateBuf[48];
      snprintf(dateBuf, sizeof(dateBuf), "%s, %02d/%02d", _getDayOfWeekString(_clockDayOfWeek), _clockDay, _clockMonth);
      for (int i = 0; dateBuf[i]; i++) dateBuf[i] = toupper((unsigned char)dateBuf[i]);
      _drawUtf8StringTransparent(dateBuf, 22, 70, TFT_WHITE);

      // 3. Music Duration (chỉ vẽ khi durationSec > 0)
      if (_navData.songDurationSec > 0) {
        char elBuf[16], durBuf[16];
        snprintf(elBuf, sizeof(elBuf), "%02d:%02d", _navData.songElapsedSec / 60, _navData.songElapsedSec % 60);
        snprintf(durBuf, sizeof(durBuf), "%02d:%02d", _navData.songDurationSec / 60, _navData.songDurationSec % 60);
        tft.setTextColor(tft.color565(251, 146, 60));
        tft.drawString(elBuf, 262, 201, 1);
        tft.setTextColor(TFT_WHITE);
        tft.drawString(durBuf, 262, 211, 1);
      }

      // 4. Notification: Người gửi cố định (vàng), nội dung xuống dòng hết ô không trôi
      if (_notifShown && _notif.title[0] != '\0') {
        _drawTruncatedUtf8StringTransparent(_notif.title, 184, 50, 110, tft.color565(250, 204, 21));
        if (_notif.message[0] != '\0') {
          _drawWrappedUtf8StringTransparent(_notif.message, 184, 68, 110, 4, TFT_WHITE, 15);
        }
      }
    }

    // 5. Song Title (nhỏ lại 2px, dời xuống 3px: y=201, thả trôi nếu dài hơn 175px)
    if (_navData.songTitle[0] != '\0') {
      _drawSongTitle(_navData.songTitle, 60, 201, 175, 16, tft.color565(254, 240, 138), tft.color565(37, 27, 18), isRedraw);
    }
  }

  // --- GIAO DIỆN 2: CYBERPUNK NEON HUD ---
  void _drawTheme2CyberpunkContent(bool isRedraw) {
    if (isRedraw) {
      // 1. Clock (HH:mm - phóng to theo ảnh nền zoom)
      char timeBuf[16];
      snprintf(timeBuf, sizeof(timeBuf), "%02d:%02d", _clockHour, _clockMin);
      tft.setTextColor(tft.color565(0, 240, 255)); // cyan neon trong suốt
      tft.drawString(timeBuf, 14, 38, 7);

      // 2. Date
      char dateBuf[32];
      snprintf(dateBuf, sizeof(dateBuf), "T%d, %02d.%02d.%04d",
               _clockDayOfWeek == 7 ? 0 : _clockDayOfWeek + 1, _clockDay, _clockMonth, _clockYear);
      _drawUtf8StringTransparent(dateBuf, 16, 116, tft.color565(103, 232, 249));

      // 3. Music Duration (chỉ hiện khi durationSec > 0)
      if (_navData.songDurationSec > 0) {
        char ratioBuf[32];
        snprintf(ratioBuf, sizeof(ratioBuf), "%02d:%02d / %02d:%02d",
                 _navData.songElapsedSec / 60, _navData.songElapsedSec % 60,
                 _navData.songDurationSec / 60, _navData.songDurationSec % 60);
        tft.setTextColor(tft.color565(251, 146, 60));
        tft.drawString(ratioBuf, 240, 188, 1);
      }

      // 4. Notification: Người gửi cố định (hồng neon), nội dung xuống dòng hết ô không trôi
      if (_notifShown && _notif.title[0] != '\0') {
        _drawTruncatedUtf8StringTransparent(_notif.title, 218, 50, 86, tft.color565(255, 0, 127));
        if (_notif.message[0] != '\0') {
          _drawWrappedUtf8StringTransparent(_notif.message, 218, 68, 86, 4, TFT_WHITE, 15);
        }
      }
    }

    // 5. Song Title (thanh nhạc đáy: x: 52, y: 188, w: 180, thả trôi)
    if (_navData.songTitle[0] != '\0') {
      _drawSongTitle(_navData.songTitle, 52, 188, 180, 16, tft.color565(103, 232, 249), tft.color565(13, 13, 41), isRedraw);
    }
  }

  // --- GIAO DIỆN 3: RETRO MACINTOSH PIXEL OS ---
  void _drawTheme3RetroMacContent(bool isRedraw) {
    if (isRedraw) {
      // 1. Clock (HH:mm - căn giữa chuẩn trong cửa sổ đồng hồ x: 9..144)
      char timeBuf[16];
      snprintf(timeBuf, sizeof(timeBuf), "%02d:%02d", _clockHour, _clockMin);
      tft.setTextColor(TFT_BLACK); // đen trong suốt, không đè hộp trắng
      tft.drawCentreString(timeBuf, 76, 38, 6);

      // 2. Date (căn giữa)
      char dBuf[32];
      snprintf(dBuf, sizeof(dBuf), "%02d/%02d/%04d", _clockDay, _clockMonth, _clockYear);
      _drawCentreUtf8StringTransparent(dBuf, 76, 82, TFT_BLACK);

      // 3. Music Duration (chỉ hiện khi durationSec > 0)
      if (_navData.songDurationSec > 0) {
        char elBuf[16];
        snprintf(elBuf, sizeof(elBuf), "%02d:%02d", _navData.songElapsedSec / 60, _navData.songElapsedSec % 60);
        tft.setTextColor(TFT_BLACK);
        tft.drawString(elBuf, 228, 151, 1);
      }

      // 4. Notification: "From: Người gửi" ngang hàng với hộp thư (hộp thư x: 14..36, y: 155..170).
      //    Tên người gửi cố định không trôi. Nội dung tin nhắn xuống dòng đến hết ô (x: 16, y: 174, w: 124, 3 lines) không trôi.
      if (_notifShown && _notif.title[0] != '\0') {
        char fromBuf[48];
        snprintf(fromBuf, sizeof(fromBuf), "From: %s", _notif.title);
        _drawTruncatedUtf8StringTransparent(fromBuf, 42, 155, 98, TFT_BLACK);
        if (_notif.message[0] != '\0') {
          _drawWrappedUtf8StringTransparent(_notif.message, 16, 174, 124, 3, TFT_BLACK, 15);
        }
      }
    }

    // 5. Song Title (thả trôi nếu dài hơn 110px, trong khung đen x: 176, y: 63, w: 112, h: 14)
    if (_navData.songTitle[0] != '\0') {
      _drawSongTitle(_navData.songTitle, 176, 63, 112, 14, TFT_WHITE, TFT_BLACK, isRedraw);
    }
  }

  // --- GIAO DIỆN 4: 80s SYNTHWAVE CASSETTE ---
  void _drawTheme4CassetteContent(bool isRedraw) {
    if (isRedraw) {
      // 1. Clock (HH:mm - không hiện giây)
      char timeBuf[16];
      snprintf(timeBuf, sizeof(timeBuf), "%02d:%02d", _clockHour, _clockMin);
      tft.setTextColor(TFT_WHITE);
      tft.drawCentreString(timeBuf, 80, 28, 6);

      // 2. Date
      char dateBuf[48];
      snprintf(dateBuf, sizeof(dateBuf), "T%d, %02d TH%02d %04d",
               _clockDayOfWeek == 7 ? 0 : _clockDayOfWeek + 1, _clockDay, _clockMonth, _clockYear);
      _drawCentreUtf8StringTransparent(dateBuf, 80, 84, tft.color565(34, 211, 238));

      // 3. Music Duration (chỉ hiện khi durationSec > 0)
      if (_navData.songDurationSec > 0) {
        char elBuf[16], durBuf[16];
        snprintf(elBuf, sizeof(elBuf), "%02d:%02d", _navData.songElapsedSec / 60, _navData.songElapsedSec % 60);
        snprintf(durBuf, sizeof(durBuf), "%02d:%02d", _navData.songDurationSec / 60, _navData.songDurationSec % 60);
        tft.setTextColor(tft.color565(34, 211, 238));
        tft.drawString(elBuf, 172, 196, 2);
        tft.drawRightString(durBuf, 308, 196, 2);
      }

      // 4. Notification: Người gửi cố định, nội dung xuống dòng hết ô không cần trôi
      if (_notifShown && _notif.title[0] != '\0') {
        _drawTruncatedUtf8StringTransparent(_notif.title, 22, 142, 120, tft.color565(251, 146, 60));
        if (_notif.message[0] != '\0') {
          _drawWrappedUtf8StringTransparent(_notif.message, 22, 158, 120, 3, tft.color565(165, 243, 252), 15);
        }
      }
    }

    // 5. Cuộn băng Cassette: Tên bài hát in hoa trên dải nhãn trên (thả trôi nếu dài hơn 120px)
    if (_navData.songTitle[0] != '\0') {
      char upperSong[64];
      strncpy(upperSong, _navData.songTitle, sizeof(upperSong) - 1);
      upperSong[sizeof(upperSong) - 1] = '\0';
      for (int i = 0; upperSong[i]; i++) upperSong[i] = toupper((unsigned char)upperSong[i]);
      _drawSongTitle(upperSong, 175, 58, 120, 16, TFT_WHITE, tft.color565(47, 10, 62), isRedraw);
    }
  }

  // --- GIAO DIỆN 5: POP-ART COMIC STRIP ---
  void _drawTheme5ComicContent(bool isRedraw) {
    if (isRedraw) {
      // 1. Clock (HH:mm - không hiện giây)
      char timeBuf[16];
      snprintf(timeBuf, sizeof(timeBuf), "%02d:%02d", _clockHour, _clockMin);
      tft.setTextColor(TFT_BLACK); // đen trong suốt
      tft.drawString(timeBuf, 24, 20, 6);

      // 2. Date
      char dateRib[32];
      snprintf(dateRib, sizeof(dateRib), "T%d, %02d THANG %02d",
               _clockDayOfWeek == 7 ? 0 : _clockDayOfWeek + 1, _clockDay, _clockMonth);
      _drawCentreUtf8StringTransparent(dateRib, 89, 83, TFT_BLACK);

      // 3. Music Duration (chỉ hiện khi durationSec > 0)
      if (_navData.songDurationSec > 0) {
        char elBuf[16], durBuf[16];
        snprintf(elBuf, sizeof(elBuf), "%02d:%02d", _navData.songElapsedSec / 60, _navData.songElapsedSec % 60);
        snprintf(durBuf, sizeof(durBuf), "%02d:%02d", _navData.songDurationSec / 60, _navData.songDurationSec % 60);
        tft.setTextColor(TFT_BLACK);
        tft.drawString(elBuf, 184, 212, 2);
        tft.drawRightString(durBuf, 306, 212, 2);
      }

      // Vẽ khung badge bài hát màu vàng viền đen phong cách Comic
      tft.fillRoundRect(184, 16, 124, 24, 4, tft.color565(250, 204, 21));
      tft.drawRoundRect(184, 16, 124, 24, 4, TFT_BLACK);

      // 4. Notification trong bóng thoại: Người gửi cố định, nội dung xuống dòng hết ô không trôi
      if (_notifShown && _notif.title[0] != '\0') {
        _drawTruncatedUtf8StringTransparent(_notif.title, 32, 142, 120, tft.color565(234, 88, 12));
        if (_notif.message[0] != '\0') {
          _drawWrappedUtf8StringTransparent(_notif.message, 32, 160, 120, 3, TFT_BLACK, 15);
        }
      }
    }

    // 5. Song Title: chữ đen nổi bật trên badge vàng Comic, thả trôi không bao giờ tràn
    if (_navData.songTitle[0] != '\0') {
      _drawSongTitle(_navData.songTitle, 188, 20, 116, 16, TFT_BLACK, tft.color565(250, 204, 21), isRedraw);
    }
  }

  // --- GIAO DIỆN 250: DYNAMIC ZIP CUSTOM THEME (/custom_theme_bg.jpg + /custom_theme.json) ---
  void _drawTheme250CustomContent(bool isRedraw) {
    if (isRedraw) {
      for (uint8_t i = 0; i < _customTheme.boxCount; i++) {
        const CustomThemeBox& b = _customTheme.boxes[i];
        if (b.w <= 0 || b.h <= 0) continue;
        if (b.hasFill) {
          if (b.r > 0) tft.fillRoundRect(b.x, b.y, b.w, b.h, b.r, b.fill);
          else tft.fillRect(b.x, b.y, b.w, b.h, b.fill);
        }
        if (b.hasBorder) {
          if (b.r > 0) tft.drawRoundRect(b.x, b.y, b.w, b.h, b.r, b.border);
          else tft.drawRect(b.x, b.y, b.w, b.h, b.border);
        }
      }

      for (uint8_t i = 0; i < _customTheme.labelCount; i++) {
        const CustomThemeLabel& l = _customTheme.labels[i];
        if (!l.visible || l.text[0] == '\0') continue;
        if (l.center) _drawCentreUtf8StringTransparent(l.text, l.x, l.y, l.color);
        else _drawTruncatedUtf8StringTransparent(l.text, l.x, l.y, l.maxW, l.color);
      }

      if (_customTheme.clockVisible) {
        char timeBuf[16];
        snprintf(timeBuf, sizeof(timeBuf), "%02d:%02d", _clockHour, _clockMin);
        tft.setTextColor(_customTheme.clockColor);
        if (_customTheme.clockCenter) {
          tft.drawCentreString(timeBuf, _customTheme.clockX, _customTheme.clockY, _customTheme.clockFont);
        } else {
          tft.drawString(timeBuf, _customTheme.clockX, _customTheme.clockY, _customTheme.clockFont);
        }
      }

      if (_customTheme.dateVisible) {
        char dateBuf[48];
        if (strcmp(_customTheme.dateFormat, "dmy_dot") == 0) {
          snprintf(dateBuf, sizeof(dateBuf), "T%d, %02d.%02d.%04d",
                   _clockDayOfWeek == 7 ? 0 : _clockDayOfWeek + 1, _clockDay, _clockMonth, _clockYear);
        } else if (strcmp(_customTheme.dateFormat, "dmy_slash") == 0) {
          snprintf(dateBuf, sizeof(dateBuf), "%02d/%02d/%04d", _clockDay, _clockMonth, _clockYear);
        } else if (strcmp(_customTheme.dateFormat, "en_upper") == 0) {
          const char* enDays[] = {"SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"};
          const char* enMonths[] = {"JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"};
          int di = (_clockDayOfWeek == 7) ? 0 : (_clockDayOfWeek % 7);
          int mi = constrain((int)_clockMonth - 1, 0, 11);
          snprintf(dateBuf, sizeof(dateBuf), "%s %s %02d", enDays[di], enMonths[mi], _clockDay);
        } else {
          snprintf(dateBuf, sizeof(dateBuf), "%s, %02d/%02d", _getDayOfWeekString(_clockDayOfWeek), _clockDay, _clockMonth);
          for (int i = 0; dateBuf[i]; i++) dateBuf[i] = toupper((unsigned char)dateBuf[i]);
        }
        if (_customTheme.dateCenter) _drawCentreUtf8StringTransparent(dateBuf, _customTheme.dateX, _customTheme.dateY, _customTheme.dateColor);
        else _drawUtf8StringTransparent(dateBuf, _customTheme.dateX, _customTheme.dateY, _customTheme.dateColor);
      }

      if (_customTheme.durVisible && _navData.songDurationSec > 0) {
        char elBuf[16], durBuf[24];
        snprintf(elBuf, sizeof(elBuf), "%02d:%02d", _navData.songElapsedSec / 60, _navData.songElapsedSec % 60);
        snprintf(durBuf, sizeof(durBuf), "%02d:%02d", _navData.songDurationSec / 60, _navData.songDurationSec % 60);
        if (strcmp(_customTheme.durMode, "split") == 0) {
          tft.setTextColor(_customTheme.durColor);
          tft.drawString(elBuf, _customTheme.durX, _customTheme.durY, 1);
          tft.setTextColor(_customTheme.durSecondary);
          tft.drawString(durBuf, _customTheme.durX, _customTheme.durY + 10, 1);
        } else if (strcmp(_customTheme.durMode, "elapsed") == 0) {
          tft.setTextColor(_customTheme.durColor);
          tft.drawString(elBuf, _customTheme.durX, _customTheme.durY, 1);
        } else {
          char ratioBuf[32];
          snprintf(ratioBuf, sizeof(ratioBuf), "%s / %s", elBuf, durBuf);
          tft.setTextColor(_customTheme.durColor);
          tft.drawString(ratioBuf, _customTheme.durX, _customTheme.durY, 1);
        }
      }

      if (_notifShown && _notif.title[0] != '\0') {
        if (_customTheme.notifTitleVisible) {
          _drawTruncatedUtf8StringTransparent(_notif.title, _customTheme.notifTitleX, _customTheme.notifTitleY, _customTheme.notifTitleW, _customTheme.notifTitleColor);
        }
        if (_customTheme.notifMsgVisible && _notif.message[0] != '\0') {
          _drawWrappedUtf8StringTransparent(_notif.message, _customTheme.notifMsgX, _customTheme.notifMsgY, _customTheme.notifMsgW, _customTheme.notifMsgLines, _customTheme.notifMsgColor, _customTheme.notifMsgLineH);
        }
      }
    }

    if (_customTheme.songVisible && !_customTheme.showWaybar && _navData.songTitle[0] != '\0') {
      _drawSongTitle(_navData.songTitle, _customTheme.songX, _customTheme.songY, _customTheme.songW, 16, _customTheme.songColor, _customTheme.songBgColor, isRedraw);
    }
  }

  void _renderStandbyWatchface() {
    if (_watchfaceStyle == 250) {
      if (_customThemeDirty || !_customThemeLoaded) {
        _loadCustomThemeSpec();
      }
      bool minuteChanged = (_clockHour != _lastDrawnHour || _clockMin != _lastDrawnMin);
      bool songChanged = (strcmp(_navData.songTitle, _lastDrawnSong) != 0);
      bool needsFullThemeRedraw = _needFullRedraw || minuteChanged || _notifDirty || songChanged;

      if (needsFullThemeRedraw) {
        _lastState = _currentState;
        _lastWatchfaceStyle = _watchfaceStyle;
        _lastDrawnHour = _clockHour;
        _lastDrawnMin = _clockMin;
        _lastDrawnDay = _clockDay;
        _needFullRedraw = false;
        _notifDirty = false;
        strncpy(_lastDrawnSong, _navData.songTitle, sizeof(_lastDrawnSong) - 1);

        tft.fillScreen(_customTheme.bgColor);
        if (SPIFFS.exists("/custom_theme_bg.jpg")) {
          File f = SPIFFS.open("/custom_theme_bg.jpg", "r");
          if (f) {
            size_t fSize = f.size();
            f.close();
            if (fSize > 200) {
              TJpgDec.drawFsJpg(0, 0, "/custom_theme_bg.jpg");
            }
          }
        }
        _drawTheme250CustomContent(true);
        if (_customTheme.showWaybar) {
          _drawTheme0WaybarStatic();
          _updateTheme0CustomStatic(true);
        }
      } else {
        _drawTheme250CustomContent(false);
        if (_customTheme.showWaybar) {
          _updateTheme0CustomStatic(false);
        }
      }
      return;
    }

    if (_watchfaceStyle == 0) {
      bool needRedraw = _needFullRedraw;
      if (_needFullRedraw) {
        _lastState = _currentState;
        _lastWatchfaceStyle = _watchfaceStyle;
        _needFullRedraw = false;
        tft.fillScreen(TFT_BLACK);
        if (SPIFFS.exists("/bg_wait.jpg")) {
          File f = SPIFFS.open("/bg_wait.jpg", "r");
          if (f) {
            size_t fSize = f.size();
            f.close();
            if (fSize > 500) {
              TJpgDec.drawFsJpg(0, 0, "/bg_wait.jpg");
            }
          }
        } else {
          _drawDefaultWallpaper();
        }
        _drawTheme0WaybarStatic();
      }
      _updateTheme0CustomStatic(needRedraw);
      return;
    }

    // Themes 1..5: Vẽ nền ảnh sạch 2D, tách hoàn toàn màu nền (trong suốt 100%)
    bool minuteChanged = (_clockHour != _lastDrawnHour || _clockMin != _lastDrawnMin);
    bool songChanged = (strcmp(_navData.songTitle, _lastDrawnSong) != 0);
    bool needsFullThemeRedraw = _needFullRedraw || minuteChanged || _notifDirty || songChanged;

    if (needsFullThemeRedraw) {
      _lastState = _currentState;
      _lastWatchfaceStyle = _watchfaceStyle;
      _lastDrawnHour = _clockHour;
      _lastDrawnMin = _clockMin;
      _lastDrawnDay = _clockDay;
      _needFullRedraw = false;
      _notifDirty = false;
      strncpy(_lastDrawnSong, _navData.songTitle, sizeof(_lastDrawnSong) - 1);

      switch (_watchfaceStyle) {
        case 1: TJpgDec.drawJpg(0, 0, THEME_1_BG_JPG, THEME_1_BG_LEN); break;
        case 2: TJpgDec.drawJpg(0, 0, THEME_2_BG_JPG, THEME_2_BG_LEN); break;
        case 3: TJpgDec.drawJpg(0, 0, THEME_3_BG_JPG, THEME_3_BG_LEN); break;
        case 4: TJpgDec.drawJpg(0, 0, THEME_4_BG_JPG, THEME_4_BG_LEN); break;
        case 5: TJpgDec.drawJpg(0, 0, THEME_5_BG_JPG, THEME_5_BG_LEN); break;
        default: TJpgDec.drawJpg(0, 0, THEME_1_BG_JPG, THEME_1_BG_LEN); break;
      }

      switch (_watchfaceStyle) {
        case 1: _drawTheme1SunflowerContent(true); break;
        case 2: _drawTheme2CyberpunkContent(true); break;
        case 3: _drawTheme3RetroMacContent(true); break;
        case 4: _drawTheme4CassetteContent(true); break;
        case 5: _drawTheme5ComicContent(true); break;
        default: _drawTheme1SunflowerContent(true); break;
      }
    } else {
      switch (_watchfaceStyle) {
        case 1: _drawTheme1SunflowerContent(false); break;
        case 2: _drawTheme2CyberpunkContent(false); break;
        case 3: _drawTheme3RetroMacContent(false); break;
        case 4: _drawTheme4CassetteContent(false); break;
        case 5: _drawTheme5ComicContent(false); break;
      }
    }
  }

  // =========================================================================
  // MÀN 2: APP IDLE MAP (No Waybar, Minimap Left + Media & Clock Right, Flicker-Free)
  // =========================================================================
  void _renderAppIdleMap() {
    Man2Layout l = _activeMan2Layout();
    bool musicRedraw = false;
    int cardCenterX = l.cardX + l.cardW / 2;

    if (_needFullRedraw) {
      tft.fillScreen(l.screenBg);
      if (l.hasBgJpg && SPIFFS.exists("/custom_man2_bg.jpg")) {
        File f = SPIFFS.open("/custom_man2_bg.jpg", "r");
        if (f) {
          size_t fSize = f.size();
          f.close();
          if (fSize > 200) {
            TJpgDec.drawFsJpg(0, 0, "/custom_man2_bg.jpg");
          }
        }
      }
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

      _renderStandbyVectorMapAt(l.mapX, l.mapY, l.mapW, l.mapH, l.mapR, l.mapBorder, l.musicBg);

      if (l.drawPanelCard && l.cardW > 0) {
        tft.fillRoundRect(l.cardX, l.cardY, l.cardW, l.cardH, l.cardR, l.cardBg);
        tft.drawRoundRect(l.cardX, l.cardY, l.cardW, l.cardH, l.cardR, l.cardBorder);
      }

      if (l.songVisible) {
        tft.fillRoundRect(l.musicX, l.musicY, l.musicW, l.musicH, 8, l.musicBg);
        tft.drawRoundRect(l.musicX, l.musicY, l.musicW, l.musicH, 8, l.musicBorder);
      }

      if (l.notifVisible) {
        _drawNotifBoxAt(l.notifX, l.notifY, l.notifW, l.notifH, l.notifBg, l.notifBorder, l.notifTitleColor, l.notifMsgColor);
      }
    }

    if (l.clockVisible && (_clockHour != _lastDrawnHour || _clockMin != _lastDrawnMin)) {
      _lastDrawnHour = _clockHour;
      _lastDrawnMin = _clockMin;
      if (l.clockFont == 7) {
        tft.fillRect(l.cardX + 4, l.clockY - 2, l.cardW - 8, 34, l.cardBg);
      }
      tft.setTextPadding(l.cardW - 14);
      tft.setTextColor(l.clockColor, l.cardBg);
      tft.drawCentreString(_navData.currentTime, l.clockX, l.clockY, l.clockFont == 7 ? 4 : l.clockFont);
      tft.setTextPadding(0);
    }

    if (l.dateVisible && _clockDay != _lastDrawnDay) {
      _lastDrawnDay = _clockDay;
      tft.fillRect(l.cardX + 2, l.dateY - 2, l.cardW - 4, 24, l.cardBg);
      char dateStr[32];
      snprintf(dateStr, sizeof(dateStr), "%s, %02d/%02d", _getDayOfWeekString(_clockDayOfWeek), _clockDay, _clockMonth);
      _drawCentreUtf8String(dateStr, l.dateX, l.dateY, l.dateColor, l.cardBg);
      tft.drawFastHLine(l.divX, l.divY, l.divW, l.cardBorder);
    }

    // Music: "Tên bài • Tác giả" thả trôi trên 1 dòng + thời gian phát
    bool hasSong = (strlen(_navData.songTitle) > 0 && strcmp(_navData.songTitle, "CHUA PHAT NHAC") != 0);
    bool songChanged = (strcmp(_navData.songTitle, _lastDrawnSong) != 0);
    if (l.songVisible) {
      int musicCx = l.musicX + l.musicW / 2;
      if (songChanged) {
        strncpy(_lastDrawnSong, _navData.songTitle, sizeof(_lastDrawnSong) - 1);
        _lastDrawnSong[sizeof(_lastDrawnSong) - 1] = '\0';
        musicRedraw = true;
        tft.fillRect(l.musicX + 2, l.musicY + 2, l.musicW - 4, l.musicH - 4, l.musicBg);
        _mqIdle.text[0] = '\0';
        _lastIdleElapsed = 0xFFFF;
        if (!hasSong) {
          _drawCentreUtf8String("Chưa phát nhạc", musicCx, l.musicY + 12, tft.color565(100, 116, 139), l.musicBg);
        }
      }
      if (hasSong) {
        char full[100];
        if (_navData.songArtist[0] != '\0') snprintf(full, sizeof(full), "%s • %s", _navData.songTitle, _navData.songArtist);
        else snprintf(full, sizeof(full), "%s", _navData.songTitle);
        _marquee(_mqIdle, marqueeSpr, u8f_marquee, l.musicX + 3, l.musicY + 2, full, l.musicColor, l.musicBg, musicRedraw);

        uint16_t elKey = (_navData.songElapsedSec > 0 || _navData.songDurationSec > 0) ? _navData.songElapsedSec : 0xFFFE;
        if (_lastIdleElapsed != elKey) {
          _lastIdleElapsed = elKey;
          tft.fillRect(l.musicX + 2, l.musicY + 22, l.musicW - 4, 16, l.musicBg);
          if (elKey != 0xFFFE) {
            char timeStr[32];
            int elM = _navData.songElapsedSec / 60, elS = _navData.songElapsedSec % 60;
            if (_navData.songDurationSec > 0) {
              snprintf(timeStr, sizeof(timeStr), "%02d:%02d / %02d:%02d", elM, elS,
                       _navData.songDurationSec / 60, _navData.songDurationSec % 60);
            } else {
              snprintf(timeStr, sizeof(timeStr), "%02d:%02d", elM, elS);
            }
            _drawCentreUtf8String(timeStr, musicCx, l.musicY + 22, l.durColor, l.musicBg);
          }
        }
      }
    }

    // Notification box
    if (_notifShown && _notif.isCall && millis() > _notifExpire) {
      _notifShown = false;
      _notifDirty = true;
    }
    if (l.notifVisible && _notifDirty) {
      _notifDirty = false;
      _drawNotifBoxAt(l.notifX, l.notifY, l.notifW, l.notifH, l.notifBg, l.notifBorder, l.notifTitleColor, l.notifMsgColor);
    }
    (void)cardCenterX;
  }

  void _renderStandbyVectorMapAt(int16_t mx, int16_t my, int16_t mw, int16_t mh, int16_t br, uint16_t borderCol, uint16_t cMapBg) {
    uint16_t cRadarRing   = tft.color565(20, 32, 48);
    uint16_t cAsphaltBed  = tft.color565(28, 38, 54);
    uint16_t cRoadBorder  = tft.color565(55, 75, 100);
    uint16_t cRouteActive = borderCol;

    tft.drawRoundRect(mx - 2, my - 2, mw + 4, mh + 4, br, borderCol);
    tft.setViewport(mx, my, mw, mh, false);
    tft.fillRect(0, 0, mw, mh, cMapBg);

    const int cx = mw / 2;
    const int cy = mh / 2;

    tft.drawCircle(cx, cy, 42, cRadarRing);
    tft.drawCircle(cx, cy, 80, cRadarRing);

    _drawThickLine(cx, mh - 4, cx, 4, cRoadBorder, 14);
    _drawThickLine(cx, mh - 4, cx, 4, cAsphaltBed, 10);

    _drawThickLine(4, cy, mw - 4, cy, cRoadBorder, 14);
    _drawThickLine(4, cy, mw - 4, cy, cAsphaltBed, 10);

    tft.drawCircle(cx, cy, 12, tft.color565(0, 50, 80));
    tft.fillCircle(cx, cy, 7, cRouteActive);
    tft.drawCircle(cx, cy, 7, TFT_WHITE);
    tft.fillTriangle(cx, cy - 9, cx - 4, cy - 2, cx + 4, cy - 2, TFT_WHITE);

    tft.setTextColor(borderCol, cMapBg);
    tft.drawString("N", 6, 6, 2);
    tft.fillTriangle(20, 7, 17, 15, 23, 15, borderCol);
    tft.fillCircle(mw - 10, 10, 3, TFT_GREEN);
    tft.resetViewport();
  }

  void _renderStandbyVectorMap() {
    Man2Layout l = _activeMan2Layout();
    _renderStandbyVectorMapAt(l.mapX, l.mapY, l.mapW, l.mapH, l.mapR, l.mapBorder, l.musicBg);
  }

  void _drawManeuverArrow(int x, int y, uint8_t turnCode) {
    tft.fillRoundRect(x, y, 52, 52, 10, tft.color565(14, 20, 30));
    tft.drawRoundRect(x, y, 52, 52, 10, TFT_CYAN);

    int cx = x + 26;
    int cy = y + 26;

    if (turnCode == 5 || turnCode == 6 || turnCode == 7) {
      // TURN LEFT
      tft.fillRect(cx + 6, cy - 6, 5, 20, TFT_CYAN);
      tft.fillRect(cx - 12, cy - 6, 20, 5, TFT_CYAN);
      tft.fillTriangle(cx - 16, cy - 4, cx - 8, cy - 12, cx - 8, cy + 4, TFT_CYAN);
    }
    else if (turnCode == 1 || turnCode == 2 || turnCode == 3) {
      // TURN RIGHT
      tft.fillRect(cx - 11, cy - 6, 5, 20, TFT_CYAN);
      tft.fillRect(cx - 8, cy - 6, 20, 5, TFT_CYAN);
      tft.fillTriangle(cx + 16, cy - 4, cx + 8, cy - 12, cx + 8, cy + 4, TFT_CYAN);
    }
    else if (turnCode == 4) {
      // U-TURN
      tft.fillRect(cx + 6, cy - 4, 4, 18, TFT_CYAN);
      tft.fillRect(cx - 10, cy - 8, 18, 4, TFT_CYAN);
      tft.fillRect(cx - 10, cy - 4, 4, 18, TFT_CYAN);
      tft.fillTriangle(cx - 8, cy + 16, cx - 14, cy + 8, cx - 2, cy + 8, TFT_CYAN);
    }
    else if (turnCode == 8) {
      // ROUNDABOUT
      tft.drawCircle(cx, cy, 12, TFT_CYAN);
      tft.drawCircle(cx, cy, 11, TFT_CYAN);
      tft.fillTriangle(cx + 8, cy - 12, cx + 15, cy - 7, cx + 8, cy - 2, TFT_CYAN);
    }
    else if (turnCode == 9) {
      // ARRIVED / DESTINATION FLAG
      tft.fillRect(cx - 8, cy - 12, 3, 24, TFT_WHITE);
      tft.fillTriangle(cx - 5, cy - 12, cx + 12, cy - 6, cx - 5, cy, TFT_CYAN);
    }
    else {
      // STRAIGHT
      tft.fillRect(cx - 2, cy - 6, 5, 20, TFT_CYAN);
      tft.fillTriangle(cx, cy - 14, cx - 10, cy - 5, cx + 10, cy - 5, TFT_CYAN);
    }
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

      // Draw vector radar/road grid in left map box
      const int cx = 78;
      const int cy = 152;
      uint16_t cRadarRing = tft.color565(20, 32, 48);
      tft.drawCircle(cx, cy, 38, cRadarRing);
      tft.drawCircle(cx, cy, 68, cRadarRing);
      _drawThickLine(cx, 226, cx, 36, tft.color565(28, 38, 54), 10);
      _drawThickLine(10, cy, 146, cy, tft.color565(28, 38, 54), 10);

      // Vehicle Puck
      tft.drawCircle(cx, cy, 10, tft.color565(0, 50, 80));
      tft.fillCircle(cx, cy, 6, TFT_CYAN);
      tft.drawCircle(cx, cy, 6, TFT_WHITE);
      tft.fillTriangle(cx, cy - 8, cx - 4, cy - 1, cx + 4, cy - 1, TFT_WHITE);

      // Draw Maneuver Arrow
      _drawManeuverArrow(52, 44, _navData.turnCode);
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
      tft.setTextPadding(36);
      tft.drawRightString(batStr, 290, 4, 2);
      tft.setTextPadding(0);
      tft.drawRect(294, 6, 20, 11, cBat);
      tft.fillRect(314, 9, 2, 5, cBat);
      tft.fillRect(296, 8, 16, 7, cBarBg);
      int fillW = constrain((_navData.batteryLevel * 16) / 100, 0, 16);
      if (fillW > 0) tft.fillRect(296, 8, fillW, 7, cBat);
    }

    bool hasSong = (_navData.songTitle[0] != '\0' && strcmp(_navData.songTitle, "CHUA PHAT NHAC") != 0);
    if (hasSong) {
      char full[128];
      int elM = _navData.songElapsedSec / 60;
      int elS = _navData.songElapsedSec % 60;
      bool hasElapsed = (_navData.songElapsedSec > 0 || _navData.songDurationSec > 0);

      if (_navData.songArtist[0] != '\0') {
        if (hasElapsed) {
          snprintf(full, sizeof(full), "%s • %s [%02d:%02d]", _navData.songTitle, _navData.songArtist, elM, elS);
        } else {
          snprintf(full, sizeof(full), "%s • %s", _navData.songTitle, _navData.songArtist);
        }
      } else {
        if (hasElapsed) {
          snprintf(full, sizeof(full), "%s [%02d:%02d]", _navData.songTitle, elM, elS);
        } else {
          snprintf(full, sizeof(full), "%s", _navData.songTitle);
        }
      }
      _marquee(_mqBar, _wbSpr, _wbU8, 52, 0, full, tft.color565(250, 204, 21), cBarBg, false);
    } else if (_lastWaybarSong[0] != '\0') {
      _lastWaybarSong[0] = '\0';
      _mqBar.text[0] = '\0';
      tft.fillRect(52, 0, 192, 24, cBarBg);
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

  // Ô thông báo (tin nhắn / cuộc gọi) theo tọa độ Màn 2 hiện tại
  void _drawNotifBox() {
    Man2Layout l = _activeMan2Layout();
    _drawNotifBoxAt(l.notifX, l.notifY, l.notifW, l.notifH, l.notifBg, l.notifBorder, l.notifTitleColor, l.notifMsgColor);
  }

  void _drawNotifBoxAt(int16_t nx, int16_t ny, int16_t nw, int16_t nh, uint16_t cPill, uint16_t defaultBorder, uint16_t titleColor, uint16_t msgColor) {
    if (_notifShown && _notif.isCall && millis() > _notifExpire) {
      _notifShown = false;
    }

    uint16_t border = defaultBorder;
    uint16_t circle = 0;
    const uint8_t* icon = icon_bell_20x20;

    if (_notifShown) {
      _notifStyle(_notif, border, circle, icon);
    }

    tft.fillRoundRect(nx, ny, nw, nh, 8, cPill);
    tft.drawRoundRect(nx, ny, nw, nh, 8, border);
    if (_notifShown && _notif.isCall) {
      tft.drawRoundRect(nx + 1, ny + 1, nw - 2, nh - 2, 7, border);
    }

    int cx = nx + nw / 2;
    if (!_notifShown) {
      tft.fillCircle(cx, ny + 31, 12, tft.color565(20, 28, 40));
      tft.drawBitmap(cx - 10, ny + 21, icon_bell_20x20, 20, 20, tft.color565(71, 85, 105));
      _drawCentreUtf8String("Chưa có thông báo", cx, ny + 61, tft.color565(71, 85, 105), cPill);
      return;
    }

    // Header: App icon + Sender/Caller Title
    tft.fillCircle(nx + 17, ny + 18, 12, circle);
    tft.drawBitmap(nx + 7, ny + 8, icon, 20, 20, TFT_WHITE);

    char titleLine[64];
    _fitUtf8(_notif.title, titleLine, sizeof(titleLine), max(40, (int)nw - 42));
    _drawUtf8String(titleLine, nx + 34, ny + 9, _notif.isCall ? TFT_GREEN : titleColor, cPill);

    tft.drawFastHLine(nx + 6, ny + 34, max(20, (int)nw - 12), tft.color565(28, 38, 52));

    // Body: Lines 1, 2, 3
    if (_notif.isCall) {
      _drawUtf8String("Cuộc gọi đến", nx + 8, ny + 39, tft.color565(148, 163, 184), cPill);
      const char* phone = (_notif.message[0] != '\0') ? _notif.message : "Đang đổ chuông...";
      char pLine[64];
      _fitUtf8(phone, pLine, sizeof(pLine), max(40, (int)nw - 14));
      _drawUtf8String(pLine, nx + 8, ny + 59, msgColor, cPill);
      _drawUtf8String("Nhấc máy trên ĐT", nx + 8, ny + 79, tft.color565(100, 116, 139), cPill);
    } else {
      _drawWrappedUtf8String(_notif.message, nx + 8, ny + 39, max(40, (int)nw - 14), 3, msgColor, cPill, 19);
    }
  }
};

#endif // DISPLAY_UI_H
