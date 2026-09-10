#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include "display_ui.h"

// =========================================================================
// Wi-Fi SoftAP Configuration
// =========================================================================
const char* AP_SSID = "ESP32-Navigator-Screen";
const char* AP_PASS = "12345678";

WebServer server(80);

// Frame Buffer for Direct High-Speed 20-30 FPS JPEG Stream
static uint8_t jpegFrameBuf[40960];
volatile size_t jpegFrameLen = 0;
volatile unsigned long lastFrameTime = 0;
static uint8_t currentBleFrameId = 255;
static size_t bleJpegBytesReceived = 0;

// UUIDs for Custom Navigation Service
static NimBLEUUID navServiceUUID("0000FFE0-0000-1000-8000-00805F9B34FB");
static NimBLEUUID navCharUUID("0000FFE1-0000-1000-8000-00805F9B34FB");

#if defined(DISPLAY_OLED_SSD1306)
U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2(U8G2_R0, /* reset=*/ U8X8_PIN_NONE, /* clock=*/ 22, /* data=*/ 21);
#elif defined(DISPLAY_TFT_ST7789)
TFT_eSPI tft = TFT_eSPI();
#include <TJpg_Decoder.h>
bool tft_output(int16_t x, int16_t y, uint16_t w, uint16_t h, uint16_t* bitmap) {
  if (y >= tft.height() || x >= 160) return 0;
  if (x + w > 160) {
    w = 160 - x;
  }
  tft.pushImage(x, y, w, h, bitmap);
  return 1;
}
#endif

DisplayManager display;
NimBLEServer* pServer = nullptr;
NimBLECharacteristic* pNavChar = nullptr;

// Navigation & Telemetry State
volatile bool bleConnected = false;
volatile uint8_t curTurn = 2;
volatile uint16_t curDist = 595;
volatile uint16_t curTotalDist = 700;
volatile uint8_t curSpeed = 0;
volatile uint8_t curEta = 1;
volatile int curHeading = 0;
String curStreet = "PHO DAI TU";
String curArrival = "11:25";

// ANCS / Notification State
String popupTitle = "";
String popupMsg = "";
String popupType = "NONE";
unsigned long popupExpire = 0;

