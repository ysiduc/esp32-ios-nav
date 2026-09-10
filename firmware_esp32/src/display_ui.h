#ifndef DISPLAY_UI_H
#define DISPLAY_UI_H

#include <Arduino.h>
#include "icons.h"

extern volatile unsigned long lastFrameTime;

#if defined(DISPLAY_OLED_SSD1306)
#include <U8g2lib.h>
#include <Wire.h>

#ifndef OLED_SDA_PIN
#define OLED_SDA_PIN 8
#endif
#ifndef OLED_SCL_PIN
#define OLED_SCL_PIN 9
#endif

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
  uint8_t turnCode = 6;       // Default Left Turn (matching user image)
  uint16_t distMeters = 208;  // Default 208m (matching user image)
  uint16_t totalDistMeters = 5900; // 5.9km
  uint8_t speedKmh = 0;
  uint8_t etaMinutes = 11;    // 11 ph
  char streetName[32] = "CAU SONG LU";
  char arrivalTime[8] = "12:05";
  bool isConnected = true;
  int heading = 0;
  uint8_t batteryLevel = 100;
};

struct AncsPopupData {
  char title[32] = "";
  char message[64] = "";
  uint32_t expireMillis = 0;
};

// =========================================================================
// Design Color Palette for TFT ST7789 (Exact Match to Retina HD App & Web UI)
// =========================================================================
#define COLOR_BG          0x0000 // Deep Obsidian Black
#define COLOR_CARD_BG     0x08A5 // Dark Slate Card (#0F172A)
#define COLOR_CARD_FRAME  0x2168 // Border Slate (#222F42)
#define COLOR_CARD_INNER  0x0841 // Inner Card (#0A0E14)
#define COLOR_CYAN        0x07FF // Neon Cyan (#00F0FF)
#define COLOR_CYAN_TINT   0x0946 // Dark Cyan Glow (#0A2433)
#define COLOR_GREEN       0x07E0 // Neon Green (#05FFA1)
#define COLOR_GOLD        0xFD20 // Cyber Gold (#FFB800)
#define COLOR_TEXT_MUTED  0x9CD3 // Slate Muted Text (#94A3B8)
#define COLOR_TEXT_DARK   0x63B1 // Dark Grey Muted (#64748B)

class DisplayManager {
private:
  DisplayState _currentState = STATE_NAVIGATION;
  NavStateData _navData;
  AncsPopupData _popupData;
  unsigned long _lastRightRender = 0;
  bool _wasPopupActive = false;
  bool _leftStandbyDrawn = false;

public:
  void init() {
#if defined(DISPLAY_OLED_SSD1306)
    Wire.begin(OLED_SDA_PIN, OLED_SCL_PIN);
    Wire.setClock(400000);
    u8g2.begin();
    u8g2.enableUTF8Print();
    u8g2.setFontMode(0);
#elif defined(DISPLAY_TFT_ST7789)
    tft.init();
    tft.setRotation(1);
    tft.invertDisplay(true);
    tft.fillScreen(COLOR_BG);
    _drawBaseDivider();
#endif
  }

  void setNavData(uint8_t turn, uint16_t dist, uint16_t totalDist, uint8_t speed, uint8_t eta, const char* street) {
    _navData.turnCode = turn;
    _navData.distMeters = dist;
    _navData.totalDistMeters = totalDist;
    _navData.speedKmh = speed;
    _navData.etaMinutes = eta;
    if (street && strlen(street) > 0) {
      strncpy(_navData.streetName, street, sizeof(_navData.streetName) - 1);
      _navData.streetName[sizeof(_navData.streetName) - 1] = '\0';
    }

    if (_currentState != STATE_POPUP_CALL && _currentState != STATE_POPUP_SMS) {
      _currentState = STATE_NAVIGATION;
    }
  }

  void setBleConnected(bool connected) {
    _navData.isConnected = connected;
  }

  void showCallAlert(const char* callerName) {
    strncpy(_popupData.title, callerName, sizeof(_popupData.title) - 1);
    _popupData.title[sizeof(_popupData.title) - 1] = '\0';
    _popupData.expireMillis = millis() + 8000;
    _currentState = STATE_POPUP_CALL;
  }

