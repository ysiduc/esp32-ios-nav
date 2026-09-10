#ifndef DISPLAY_UI_H
#define DISPLAY_UI_H

#include <Arduino.h>
#include "icons.h"

#if defined(DISPLAY_OLED_SSD1306)
#include <U8g2lib.h>
#include <Wire.h>

// U8g2 I2C Display Constructor (SDA: 21, SCL: 22)
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
  uint16_t distMeters = 0;
  uint16_t totalDistMeters = 0;
  uint8_t speedKmh = 0;
  uint8_t etaMinutes = 0;
  char streetName[32] = "SAN SANG";
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

public:
  void init() {
#if defined(DISPLAY_OLED_SSD1306)
    u8g2.begin();
    u8g2.enableUTF8Print();
    u8g2.setFontMode(0);
#elif defined(DISPLAY_TFT_ST7789)
    tft.init();
    tft.setRotation(1);
    tft.fillScreen(TFT_BLACK);
#endif
  }

  void setNavData(uint8_t turn, uint16_t dist, uint16_t totalDist, uint8_t speed, uint8_t eta, const char* street) {
    _navData.turnCode = turn;
    _navData.distMeters = dist;
    _navData.totalDistMeters = totalDist;
    _navData.speedKmh = speed;
    _navData.etaMinutes = eta;
    strncpy(_navData.streetName, street, sizeof(_navData.streetName) - 1);
    _navData.streetName[sizeof(_navData.streetName) - 1] = '\0';

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
    _popupData.expireMillis = millis() + 8000; // 8 seconds timeout
    _currentState = STATE_POPUP_CALL;
  }

  void showSmsAlert(const char* sender, const char* msg) {
    strncpy(_popupData.title, sender, sizeof(_popupData.title) - 1);
    strncpy(_popupData.message, msg, sizeof(_popupData.message) - 1);
    _popupData.expireMillis = millis() + 6000; // 6 seconds timeout
    _currentState = STATE_POPUP_SMS;
  }

  void update() {
    // Check if popup expired -> return to navigation or pairing
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
      // Call Popup Frame
      u8g2.drawFrame(0, 0, 128, 64);
      u8g2.drawXBMP(6, 6, 16, 16, icon_phone_16x16);
      u8g2.setFont(u8g2_font_6x10_tf);
      u8g2.drawStr(28, 16, "CUOC GOI DEN");
      u8g2.drawLine(0, 24, 128, 24);

      u8g2.setFont(u8g2_font_7x14B_tf);
      u8g2.drawStr(8, 44, _popupData.title);

      u8g2.setFont(u8g2_font_5x8_tf);
      u8g2.drawStr(8, 56, "ANCS Apple Notification");
    }
    else if (_currentState == STATE_POPUP_SMS) {
      // SMS Popup Frame
      u8g2.drawFrame(0, 0, 128, 64);
      u8g2.drawXBMP(6, 6, 16, 16, icon_msg_16x16);
      u8g2.setFont(u8g2_font_6x10_tf);
      u8g2.drawStr(28, 16, "TIN NHAN SMS");
      u8g2.drawLine(0, 24, 128, 24);

      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(6, 38, _popupData.title);
      u8g2.setFont(u8g2_font_5x8_tf);
      u8g2.drawStr(6, 52, _popupData.message);
    }
    else if (_currentState == STATE_NAVIGATION) {
      // 1. Maneuver Icon (32x32 at top-left)
      const uint8_t* icon = icon_straight_32x32;
      switch (_navData.turnCode) {
        case 1: case 2: case 3: icon = icon_turn_right_32x32; break;
        case 5: case 6: case 7: icon = icon_turn_left_32x32; break;
        case 8: icon = icon_roundabout_32x32; break;
        case 9: icon = icon_arrive_32x32; break;
        default: icon = icon_straight_32x32; break;
      }
      u8g2.drawXBMP(4, 4, 32, 32, icon);

      // 2. Distance Text
      u8g2.setFont(u8g2_font_logisoso16_tr);
      char distStr[16];
      if (_navData.distMeters >= 1000) {
        snprintf(distStr, sizeof(distStr), "%.1f km", (float)_navData.distMeters / 1000.0);
      } else {
        snprintf(distStr, sizeof(distStr), "%d m", _navData.distMeters);
      }
      u8g2.drawStr(44, 22, distStr);

      // 3. Speedometer & ETA
      u8g2.setFont(u8g2_font_6x10_tf);
      char metaStr[24];
      snprintf(metaStr, sizeof(metaStr), "%d km/h  %d m", _navData.speedKmh, _navData.etaMinutes);
      u8g2.drawStr(44, 36, metaStr);

      // 4. Street Name Banner (Bottom)
      u8g2.drawBox(0, 44, 128, 20);
      u8g2.setDrawColor(0); // White text on black box
      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(4, 58, _navData.streetName);
      u8g2.setDrawColor(1); // Reset draw color
    }
    else {
      // Pairing wait screen
      u8g2.drawXBMP(8, 6, 16, 16, icon_ble_16x16);
      u8g2.setFont(u8g2_font_6x10_tf);
      u8g2.drawStr(30, 16, "ESP32 NAV");
      u8g2.drawLine(0, 24, 128, 24);

      u8g2.setFont(u8g2_font_5x8_tf);
      u8g2.drawStr(6, 38, "1. Vao Cai dat iPhone");
      u8g2.drawStr(6, 48, "2. Ket noi Bluetooth");
      u8g2.drawStr(6, 58, "3. Mo App bat dieu huong");
    }

    u8g2.sendBuffer();
  }
#endif

#if defined(DISPLAY_TFT_ST7789)
  void _renderTft() {
    tft.fillScreen(TFT_BLACK);
    // ST7789 Color Rendering implementation
    if (_currentState == STATE_POPUP_CALL) {
      tft.fillRoundRect(10, 10, 220, 220, 16, TFT_DARKGREEN);
      tft.setTextColor(TFT_GREEN, TFT_DARKGREEN);
      tft.drawString("CUOC GOI DEN", 40, 30, 4);
      tft.setTextColor(TFT_WHITE, TFT_DARKGREEN);
      tft.drawString(_popupData.title, 30, 100, 4);
    } else if (_currentState == STATE_NAVIGATION) {
      tft.setTextColor(TFT_CYAN, TFT_BLACK);
      char distStr[16];
      snprintf(distStr, sizeof(distStr), "%d m", _navData.distMeters);
      tft.drawString(distStr, 30, 30, 7);

      tft.setTextColor(TFT_YELLOW, TFT_BLACK);
      tft.drawString(_navData.streetName, 20, 140, 4);

      tft.setTextColor(TFT_GREEN, TFT_BLACK);
      char spd[16];
      snprintf(spd, sizeof(spd), "%d km/h", _navData.speedKmh);
      tft.drawString(spd, 20, 190, 4);
    } else {
      tft.setTextColor(TFT_WHITE, TFT_BLACK);
      tft.drawString("ESP32 NAV - BLE PAIR", 20, 50, 4);
    }
  }
#endif
};

#endif