// =========================================================================
// Web Page: 100% Exact Match to iOS Simulation Screen (Image 2)
// =========================================================================
const char PAGE_INDEX[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>ESP32 Smart Navigator Screen</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    :root {
      --bg: #0B0F19;
      --card-bg: #151D2A;
      --accent: #00F0FF;
      --accent-green: #05FFA1;
      --gold: #FFB800;
      --border: #222F42;
    }
    body {
      background: var(--bg);
      color: #fff;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      display: flex;
      flex-direction: column;
      align-items: center;
      min-height: 100vh;
      padding: 10px 8px 30px;
    }
    header {
      text-align: center;
      margin-bottom: 10px;
      width: 100%;
      max-width: 440px;
    }
    .header-title {
      font-size: 1.1rem;
      font-weight: 800;
      color: var(--accent);
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      letter-spacing: 0.5px;
    }
    .status-row {
      display: flex;
      justify-content: center;
      gap: 8px;
      margin-top: 6px;
    }
    .pill {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 3px 10px;
      border-radius: 99px;
      font-size: 0.72rem;
      font-weight: 700;
      background: var(--card-bg);
      border: 1px solid var(--border);
      color: #94A3B8;
    }
    .pill.active {
      border-color: rgba(5, 255, 161, 0.4);
      color: var(--accent-green);
    }
    .dot {
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: #64748B;
    }
    .pill.active .dot {
      background: var(--accent-green);
      box-shadow: 0 0 8px var(--accent-green);
    }
    .screen-frame {
      width: 100%;
      max-width: 420px;
      aspect-ratio: 4 / 3;
      background: #000;
      border-radius: 18px;
      border: 3px solid #1E293B;
      box-shadow: 0 10px 30px rgba(0,0,0,0.8), 0 0 20px rgba(0,240,255,0.15);
      position: relative;
      overflow: hidden;
      display: flex;
    }
    .split-left {
      width: 50%;
      height: 100%;
      position: relative;
      background: #0F172A;
      border-right: 2px solid var(--accent);
      overflow: hidden;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    #liveMapImg {
      width: 100%;
      height: 100%;
      object-fit: cover;
      display: block;
    }
    .placeholder-map {
      color: #64748B;
      font-size: 0.75rem;
      text-align: center;
      padding: 10px;
    }
    .split-right {
      width: 50%;
      height: 100%;
      padding: 12px 10px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      background: #090D16;
    }
    .maneuver-box {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .maneuver-icon {
      width: 44px;
      height: 44px;
      background: rgba(0,240,255,0.1);
      border: 1.5px solid var(--accent);
      border-radius: 10px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 1.4rem;
      font-weight: 900;
      color: var(--accent);
    }
    .dist-num {
      font-size: 1.6rem;
      font-weight: 900;
      color: #fff;
      line-height: 1.1;
      font-family: monospace;
    }
    .dist-unit {
      font-size: 0.75rem;
      color: var(--accent);
      font-weight: 700;
    }
    .street-banner {
      background: rgba(0,240,255,0.08);
      border: 1px solid rgba(0,240,255,0.25);
      border-radius: 8px;
      padding: 6px 8px;
    }
    .street-label {
      font-size: 0.58rem;
      color: #94A3B8;
      font-weight: 700;
      text-transform: uppercase;
    }
    .street-name {
      font-size: 0.82rem;
      font-weight: 800;
      color: #F8FAFC;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .metrics-row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 6px;
    }
    .metric-card {
      background: #111827;
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 5px 6px;
      text-align: center;
    }
    .metric-label {
      font-size: 0.55rem;
      color: #64748B;
      font-weight: 700;
    }
    .metric-val {
      font-size: 0.9rem;
      font-weight: 900;
      color: var(--accent-green);
      font-family: monospace;
    }
    .metric-val.gold {
      color: var(--gold);
    }
    .popup-overlay {
      position: absolute;
      top: 0; left: 0; right: 0; bottom: 0;
      background: rgba(11, 15, 25, 0.95);
      display: none;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 16px;
      text-align: center;
      z-index: 10;
    }
    .popup-overlay.active {
      display: flex;
    }
    .popup-box {
      background: #151D2A;
      border: 2px solid var(--accent-green);
      border-radius: 14px;
      padding: 16px 20px;
      width: 90%;
      box-shadow: 0 0 25px rgba(5,255,161,0.3);
    }
    .popup-box.sms {
      border-color: var(--accent);
      box-shadow: 0 0 25px rgba(0,240,255,0.3);
    }
    .popup-type {
      font-size: 0.72rem;
      font-weight: 800;
      color: var(--accent-green);
      text-transform: uppercase;
      letter-spacing: 1px;
    }
    .popup-title {
      font-size: 1.1rem;
      font-weight: 900;
      color: #fff;
      margin: 6px 0;
    }
    .popup-msg {
      font-size: 0.8rem;
      color: #CBD5E1;
    }
  </style>
</head>
<body>
  <header>
    <div class="header-title">
      <span>🚀 ESP32 SMART NAVIGATOR</span>
    </div>
    <div class="status-row">
      <div class="pill" id="blePill"><span class="dot"></span>BLE: Đang đợi</div>
      <div class="pill active"><span class="dot"></span>LCD: ST7789 HD</div>
    </div>
  </header>

  <div class="screen-frame">
    <div class="split-left">
      <img id="liveMapImg" src="/api/frame.jpg" onerror="this.style.display='none'; document.getElementById('placeholder').style.display='block';" onload="this.style.display='block'; document.getElementById('placeholder').style.display='none';" />
      <div id="placeholder" class="placeholder-map" style="display:none;">
        <div style="font-size: 1.8rem; margin-bottom: 6px;">🗺️</div>
        <b>CHỜ STREAM JPEG</b><br/>Từ App iOS (BLE/Wi-Fi)
      </div>
    </div>

    <div class="split-right">
      <div class="maneuver-box">
        <div class="maneuver-icon" id="turnIcon">↱</div>
        <div>
          <div class="dist-num" id="distVal">595</div>
          <div class="dist-unit" id="distUnit">MÉT NỮA</div>
        </div>
      </div>

      <div class="street-banner">
        <div class="street-label">ĐƯỜNG HIỆN TẠI</div>
        <div class="street-name" id="streetVal">PHỐ ĐẠI TỪ</div>
      </div>

      <div class="metrics-row">
        <div class="metric-card">
          <div class="metric-label">TỐC ĐỘ</div>
          <div class="metric-val" id="speedVal">0 <span style="font-size:0.6rem">km/h</span></div>
        </div>
        <div class="metric-card">
          <div class="metric-label">DỰ KIẾN ĐẾN</div>
          <div class="metric-val gold" id="etaVal">11:25</div>
        </div>
      </div>
    </div>

    <div class="popup-overlay" id="popupOverlay">
      <div class="popup-box" id="popupBox">
        <div class="popup-type" id="popupType">CUỘC GỌI ĐẾN</div>
        <div class="popup-title" id="popupTitle">Nguyễn Văn A</div>
        <div class="popup-msg" id="popupMsg">Cuộc gọi đến từ iPhone</div>
      </div>
    </div>
  </div>

  <script>
    const turnIcons = ['↑', '↗', '→', '↘', '⤶', '↙', '←', '↖', '⟲', '🏁'];

    function refreshFrame() {
      const img = document.getElementById('liveMapImg');
      img.src = '/api/frame.jpg?t=' + Date.now();
    }
    setInterval(refreshFrame, 200);

    async function fetchStatus() {
      try {
        const res = await fetch('/api/status');
        const d = await res.json();

        const blePill = document.getElementById('blePill');
        if (d.ble) {
          blePill.className = 'pill active';
          blePill.innerHTML = '<span class="dot"></span>BLE: Đã kết nối';
        } else {
          blePill.className = 'pill';
          blePill.innerHTML = '<span class="dot"></span>BLE: Chờ iPhone';
        }

        document.getElementById('turnIcon').textContent = turnIcons[d.turn] || '↑';
        if (d.dist >= 1000) {
          document.getElementById('distVal').textContent = (d.dist / 1000).toFixed(1);
          document.getElementById('distUnit').textContent = 'KM NỮA';
        } else {
          document.getElementById('distVal').textContent = d.dist;
          document.getElementById('distUnit').textContent = 'MÉT NỮA';
        }

        document.getElementById('streetVal').textContent = d.street || 'TIẾP TỤC';
        document.getElementById('speedVal').innerHTML = d.speed + ' <span style="font-size:0.6rem">km/h</span>';
        document.getElementById('etaVal').textContent = d.arrival || (d.eta + ' ph');

        const overlay = document.getElementById('popupOverlay');
        const pBox = document.getElementById('popupBox');
        if (d.popup && d.popup !== 'NONE') {
          overlay.className = 'popup-overlay active';
          pBox.className = (d.popup === 'SMS') ? 'popup-box sms' : 'popup-box';
          document.getElementById('popupType').textContent = (d.popup === 'SMS') ? 'TIN NHẮN SMS' : 'CUỘC GỌI ĐẾN';
          document.getElementById('popupTitle').textContent = d.title || 'Thông báo';
          document.getElementById('popupMsg').textContent = d.msg || '';
        } else {
          overlay.className = 'popup-overlay';
        }
      } catch (e) {}
    }
    setInterval(fetchStatus, 300);
  </script>
</body>
</html>
)rawliteral";

// =========================================================================
// Web Server Handlers
// =========================================================================
void handleRoot() {
  server.send_P(200, "text/html; charset=utf-8", PAGE_INDEX);
}

void handlePostFrame() {
  if (server.hasArg("plain") == false && server.arg("plain").length() == 0) {
    server.send(400, "text/plain", "Body empty");
    return;
  }

  String body = server.arg("plain");
  size_t len = body.length();
  if (len > sizeof(jpegFrameBuf)) len = sizeof(jpegFrameBuf);

  memcpy(jpegFrameBuf, body.c_str(), len);
  jpegFrameLen = len;
  lastFrameTime = millis();

  #if defined(DISPLAY_TFT_ST7789)
  if (jpegFrameBuf[0] == 0xFF && jpegFrameBuf[1] == 0xD8) {
    TJpgDec.drawJpg(0, 0, jpegFrameBuf, jpegFrameLen);
  }
  #endif

  server.send(200, "text/plain", "Frame OK");
}

void handleGetFrame() {
  if (jpegFrameLen > 0 && (millis() - lastFrameTime < 5000)) {
    server.sendHeader("Access-Control-Allow-Origin", "*");
    server.setContentLength(jpegFrameLen);
    server.send(200, "image/jpeg", "");
    WiFiClient client = server.client();
    client.write((const uint8_t*)jpegFrameBuf, jpegFrameLen);
  } else {
    server.send(404, "text/plain", "No active stream");
  }
}

void handleStatusApi() {
  if (popupType != "NONE" && millis() > popupExpire) {
    popupType = "NONE";
  }

  JsonDocument doc;
  doc["ble"] = bleConnected;
  doc["turn"] = curTurn;
  doc["dist"] = curDist;
  doc["tot_dist"] = curTotalDist;
  doc["speed"] = curSpeed;
  doc["eta"] = curEta;
  doc["street"] = curStreet;
  doc["arrival"] = curArrival;
  doc["head"] = curHeading;
  doc["popup"] = popupType;
  doc["title"] = popupTitle;
  doc["msg"] = popupMsg;

  String output;
  serializeJson(doc, output);
  server.send(200, "application/json", output);
}

void handleTestNav() {
  if (server.hasArg("turn")) curTurn = server.arg("turn").toInt();
  if (server.hasArg("dist")) curDist = server.arg("dist").toInt();
  if (server.hasArg("speed")) curSpeed = server.arg("speed").toInt();
  if (server.hasArg("street")) curStreet = server.arg("street");
  if (server.hasArg("eta")) curEta = server.arg("eta").toInt();
  if (server.hasArg("arrival")) curArrival = server.arg("arrival");

  display.setNavData(curTurn, curDist, curTotalDist, curSpeed, curEta, curStreet.c_str());
  server.send(200, "text/plain", "OK");
}

void handleTestCall() {
  String name = server.hasArg("name") ? server.arg("name") : "Nguyen Van A";
  popupTitle = name;
  popupMsg = "Cuoc goi den tu iPhone";
  popupType = "CALL";
  popupExpire = millis() + 10000;

  display.showCallAlert(name.c_str());
  server.send(200, "text/plain", "OK");
}

void handleTestSms() {
  String sender = server.hasArg("sender") ? server.arg("sender") : "Me";
  String msg = server.hasArg("msg") ? server.arg("msg") : "Con ve nha an com nhe!";
  popupTitle = sender;
  popupMsg = msg;
  popupType = "SMS";
  popupExpire = millis() + 8000;

  display.showSmsAlert(sender.c_str(), msg.c_str());
  server.send(200, "text/plain", "OK");
}

// =========================================================================
// 1. BLE Server Callbacks
// =========================================================================
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer) {
    bleConnected = true;
    display.setBleConnected(true);
    Serial.println("[BLE] iPhone da ket noi!");
  }

  void onDisconnect(NimBLEServer* pServer) {
    bleConnected = false;
    display.setBleConnected(false);
    Serial.println("[BLE] Da ngat ket noi. Phat quang ba lai...");
    NimBLEDevice::startAdvertising();
  }
};