  void showSmsAlert(const char* sender, const char* msg) {
    strncpy(_popupData.title, sender, sizeof(_popupData.title) - 1);
    _popupData.title[sizeof(_popupData.title) - 1] = '\0';
    strncpy(_popupData.message, msg, sizeof(_popupData.message) - 1);
    _popupData.message[sizeof(_popupData.message) - 1] = '\0';
    _popupData.expireMillis = millis() + 6000;
    _currentState = STATE_POPUP_SMS;
  }

  void update() {
    if ((_currentState == STATE_POPUP_CALL || _currentState == STATE_POPUP_SMS) && millis() > _popupData.expireMillis) {
      _currentState = STATE_NAVIGATION;
    }

#if defined(DISPLAY_OLED_SSD1306)
    _renderOled();
#elif defined(DISPLAY_TFT_ST7789)
    _renderTft();
#endif
  }

private:
#if defined(DISPLAY_OLED_SSD1306)
  void _renderOled() {
    u8g2.clearBuffer();

    // -------------------------------------------------------------
    // POPUP OVERLAY: CUOC GOI DEN / TIN NHAN SMS
    // -------------------------------------------------------------
    if (_currentState == STATE_POPUP_CALL) {
      u8g2.drawRFrame(0, 0, 128, 64, 4);
      u8g2.drawXBMP(8, 6, 16, 16, icon_phone_16x16);
      u8g2.setFont(u8g2_font_6x10_tf);
      u8g2.drawStr(30, 18, "CUOC GOI DEN");
      u8g2.drawHLine(0, 24, 128);

      u8g2.setFont(u8g2_font_7x14B_tf);
      u8g2.drawStr(8, 44, _popupData.title);

      u8g2.setFont(u8g2_font_4x6_tf);
      u8g2.drawStr(8, 58, "ANCS Apple Notification");
      u8g2.sendBuffer();
      return;
    } else if (_currentState == STATE_POPUP_SMS) {
      u8g2.drawRFrame(0, 0, 128, 64, 4);
      u8g2.drawXBMP(8, 6, 16, 16, icon_msg_16x16);
      u8g2.setFont(u8g2_font_6x10_tf);
      u8g2.drawStr(30, 18, "TIN NHAN MOI");
      u8g2.drawHLine(0, 24, 128);

      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(8, 40, _popupData.title);

      u8g2.setFont(u8g2_font_4x6_tf);
      u8g2.drawStr(8, 56, _popupData.message);
      u8g2.sendBuffer();
      return;
    }

    // =============================================================
    // 1. TOP HARDWARE STATUS BAR (y: 0..9) - 100% Match to Image
    // =============================================================
    // BLE Icon & Text
    u8g2.drawXBMP(1, 1, 8, 8, icon_ble_8x8);
    u8g2.setFont(u8g2_font_4x6_tf);
    u8g2.drawStr(11, 7, "ESP32 BLE");

    // Center Clock
    u8g2.setFont(u8g2_font_4x6_tf);
    u8g2.drawStr(56, 7, "11:54");

    // Battery percentage & icon
    u8g2.drawStr(98, 7, "100%");
    u8g2.drawFrame(117, 2, 9, 5);
    u8g2.drawBox(118, 3, 7, 3);
    u8g2.drawVLine(126, 3, 3);

    // =============================================================
    // 2. LEFT 50% (x: 0..61, y: 10..63): LIVE MAP VIEWPORT
    // =============================================================
    u8g2.drawRFrame(0, 10, 62, 54, 4); // Left Map Container Frame

    // Road Grid Lines
    u8g2.drawLine(44, 11, 44, 63);     // Main road
    u8g2.drawLine(2, 28, 44, 28);      // Left street 1
    u8g2.drawLine(2, 18, 30, 18);      // Left street 2
    u8g2.drawLine(44, 46, 60, 46);     // Right side street

    // Active Navigation Route Polyline (Thick Path)
    u8g2.drawVLine(43, 11, 52);
    u8g2.drawVLine(44, 11, 52);

    // Vehicle Navigation Cursor (Centered at x: 36, y: 36)
    u8g2.drawCircle(36, 36, 6);        // Pulsing radar halo
    u8g2.drawDisc(36, 36, 3);          // Solid vehicle dot
    u8g2.setDrawColor(0);
    u8g2.drawPixel(36, 35);            // Direction tip
    u8g2.setDrawColor(1);

    // "MAP LIVE" Badge (Bottom Left)
    u8g2.drawBox(3, 53, 27, 9);
    u8g2.setDrawColor(0);
    u8g2.setFont(u8g2_font_4x6_tf);
    u8g2.drawStr(5, 60, "MAP LIVE");
    u8g2.setDrawColor(1);

    // =============================================================
    // 3. RIGHT 50% (x: 65..127, y: 10..63): NAVIGATION HUD
    // =============================================================
    u8g2.drawRFrame(64, 10, 64, 54, 4); // Right HUD Container Frame

    // Row 1: Maneuver Turn Box + Distance & Speed
    u8g2.drawRFrame(66, 12, 16, 16, 2);
    const uint8_t* icon16 = icon_straight_16x16;
    switch (_navData.turnCode) {
      case 1: case 2: case 3: icon16 = icon_turn_right_16x16; break;
      case 4: icon16 = icon_uturn_16x16; break;
      case 5: case 6: case 7: icon16 = icon_turn_left_16x16; break;
      case 8: icon16 = icon_roundabout_16x16; break;
      case 9: icon16 = icon_arrive_16x16; break;
      default: icon16 = icon_straight_16x16; break;
    }
    u8g2.drawXBMP(66, 12, 16, 16, icon16);

    // Distance Text (Large)
    u8g2.setFont(u8g2_font_7x14B_tf);
    char distStr[16];
    if (_navData.distMeters >= 1000) {
      snprintf(distStr, sizeof(distStr), "%.1fkm", (float)_navData.distMeters / 1000.0);
    } else {
      snprintf(distStr, sizeof(distStr), "%dm", _navData.distMeters);
    }
    u8g2.drawStr(85, 22, distStr);

    // Speed Text below Distance
    u8g2.setFont(u8g2_font_4x6_tf);
    char spdStr[16];
    snprintf(spdStr, sizeof(spdStr), "%d km/h", _navData.speedKmh);
    u8g2.drawStr(85, 29, spdStr);

    // Row 2: Street Name Pill (Rounded Badge)
    u8g2.drawRFrame(66, 31, 60, 11, 2);
    u8g2.setFont(u8g2_font_5x7_tf);
    char cleanStreet[18];
    strncpy(cleanStreet, _navData.streetName, sizeof(cleanStreet) - 1);
    cleanStreet[sizeof(cleanStreet) - 1] = '\0';
    u8g2.drawStr(69, 39, cleanStreet);

    // Row 3: ETA Arrival & Remaining Distance
    u8g2.setFont(u8g2_font_4x6_tf);
    u8g2.drawStr(67, 50, "DU KIEN");
    u8g2.setFont(u8g2_font_5x8_tf);
    u8g2.drawStr(67, 60, "12:05");

    u8g2.setFont(u8g2_font_4x6_tf);
    char totDistStr[16];
    snprintf(totDistStr, sizeof(totDistStr), "%.1fkm", (float)_navData.totalDistMeters / 1000.0);
    u8g2.drawStr(103, 50, totDistStr);

    u8g2.setFont(u8g2_font_5x7_tf);
    char etaMinStr[16];
    snprintf(etaMinStr, sizeof(etaMinStr), "%d ph", _navData.etaMinutes);
    u8g2.drawStr(103, 60, etaMinStr);

    u8g2.sendBuffer();
  }
#endif

#if defined(DISPLAY_TFT_ST7789)
  void _drawBaseDivider() {
    tft.drawFastVLine(159, 0, 240, COLOR_CARD_FRAME);
    tft.drawFastVLine(160, 0, 240, COLOR_CYAN);
  }

