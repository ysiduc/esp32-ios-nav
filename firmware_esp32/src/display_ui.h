#ifndef DISPLAY_UI_H
#define DISPLAY_UI_H

#include <Arduino.h>
#include "icons.h"

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
  uint16_t distMeters = 595;
  uint16_t totalDistMeters = 1200;
  uint8_t speedKmh = 0;
  uint8_t etaMinutes = 1;
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
  bool _needFullRedraw = true;
  unsigned long _lastRenderTime = 0;

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
    tft.setRotation(1); // 1 = Landscape 320x240
    tft.fillScreen(TFT_BLACK);
    _drawPairingScreenTft();
#endif
  }

  void setNavData(uint8_t turn, uint16_t dist, uint16_t totalDist, uint8_t speed, uint8_t eta, const char* street) {
    if (_navData.turnCode != turn || _navData.distMeters != dist || 
        _navData.speedKmh != speed || strcmp(_navData.streetName, street) != 0) {
      _needFullRedraw = true;
    }
    _navData.turnCode = turn;
    _navData.distMeters = dist;
    _navData.totalDistMeters = totalDist;
    _navData.speedKmh = speed;
    _navData.etaMinutes = eta;
    strncpy(_navData.streetName, street, sizeof(_navData.streetName) - 1);
    _navData.streetName[sizeof(_navData.streetName) - 1] = '\0';

    if (_currentState != STATE_POPUP_CALL && _currentState != STATE_POPUP_SMS) {
      if (_currentState != STATE_NAVIGATION) {
        _currentState = STATE_NAVIGATION;
        _needFullRedraw = true;
      }
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

  void showCallAlert(const char* callerName) {
    strncpy(_popupData.title, callerName, sizeof(_popupData.title) - 1);
    _popupData.expireMillis = millis() + 8000;
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

  void update(bool isStreamingActive = false) {
    // If phone is actively streaming JPEG video frames, do not overwrite screen
    if (isStreamingActive) {
      _needFullRedraw = true;
      return;
    }

    if ((_currentState == STATE_POPUP_CALL || _currentState == STATE_POPUP_SMS) && millis() > _popupData.expireMillis) {
      _currentState = _navData.isConnected ? STATE_NAVIGATION : STATE_PAIRING_WAIT;
      _needFullRedraw = true;
    }

#if defined(DISPLAY_OLED_SSD1306)
    _renderOled();
#elif defined(DISPLAY_TFT_ST7789)
    if (_needFullRedraw || millis() - _lastRenderTime > 500) {
      _renderTft();
      _lastRenderTime = millis();
      _needFullRedraw = false;
    }
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
      u8g2.drawStr(8, 56, "Apple ANCS Notification");
    } else if (_currentState == STATE_POPUP_SMS) {
      u8g2.drawFrame(0, 0, 128, 64);
      u8g2.drawXBMP(6, 6, 16, 16, icon_msg_16x16);
      u8g2.setFont(u8g2_font_6x10_tf);
      u8g2.drawStr(28, 16, "TIN NHAN SMS");
      u8g2.drawLine(0, 24, 128, 24);
      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(6, 38, _popupData.title);
      u8g2.setFont(u8g2_font_5x8_tf);
      u8g2.drawStr(6, 52, _popupData.message);
    } else if (_currentState == STATE_NAVIGATION) {
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
    } else {
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
  void _drawPairingScreenTft() {
    tft.fillScreen(0x0821); // Dark Navy background

    // Header bar
    tft.fillRect(0, 0, 320, 32, 0x0110);
    tft.setTextColor(0x07FF, 0x0110); // Cyan
    tft.drawCentreString("ESP32 SMART NAVIGATOR", 160, 6, 4);

    // Center Card
    tft.fillRoundRect(20, 46, 280, 175, 12, 0x18E3);
    tft.drawRoundRect(20, 46, 280, 175, 12, 0x07FF);

    tft.setTextColor(0x07E0, 0x18E3); // Green
    tft.drawString("CHE DO SAN SANG KET NOI", 40, 58, 2);

    tft.setTextColor(0xFFFF, 0x18E3);
    tft.drawString("1. Bat Bluetooth tren dien thoai", 36, 90, 2);
    tft.drawString("2. Ket noi: ESP32_NAV_ANCS", 36, 118, 2);
    tft.drawString("3. Mo App & Chon lo trinh", 36, 146, 2);

    tft.setTextColor(0xFD20, 0x18E3); // Orange
    tft.drawString("Hoac WiFi: ESP32-Navigator-Screen", 36, 180, 2);
  }

  void _renderTft() {
    if (_currentState == STATE_PAIRING_WAIT) {
      _drawPairingScreenTft();
      return;
    }

    if (_currentState == STATE_POPUP_CALL) {
      tft.fillRoundRect(15, 20, 290, 200, 16, 0x0320); // Dark Green Card
      tft.drawRoundRect(15, 20, 290, 200, 16, 0x07E0);
      tft.setTextColor(0x07E0, 0x0320);
      tft.drawCentreString("CUOC GOI DEN", 160, 35, 4);
      tft.setTextColor(0xFFFF, 0x0320);
      tft.drawCentreString(_popupData.title, 160, 95, 4);
      tft.setTextColor(0x07FF, 0x0320);
      tft.drawCentreString("Apple ANCS Notification", 160, 165, 2);
      return;
    }

    if (_currentState == STATE_POPUP_SMS) {
      tft.fillRoundRect(15, 20, 290, 200, 16, 0x0014); // Dark Blue Card
      tft.drawRoundRect(15, 20, 290, 200, 16, 0x07FF);
      tft.setTextColor(0x07FF, 0x0014);
      tft.drawCentreString("TIN NHAN MOI", 160, 35, 4);
      tft.setTextColor(0xFFE0, 0x0014);
      tft.drawCentreString(_popupData.title, 160, 85, 4);
      tft.setTextColor(0xFFFF, 0x0014);
      tft.drawCentreString(_popupData.message, 160, 135, 2);
      return;
    }

    // STATE_NAVIGATION: Cyberpunk Split-Screen HUD (320x240)
    // Clear screen
    tft.fillScreen(0x0842); // Very dark slate

    // Left Panel (Mini Map / Direction Arrow + Turn Distance)
    tft.fillRoundRect(8, 8, 145, 224, 10, 0x10A2);
    tft.drawRoundRect(8, 8, 145, 224, 10, 0x07FF); // Cyan border

    // Turn Arrow / Maneuver Text
    tft.setTextColor(0x07FF, 0x10A2);
    const char* turnText = "DI THANG";
    switch (_navData.turnCode) {
      case 1: case 2: case 3: turnText = "RE PHAI"; break;
      case 5: case 6: case 7: turnText = "RE TRAI"; break;
      case 4: turnText = "QUAY DAU"; break;
      case 8: turnText = "VONG XUYEN"; break;
      case 9: turnText = "DEN NOI"; break;
    }
    tft.drawCentreString(turnText, 80, 20, 4);

    // Distance to next turn
    tft.setTextColor(0xFFFF, 0x10A2);
    char distStr[16];
    if (_navData.distMeters >= 1000) {
      snprintf(distStr, sizeof(distStr), "%.1f km", (float)_navData.distMeters / 1000.0);
    } else {
      snprintf(distStr, sizeof(distStr), "%d m", _navData.distMeters);
    }
    tft.drawCentreString(distStr, 80, 95, 7); // Large 7-segment font

    // Next turn subtext
    tft.setTextColor(0x07E0, 0x10A2);
    tft.drawCentreString("KHOANG CACH", 80, 185, 2);

    // Right Panel (Speed, Street Name, ETA)
    tft.fillRoundRect(160, 8, 152, 224, 10, 0x10A2);
    tft.drawRoundRect(160, 8, 152, 224, 10, 0x07E0); // Green border

    // Speedometer
    char spdStr[16];
    snprintf(spdStr, sizeof(spdStr), "%d", _navData.speedKmh);
    tft.setTextColor(0x07E0, 0x10A2);
    tft.drawCentreString(spdStr, 236, 20, 7);
    tft.drawString("km/h", 215, 85, 2);

    // Divider
    tft.drawFastHLine(170, 112, 132, 0x3186);

    // Street Name
    tft.setTextColor(0xFFE0, 0x10A2); // Bright Yellow
    tft.drawCentreString(_navData.streetName, 236, 125, 4);

    // ETA & Total Distance
    char metaStr[32];
    snprintf(metaStr, sizeof(metaStr), "ETA %d ph | %dm", _navData.etaMinutes, _navData.totalDistMeters);
    tft.setTextColor(0x07FF, 0x10A2);
    tft.drawCentreString(metaStr, 236, 190, 2);
  }
#endif
};

#endif