// =========================================================================
// 2. Custom Navigation Characteristic Callback (Receives 20 FPS JPEG & JSON)
// =========================================================================
class NavCharCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic) {
    std::string value = pCharacteristic->getValue();
    if (value.length() == 0) return;

    // 1. Check for 9-byte Robust Chunked JPEG Packet
    // [0xAA, 0xBB, frameId, totalChunks, chunkIdx, offsetMSB, offsetLSB, totalLenMSB, totalLenLSB, ...payload]
    if (value.length() >= 9 && (uint8_t)value[0] == 0xAA && (uint8_t)value[1] == 0xBB) {
      uint8_t frameId = (uint8_t)value[2];
      uint8_t totalChunks = (uint8_t)value[3];
      uint8_t chunkIdx = (uint8_t)value[4];
      uint16_t offset = ((uint8_t)value[5] << 8) | (uint8_t)value[6];
      uint16_t totalLen = ((uint8_t)value[7] << 8) | (uint8_t)value[8];
      size_t payloadLen = value.length() - 9;

      if (frameId != currentBleFrameId) {
        currentBleFrameId = frameId;
        bleJpegBytesReceived = 0;
      }

      if (offset + payloadLen <= sizeof(jpegFrameBuf)) {
        memcpy(jpegFrameBuf + offset, (const uint8_t*)value.data() + 9, payloadLen);
        bleJpegBytesReceived += payloadLen;
      }

      if (chunkIdx == totalChunks - 1 || offset + payloadLen >= totalLen) {
        jpegFrameLen = (totalLen > 0 && totalLen <= sizeof(jpegFrameBuf)) ? totalLen : (offset + payloadLen);
        if (jpegFrameBuf[0] == 0xFF && jpegFrameBuf[1] == 0xD8) {
          lastFrameTime = millis();
          #if defined(DISPLAY_TFT_ST7789)
          TJpgDec.drawJpg(0, 0, jpegFrameBuf, jpegFrameLen);
          #endif
        }
      }
      return;
    }