  void _renderTft() {
    if (_currentState == STATE_POPUP_CALL) {
      _wasPopupActive = true;
      tft.fillRoundRect(15, 25, 290, 190, 14, 0x01E0);
      tft.drawRoundRect(15, 25, 290, 190, 14, COLOR_GREEN);
      tft.drawRoundRect(17, 27, 286, 186, 12, COLOR_GREEN);

      tft.drawXBitmap(144, 40, icon_phone_16x16, 16, 16, COLOR_GREEN);
      tft.setTextColor(COLOR_GREEN, 0x01E0);
      tft.drawString("CUOC GOI DEN", 80, 65, 4);

      tft.setTextColor(0xFFFF, 0x01E0);
      tft.drawString(_popupData.title, 40, 110, 4);

      tft.setTextColor(COLOR_TEXT_MUTED, 0x01E0);
      tft.drawString("Ket noi tu iPhone (ANCS)", 60, 165, 2);
      return;
    } else if (_currentState == STATE_POPUP_SMS) {
      _wasPopupActive = true;
      tft.fillRoundRect(15, 25, 290, 190, 14, 0x0841);
      tft.drawRoundRect(15, 25, 290, 190, 14, COLOR_CYAN);
      tft.drawRoundRect(17, 27, 286, 186, 12, COLOR_CYAN);

      tft.drawXBitmap(144, 38, icon_msg_16x16, 16, 16, COLOR_CYAN);
      tft.setTextColor(COLOR_CYAN, 0x0841);
      tft.drawString("TIN NHAN MOI", 85, 60, 4);

      tft.setTextColor(COLOR_GOLD, 0x0841);
      tft.drawString(_popupData.title, 40, 95, 4);

      tft.fillRoundRect(25, 135, 270, 60, 8, COLOR_CARD_BG);
      tft.setTextColor(0xFFFF, COLOR_CARD_BG);
      tft.drawString(_popupData.message, 32, 150, 2);
      return;
    }

    if (_wasPopupActive) {
      _wasPopupActive = false;
      tft.fillScreen(COLOR_BG);
      _drawBaseDivider();
      _leftStandbyDrawn = false;
    }

    bool isStreamActive = (lastFrameTime > 0 && (millis() - lastFrameTime < 3500));

    if (isStreamActive) {
      _leftStandbyDrawn = false;
    } else if (!_leftStandbyDrawn || (millis() - _lastRightRender > 1500)) {
      _leftStandbyDrawn = true;
      tft.fillRect(0, 0, 159, 240, COLOR_BG);
      tft.fillRoundRect(6, 8, 147, 224, 10, COLOR_CARD_BG);
      tft.drawRoundRect(6, 8, 147, 224, 10, COLOR_CARD_FRAME);

      tft.fillRoundRect(54, 45, 52, 52, 10, COLOR_CYAN_TINT);
      tft.drawRoundRect(54, 45, 52, 52, 10, COLOR_CYAN);
      tft.drawXBitmap(64, 55, icon_straight_32x32, 32, 32, COLOR_CYAN);

      tft.setTextColor(COLOR_CYAN, COLOR_CARD_BG);
      tft.drawString("MAP STREAM", 22, 115, 4);

      tft.setTextColor(COLOR_TEXT_MUTED, COLOR_CARD_BG);
      tft.drawString("Cho stream tu App", 24, 148, 2);

      tft.fillRoundRect(20, 180, 120, 32, 6, COLOR_CARD_INNER);
      tft.drawRoundRect(20, 180, 120, 32, 6, COLOR_CARD_FRAME);
      tft.setTextColor(COLOR_GREEN, COLOR_CARD_INNER);
      tft.drawString("SAN SANG", 42, 188, 2);

      _drawBaseDivider();
    }

    if (millis() - _lastRightRender < 220) return;
    _lastRightRender = millis();

    tft.fillRect(161, 0, 159, 240, COLOR_BG);
    _drawBaseDivider();

    // A. Status Bar
    tft.fillRoundRect(164, 4, 150, 20, 4, COLOR_CARD_INNER);
    tft.fillCircle(172, 14, 3, _navData.isConnected ? COLOR_GREEN : 0xF800);
    tft.setTextColor(_navData.isConnected ? COLOR_CYAN : 0xF800, COLOR_CARD_INNER);
    tft.drawString(_navData.isConnected ? "BLE ON" : "NO BLE", 180, 8, 2);

    tft.setTextColor(COLOR_GREEN, COLOR_CARD_INNER);
    char batStr[8];
    snprintf(batStr, sizeof(batStr), "%d%%", _navData.batteryLevel);
    tft.drawString(batStr, 275, 8, 2);

    // B. Maneuver Box
    tft.fillRoundRect(164, 28, 44, 44, 8, COLOR_CYAN_TINT);
    tft.drawRoundRect(164, 28, 44, 44, 8, COLOR_CYAN);

    const uint8_t* iconData = icon_straight_32x32;
    switch (_navData.turnCode) {
      case 1: case 2: case 3: iconData = icon_turn_right_32x32; break;
      case 4: iconData = icon_uturn_32x32; break;
      case 5: case 6: case 7: iconData = icon_turn_left_32x32; break;
      case 8: iconData = icon_roundabout_32x32; break;
      case 9: iconData = icon_arrive_32x32; break;
      default: iconData = icon_straight_32x32; break;
    }
    tft.drawXBitmap(170, 34, iconData, 32, 32, 0xFFFF);

    char distStr[16];
    if (_navData.distMeters >= 1000) {
      snprintf(distStr, sizeof(distStr), "%.1fkm", (float)_navData.distMeters / 1000.0);
    } else {
      snprintf(distStr, sizeof(distStr), "%dm", _navData.distMeters);
    }
    tft.setTextColor(0xFFFF, COLOR_BG);
    tft.drawString(distStr, 214, 28, 4);

    char spdStr[16];
    snprintf(spdStr, sizeof(spdStr), "%d km/h", _navData.speedKmh);
    tft.setTextColor(COLOR_GREEN, COLOR_BG);
    tft.drawString(spdStr, 214, 54, 2);

    // C. Street Banner
    tft.fillRoundRect(164, 78, 150, 44, 6, COLOR_CARD_BG);
    tft.drawRoundRect(164, 78, 150, 44, 6, COLOR_CARD_FRAME);

    tft.setTextColor(COLOR_TEXT_MUTED, COLOR_CARD_BG);
    tft.drawString("DUONG TIEP THEO", 170, 82, 1);

    tft.setTextColor(COLOR_GOLD, COLOR_CARD_BG);
    char cleanStreet[22];
    strncpy(cleanStreet, _navData.streetName, sizeof(cleanStreet) - 1);
    cleanStreet[sizeof(cleanStreet) - 1] = '\0';
    for (int i = 0; cleanStreet[i]; i++) {
      if (cleanStreet[i] >= 'a' && cleanStreet[i] <= 'z') cleanStreet[i] -= 32;
    }
    tft.drawString(cleanStreet, 170, 96, 2);

    // D. ETA & Total Distance
    tft.fillRoundRect(164, 128, 150, 50, 6, COLOR_CARD_INNER);
    tft.drawRoundRect(164, 128, 150, 50, 6, COLOR_CARD_FRAME);

    tft.setTextColor(COLOR_TEXT_DARK, COLOR_CARD_INNER);
    tft.drawString("DU KIEN", 172, 134, 1);
    char etaClock[16];
    snprintf(etaClock, sizeof(etaClock), "%d ph", _navData.etaMinutes);
    tft.setTextColor(COLOR_CYAN, COLOR_CARD_INNER);
    tft.drawString(etaClock, 172, 148, 4);

    tft.setTextColor(COLOR_TEXT_DARK, COLOR_CARD_INNER);
    tft.drawString("QUANG DUONG", 236, 134, 1);
    char totDistStr[16];
    snprintf(totDistStr, sizeof(totDistStr), "%.1f km", (float)_navData.totalDistMeters / 1000.0);
    tft.setTextColor(COLOR_GREEN, COLOR_CARD_INNER);
    tft.drawString(totDistStr, 236, 148, 2);

    // E. Mode Status Pill
    tft.fillRoundRect(164, 184, 150, 48, 6, COLOR_CARD_BG);
    tft.drawRoundRect(164, 184, 150, 48, 6, COLOR_CARD_FRAME);

    tft.setTextColor(COLOR_GREEN, COLOR_CARD_BG);
    tft.drawString("GPS CHINH XAC", 172, 192, 2);

    tft.setTextColor(COLOR_TEXT_MUTED, COLOR_CARD_BG);
    tft.drawString("Mui ten luon ve truoc", 172, 212, 1);
  }
#endif
};

#endif
