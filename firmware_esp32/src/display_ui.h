#ifndef DISPLAY_UI_H
#define DISPLAY_UI_H

#include <Arduino.h>
#include "icons.h"

extern volatile unsigned long lastFrameTime;

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
  unsigned long _lastRightRender = 0;
  bool _screenInitialized = false;
  bool _wasPopupActive = false;

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
    _drawBaseLayout();
    _screenInitialized = true;
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
    _popupData.expireMillis = millis() + 8000;
    _currentState = STATE_POPUP_CALL;
  }

  void showSmsAlert(const char* sender, const char* msg) {
    strncpy(_popupData.title, sender, sizeof(_popupData.title) - 1);
    strncpy(_popupData.message, msg, sizeof(_popupData.message) - 1);
    _popupData.expireMillis = millis() + 6000;
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
      const uint8_t* icon = icon_straight_32x32;
      switch (_navData.turnCode) {
        case 1: case 2: case 3: icon = icon_turn_right_32x32; break;
        case 5: case 6: case 7: icon = icon_turn_left_32x32; break;
        case 8: icon = icon_roundabout_32x32; break;
        case 9: icon = icon_arrive_32x32; break;
        default: icon = icon_straight_32x32; break;
      }
      u8g2.drawXBMP(4, 4, 32, 32, icon);

      u8g2.setFont(u8g2_font_logisoso16_tr);
      char distStr[16];
      if (_navData.distMeters >= 1000) {
        snprintf(distStr, sizeof(distStr), "%.1f km", (float)_navData.distMeters / 1000.0);
      } else {
        snprintf(distStr, sizeof(distStr), "%d m", _navData.distMeters);
      }
      u8g2.drawStr(44, 22, distStr);

      u8g2.setFont(u8g2_font_6x10_tf);
      char metaStr[24];
      snprintf(metaStr, sizeof(metaStr), "%d km/h  %d m", _navData.speedKmh, _navData.etaMinutes);
      u8g2.drawStr(44, 36, metaStr);

      u8g2.drawBox(0, 44, 128, 20);
      u8g2.setDrawColor(0);
      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(4, 58, _navData.streetName);
      u8g2.setDrawColor(1);
    }
    else {
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
  void _drawBaseLayout() {
    tft.drawFastVLine(160, 0, 240, 0x07FF); // Cyan vertical divider
  }

  void _renderTft() {
    // 1. Popup Handling
    if (_currentState == STATE_POPUP_CALL) {
      _wasPopupActive = true;
      tft.fillRoundRect(20, 30, 280, 180, 16, 0x03E0); // Dark green popup
      tft.drawRoundRect(20, 30, 280, 180, 16, TFT_GREEN);
      tft.setTextColor(TFT_WHITE, 0x03E0);
      tft.drawString("CUOC GOI DEN", 80, 50, 4);
      tft.setTextColor(TFT_YELLOW, 0x03E0);
      tft.drawString(_popupData.title, 50, 110, 4);
      return;
    } else if (_currentState == STATE_POPUP_SMS) {
      _wasPopupActive = true;
      tft.fillRoundRect(20, 30, 280, 180, 16, 0x0011); // Dark blue popup
      tft.drawRoundRect(20, 30, 280, 180, 16, 0x07FF);
      tft.setTextColor(0x07FF, 0x0011);
      tft.drawString("TIN NHAN SMS", 80, 45, 4);
      tft.setTextColor(TFT_YELLOW, 0x0011);
      tft.drawString(_popupData.title, 40, 90, 4);
      tft.setTextColor(TFT_WHITE, 0x0011);
      tft.drawString(_popupData.message, 40, 140, 2);
      return;
    }

    // If popup just closed, clear screen once and restore divider
    if (_wasPopupActive) {
      _wasPopupActive = false;
      tft.fillScreen(TFT_BLACK);
      _drawBaseLayout();
    }

    // 2. Left 160x240 Map Viewport Check
    // If stream is NOT active (> 4s without frame), draw standby placeholder
    bool isStreamActive = (lastFrameTime > 0 && (millis() - lastFrameTime < 4000));
    if (!isStreamActive && (millis() - _lastRightRender > 1000)) {
      tft.fillRect(0, 0, 160, 240, 0x0841); // Dark Navy Slate
      tft.drawRect(0, 0, 160, 240, 0x18E3);
      tft.setTextColor(0x07FF, 0x0841);
      tft.drawString("LIVE MAP", 30, 80, 4);
      tft.setTextColor(TFT_WHITE, 0x0841);
      tft.drawString("STREAMING", 35, 115, 2);
      tft.setTextColor(TFT_GREEN, 0x0841);
      tft.drawString("SAN SANG", 42, 140, 2);
      tft.drawFastVLine(160, 0, 240, 0x07FF);
    }

    // 3. Right 160x240 HUD Render (Throttled to 5 Hz / 200ms to preserve SPI bandwidth)
    if (millis() - _lastRightRender < 200) return;
    _lastRightRender = millis();

    // Clear ONLY the Right Half
    tft.fillRect(161, 0, 159, 240, TFT_BLACK);
    tft.drawFastVLine(160, 0, 240, 0x07FF); // Cyan divider line

    if (_currentState == STATE_NAVIGATION) {
      // A. Top Status Header (y = 8)
      tft.fillCircle(172, 15, 4, _navData.isConnected ? TFT_GREEN : TFT_RED);
      tft.setTextColor(TFT_WHITE, TFT_BLACK);
      tft.drawString(_navData.isConnected ? "BLE ON" : "BLE OFF", 182, 10, 2);

      // B. Turn Maneuver Header (y = 35)
      const char* turnText = "DI THANG";
      uint16_t turnColor = 0x07FF;
      switch (_navData.turnCode) {
        case 1: turnText = "RE PHAI NHE"; turnColor = TFT_GREEN; break;
        case 2: turnText = "RE PHAI"; turnColor = TFT_GREEN; break;
        case 3: turnText = "RE GAT PHAI"; turnColor = TFT_GREEN; break;
        case 4: turnText = "QUAY DAU"; turnColor = TFT_YELLOW; break;
        case 5: turnText = "RE GAT TRAI"; turnColor = TFT_CYAN; break;
        case 6: turnText = "RE TRAI"; turnColor = TFT_CYAN; break;
        case 7: turnText = "RE TRAI NHE"; turnColor = TFT_CYAN; break;
        case 8: turnText = "VONG XUYEN"; turnColor = 0xFD20; break;
        case 9: turnText = "DEN NOI"; turnColor = TFT_GREEN; break;
        default: turnText = "DI THANG"; turnColor = 0x07FF; break;
      }
      tft.setTextColor(turnColor, TFT_BLACK);
      tft.drawString(turnText, 170, 35, 4);

      // C. Distance Number (y = 75)
      char distStr[16];
      if (_navData.distMeters >= 1000) {
        snprintf(distStr, sizeof(distStr), "%.1f km", (float)_navData.distMeters / 1000.0);
      } else {
        snprintf(distStr, sizeof(distStr), "%d m", _navData.distMeters);
      }
      tft.setTextColor(TFT_WHITE, TFT_BLACK);
      tft.drawString(distStr, 170, 75, 4);

      // D. Street Name Box (y = 125)
      tft.fillRoundRect(166, 125, 148, 38, 6, 0x10A2); // Dark slate box
      tft.drawRoundRect(166, 125, 148, 38, 6, 0x2124);
      tft.setTextColor(TFT_YELLOW, 0x10A2);
      char shortStreet[20];
      strncpy(shortStreet, _navData.streetName, sizeof(shortStreet) - 1);
      shortStreet[sizeof(shortStreet) - 1] = '\0';
      tft.drawString(shortStreet, 172, 134, 2);

      // E. Speedometer & ETA (y = 175)
      char spd[16];
      snprintf(spd, sizeof(spd), "%d km/h", _navData.speedKmh);
      tft.setTextColor(TFT_GREEN, TFT_BLACK);
      tft.drawString(spd, 170, 175, 4);

      char etaStr[16];
      snprintf(etaStr, sizeof(etaStr), "ETA: %d p", _navData.etaMinutes);
      tft.setTextColor(0xFDC0, TFT_BLACK); // Gold
      tft.drawString(etaStr, 170, 210, 2);
    } else {
      // Standby / Pairing Wait UI
      tft.setTextColor(0x07FF, TFT_BLACK);
      tft.drawString("SMART NAV", 170, 30, 4);
      tft.setTextColor(TFT_WHITE, TFT_BLACK);
      tft.drawString("1. Ket noi BLE", 170, 80, 2);
      tft.drawString("2. Bat Stream", 170, 110, 2);
      tft.drawString("3. Dieu huong", 170, 140, 2);
      tft.setTextColor(TFT_GREEN, TFT_BLACK);
      tft.drawString("CHO KET NOI...", 170, 190, 2);
    }
  }
#endif
};

#endif