    // Fallback: 5-byte legacy packet [0xAA, 0xBB, frameId, totalChunks, chunkIdx, ...payload]
    if (value.length() >= 5 && (uint8_t)value[0] == 0xAA && (uint8_t)value[1] == 0xBB) {
      uint8_t frameId = (uint8_t)value[2];
      uint8_t totalChunks = (uint8_t)value[3];
      uint8_t chunkIdx = (uint8_t)value[4];

      if (frameId != currentBleFrameId) {
        currentBleFrameId = frameId;
        bleJpegBytesReceived = 0;
      }

      size_t payloadLen = value.length() - 5;
      if (bleJpegBytesReceived + payloadLen < sizeof(jpegFrameBuf)) {
        memcpy(jpegFrameBuf + bleJpegBytesReceived, (const uint8_t*)value.data() + 5, payloadLen);
        bleJpegBytesReceived += payloadLen;
      }

      if (chunkIdx == totalChunks - 1 && bleJpegBytesReceived > 100) {
        jpegFrameLen = bleJpegBytesReceived;
        if (jpegFrameBuf[0] == 0xFF && jpegFrameBuf[1] == 0xD8) {
          lastFrameTime = millis();
          #if defined(DISPLAY_TFT_ST7789)
          TJpgDec.drawJpg(0, 0, jpegFrameBuf, jpegFrameLen);
          #endif
        }
      }
      return;
    }

