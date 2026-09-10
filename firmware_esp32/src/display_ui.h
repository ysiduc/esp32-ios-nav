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
  uint8_t turnCode = 0;       // 0: straight, 1: sl_right, 2: right, 3: sh_right, 4: uturn, 5: sh_left, 6: left, 7: sl_left, 8: roundabout, 9: arrive
  uint16_t distMeters = 595;
  uint16_t totalDistMeters = 7200;
  uint8_t speedKmh = 0;
  uint8_t etaMinutes = 12;
  char streetName[32] = "PHO DAI TU";
  bool isConnected = false;
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
  DisplayState _currentState = STATE_PAIRING_WAIT;
  NavStateData _navData;
  AncsPopupData _popupData;
  unsigned long _lastRightRender = 0;
  bool _wasPopupActive = false;
  bool _leftStandbyDrawn = false;

public:
  void init() {
#if defined(DISPLAY_OLED_SSD1306)
    Wire.begin(OLED_SDA_PIN, OLED_SCL_PIN);
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
    if (!connected && _currentState == STATE_NAVIGATION) {
      _currentState = STATE_PAIRING_WAIT;
    }
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
      _currentState = _navData.isConnected ? STATE_NAVIGATION : STATE_PAIRING_WAIT;
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
    if (_currentState == STATE_POPUP_CALL) {
      // Call Popup (128x64)
      u8g2.drawFrame(0, 0, 128, 64);
      u8g2.drawXBMP(6, 5, 16, 16, icon_phone_16x16);
      u8g2.setFont(u8g2_font_6x10_tf);
      u8g2.drawStr(28, 16, "CUOC GOI DEN");
      u8g2.drawLine(0, 22, 128, 22);

      u8g2.setFont(u8g2_font_7x14B_tf);
      u8g2.drawStr(6, 42, _popupData.title);

      u8g2.setFont(u8g2_font_5x8_tf);
      u8g2.drawStr(6, 56, "ANCS Apple Notification");
    }
    else if (_currentState == STATE_POPUP_SMS) {
      // SMS Popup (128x64)
      u8g2.drawFrame(0, 0, 128, 64);
      u8g2.drawXBMP(6, 5, 16, 16, icon_msg_16x16);
      u8g2.setFont(u8g2_font_6x10_tf);
      u8g2.drawStr(28, 16, "TIN NHAN MOI");
      u8g2.drawLine(0, 22, 128, 22);

      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(6, 36, _popupData.title);

      u8g2.setFont(u8g2_font_5x8_tf);
      u8g2.drawStr(6, 52, _popupData.message);
    }
    else if (_currentState == STATE_NAVIGATION) {
      // 1. Maneuver Turn Icon (32x32 at x=2, y=2)
      const uint8_t* icon = icon_straight_32x32;
      switch (_navData.turnCode) {
        case 1: case 2: case 3: icon = icon_turn_right_32x32; break;
        case 4: icon = icon_uturn_32x32; break;
        case 5: case 6: case 7: icon = icon_turn_left_32x32; break;
        case 8: icon = icon_roundabout_32x32; break;
        case 9: icon = icon_arrive_32x32; break;
        default: icon = icon_straight_32x32; break;
      }
      u8g2.drawXBMP(2, 4, 32, 32, icon);

      // 2. Distance Text (Large)
      u8g2.setFont(u8g2_font_logisoso16_tr);
      char distStr[16];
      if (_navData.distMeters >= 1000) {
        snprintf(distStr, sizeof(distStr), "%.1f km", (float)_navData.distMeters / 1000.0);
      } else {
        snprintf(distStr, sizeof(distStr), "%d m", _navData.distMeters);
      }
      u8g2.drawStr(38, 20, distStr);

      // 3. Speed & ETA Metrics
      u8g2.setFont(u8g2_font_6x10_tf);
      char metaStr[24];
      snprintf(metaStr, sizeof(metaStr), "%d km/h  %d ph", _navData.speedKmh, _navData.etaMinutes);
      u8g2.drawStr(38, 34, metaStr);

      // 4. Street Name Banner (Bottom Inverted Bar)
      u8g2.drawBox(0, 42, 128, 22);
      u8g2.setDrawColor(0); // White text on dark box
      u8g2.setFont(u8g2_font_6x12_tf);
      char cleanStreet[24];
      strncpy(cleanStreet, _navData.streetName, sizeof(cleanStreet) - 1);
      cleanStreet[sizeof(cleanStreet) - 1] = '\0';
      u8g2.drawStr(4, 57, cleanStreet);
      u8g2.setDrawColor(1);
    }
    else {
      // Standby / Pairing Wait Screen
      u8g2.drawXBMP(6, 4, 16, 16, icon_ble_16x16);
      u8g2.setFont(u8g2_font_6x10_tf);
      u8g2.drawStr(28, 15, "ESP32 NAV BLE");
      u8g2.drawLine(0, 22, 128, 22);

      u8g2.setFont(u8g2_font_5x8_tf);
      u8g2.drawStr(6, 34, "1. Vao Cai dat iPhone");
      u8g2.drawStr(6, 44, "2. Ket noi ESP32_NAV");
      u8g2.drawStr(6, 56, "3. Mo App bat dan duong");
    }
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