    // 2. JSON Notification or Navigation Telemetry
    JsonDocument doc;
    DeserializationError error = deserializeJson(doc, value.c_str());

    if (!error) {
      String typeStr = String(doc["type"] | "");
      if (typeStr == "CALL") {
        const char* name = doc["title"] | "Cuoc goi den";
        popupTitle = name;
        popupMsg = doc["msg"] | "Cuoc goi den tu iPhone";
        popupType = "CALL";
        popupExpire = millis() + 10000;
        display.showCallAlert(name);
        return;
      } else if (typeStr == "SMS") {
        const char* sender = doc["title"] | "Tin nhan";
        const char* content = doc["msg"] | "Thong bao moi";
        popupTitle = sender;
        popupMsg = content;
        popupType = "SMS";
        popupExpire = millis() + 8000;
        display.showSmsAlert(sender, content);
        return;
      }

      curTurn = doc["turn"] | 0;
      curDist = doc["dist"] | 0;
      curTotalDist = doc["tot_dist"] | 0;
      curSpeed = doc["speed"] | 0;
      curEta = doc["eta"] | 0;
      curStreet = String(doc["street"] | "Tiep tuc");
      curArrival = String(doc["arrival"] | "--:--");
      if (doc["head"].is<int>()) curHeading = doc["head"];

      display.setNavData(curTurn, curDist, curTotalDist, curSpeed, curEta, curStreet.c_str());
    }
  }
};

// =========================================================================
// Setup & Loop
// =========================================================================
void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n=== ESP32-S3 SMART NAVIGATOR (IMAGE 2 EXACT MATCH) ===");

  // 1. Start Wi-Fi SoftAP
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);
  IPAddress IP = WiFi.softAPIP();
  Serial.printf("[WiFi AP] Hotspot: %s (Pass: %s)\n", AP_SSID, AP_PASS);
  Serial.printf("[WiFi AP] Live URL: http://%s\n", IP.toString().c_str());

  // 2. Start Web Server
  const char* headerkeys[] = {"Content-Length", "Content-Type"};
  server.collectHeaders(headerkeys, 2);

  server.on("/", HTTP_GET, handleRoot);
  server.on("/api/frame", HTTP_POST, handlePostFrame);
  server.on("/api/frame.jpg", HTTP_GET, handleGetFrame);
  server.on("/api/status", HTTP_GET, handleStatusApi);
  server.on("/api/test", HTTP_GET, handleTestNav);
  server.on("/api/test_call", HTTP_GET, handleTestCall);
  server.on("/api/test_sms", HTTP_GET, handleTestSms);
  server.begin();

  // 3. Start Display (if hardware attached)
  display.init();
  #if defined(DISPLAY_TFT_ST7789)
  TJpgDec.setJpgScale(1);
  TJpgDec.setSwapBytes(true);
  TJpgDec.setCallback(tft_output);
  #endif

  // 4. Start NimBLE Server (with Max MTU 517 for High-Speed 20 FPS BLE Stream)
  NimBLEDevice::init("ESP32_NAV_ANCS");
  NimBLEDevice::setMTU(517);
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);

  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  NimBLEService* pNavService = pServer->createService(navServiceUUID);
  pNavChar = pNavService->createCharacteristic(
    navCharUUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );
  pNavChar->setCallbacks(new NavCharCallbacks());
  pNavService->start();

  NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(navServiceUUID);
  pAdvertising->setMinInterval(16);
  pAdvertising->setMaxInterval(32);
  pAdvertising->setMinPreferred(6);
  pAdvertising->setMaxPreferred(12);
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  Serial.println("[BLE] ESP32 da san sang nhan luong 20 FPS qua Bluetooth BLE (MTU 517)!");
}

void loop() {
  server.handleClient();
  display.update();
  delay(2);
}
