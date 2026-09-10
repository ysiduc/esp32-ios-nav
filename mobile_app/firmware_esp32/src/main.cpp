#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include "display_ui.h"

// =========================================================================
// Configuration & Credentials
// =========================================================================
const char* AP_SSID = "ESP32-Navigator-Screen";
const char* AP_PASS = "12345678"; // Mật khẩu Wi-Fi (hoặc để rỗng "" nếu không pass)

WebServer server(80);

// UUIDs for Apple Notification Center Service (ANCS)
static NimBLEUUID ancsServiceUUID("7905F431-B5CE-4E99-A40F-4B1E122D00D0");
static NimBLEUUID navServiceUUID("0000FFE0-0000-1000-8000-00805F9B34FB");
static NimBLEUUID navCharUUID("0000FFE1-0000-1000-8000-00805F9B34FB");

#if defined(DISPLAY_OLED_SSD1306)
U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2(U8G2_R0, /* reset=*/ U8X8_PIN_NONE, /* clock=*/ 22, /* data=*/ 21);
#elif defined(DISPLAY_TFT_ST7789)
TFT_eSPI tft = TFT_eSPI();
#endif

DisplayManager display;
NimBLEServer* pServer = nullptr;
NimBLECharacteristic* pNavChar = nullptr;

// Navigation & Telemetry State
volatile bool bleConnected = false;
volatile uint8_t curTurn = 0;
volatile uint16_t curDist = 0;
volatile uint16_t curTotalDist = 0;
volatile uint8_t curSpeed = 0;
volatile uint8_t curEta = 0;
String curStreet = "Cho ket noi tu App...";
String curArrival = "--:--";

// ANCS State
String popupTitle = "";
String popupMsg = "";
String popupType = "NONE"; // "CALL", "SMS", "NONE"
unsigned long popupExpire = 0;

// =========================================================================
// HTML / JS Web App for Virtual TFT Screen
// =========================================================================
const char PAGE_INDEX[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>ESP32 TFT Virtual Screen Preview</title>
  <link href="https://fonts.googleapis.com/css2?family=Orbitron:wght@500;700;900&family=Inter:wght@400;600;800&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #090c10;
      --card: #161b22;
      --border: #30363d;
      --accent: #2563eb;
      --green: #22c55e;
      --yellow: #eab308;
      --red: #ef4444;
      --cyan: #06b6d4;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg);
      color: #fff;
      font-family: 'Inter', -apple-system, sans-serif;
      display: flex;
      flex-direction: column;
      align-items: center;
      min-height: 100vh;
      padding: 16px;
      overflow-x: hidden;
    }
    header {
      text-align: center;
      margin-bottom: 16px;
      width: 100%;
      max-width: 520px;
    }
    header h1 {
      font-size: 1.25rem;
      font-weight: 800;
      background: linear-gradient(135deg, #38bdf8, #818cf8);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }
    .badge-bar {
      display: flex;
      justify-content: center;
      gap: 10px;
      margin-top: 6px;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      border-radius: 9999px;
      font-size: 0.75rem;
      font-weight: 600;
      background: #21262d;
      border: 1px solid var(--border);
    }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: #6b7280; }
    .dot.online { background: var(--green); box-shadow: 0 0 8px var(--green); }
    .dot.anim { animation: pulse 1.5s infinite; }

    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.3; }
    }

    /* Hardware TFT Bezel Frame */
    .tft-container {
      position: relative;
      width: 100%;
      max-width: 480px;
      aspect-ratio: 4 / 3;
      background: #020617;
      border-radius: 20px;
      box-shadow: 0 20px 40px rgba(0,0,0,0.8), 0 0 0 8px #1e293b, 0 0 0 10px #334155;
      overflow: hidden;
      display: flex;
    }
    
    /* 50/50 Split Screen Layout */
    .left-map {
      width: 50%;
      height: 100%;
      background: #0a0f1d;
      position: relative;
      border-right: 2px solid #1e293b;
      overflow: hidden;
    }
    .map-grid {
      position: absolute;
      width: 200%;
      height: 200%;
      top: -50%;
      left: -50%;
      background-image: 
        radial-gradient(circle at center, rgba(37,99,235,0.06) 1px, transparent 1px),
        linear-gradient(to right, rgba(255,255,255,0.03) 1px, transparent 1px),
        linear-gradient(to bottom, rgba(255,255,255,0.03) 1px, transparent 1px);
      background-size: 24px 24px, 24px 24px, 24px 24px;
    }
    .route-line {
      position: absolute;
      width: 8px;
      height: 160px;
      background: linear-gradient(180deg, #38bdf8 0%, #2563eb 100%);
      border-radius: 4px;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%) rotate(0deg);
      box-shadow: 0 0 12px #38bdf8;
      transition: transform 0.5s ease;
    }
    .user-marker {
      position: absolute;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      width: 28px;
      height: 28px;
      background: #3b82f6;
      border: 3px solid #ffffff;
      border-radius: 50%;
      box-shadow: 0 0 16px #3b82f6;
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 10;
    }
    .user-marker::after {
      content: '';
      width: 0;
      height: 0;
      border-left: 5px solid transparent;
      border-right: 5px solid transparent;
      border-bottom: 8px solid #ffffff;
      margin-bottom: 2px;
    }
    .compass-pill {
      position: absolute;
      top: 10px;
      left: 10px;
      background: rgba(15,23,42,0.8);
      border: 1px solid rgba(255,255,255,0.1);
      padding: 3px 8px;
      border-radius: 6px;
      font-size: 0.65rem;
      font-weight: 700;
      color: #38bdf8;
    }

    /* Right Half: HUD Telemetry */
    .right-hud {
      width: 50%;
      height: 100%;
      background: #0f172a;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      padding: 12px;
      position: relative;
    }
    .top-turn-row {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .turn-icon-box {
      width: 52px;
      height: 52px;
      background: #1e293b;
      border-radius: 12px;
      display: flex;
      align-items: center;
      justify-content: center;
      border: 1px solid #334155;
    }
    .turn-icon-box svg {
      width: 36px;
      height: 36px;
      fill: var(--cyan);
    }
    .turn-distance {
      font-family: 'Orbitron', monospace;
      font-size: 1.4rem;
      font-weight: 900;
      color: #ffffff;
      letter-spacing: -0.5px;
    }
    .turn-distance small {
      font-size: 0.8rem;
      color: var(--cyan);
      margin-left: 2px;
    }
    .speedometer-card {
      background: #1e293b;
      padding: 6px 10px;
      border-radius: 8px;
      border-left: 3px solid var(--green);
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .speed-val {
      font-family: 'Orbitron', monospace;
      font-size: 1.25rem;
      font-weight: 900;
      color: var(--green);
    }
    .speed-lbl {
      font-size: 0.65rem;
      font-weight: 700;
      color: #94a3b8;
    }
    .street-banner {
      background: #1e293b;
      border: 1px solid #334155;
      border-radius: 8px;
      padding: 6px 8px;
      text-align: center;
    }
    .street-text {
      font-size: 0.8rem;
      font-weight: 800;
      color: var(--yellow);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .bottom-eta-row {
      display: flex;
      justify-content: space-between;
      background: #020617;
      padding: 6px 8px;
      border-radius: 8px;
      font-size: 0.7rem;
      font-weight: 700;
    }
    .eta-clock { color: #f8fafc; }
    .eta-remain { color: var(--cyan); }

    /* ANCS Popup Overlay */
    .popup-overlay {
      position: absolute;
      inset: 8px;
      background: rgba(15, 23, 42, 0.95);
      border-radius: 14px;
      border: 2px solid var(--green);
      padding: 16px;
      display: none;
      flex-direction: column;
      justify-content: center;
      align-items: center;
      text-align: center;
      z-index: 50;
      backdrop-filter: blur(8px);
      animation: popIn 0.3s ease;
    }
    .popup-overlay.call { border-color: var(--green); }
    .popup-overlay.sms { border-color: var(--cyan); }
    .popup-title { font-size: 1.1rem; font-weight: 800; margin-top: 8px; color: #fff; }
    .popup-sub { font-size: 0.8rem; color: #94a3b8; margin-top: 4px; }

    @keyframes popIn {
      from { opacity: 0; transform: scale(0.9); }
      to { opacity: 1; transform: scale(1); }
    }

    /* Test Controls Card */
    .control-panel {
      margin-top: 20px;
      width: 100%;
      max-width: 480px;
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 14px;
    }
    .control-panel h3 {
      font-size: 0.9rem;
      margin-bottom: 10px;
      color: #94a3b8;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .btn-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 8px;
    }
    .btn {
      background: #21262d;
      color: #fff;
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 10px;
      font-size: 0.75rem;
      font-weight: 600;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 6px;
      transition: all 0.15s ease;
    }
    .btn:active {
      transform: scale(0.97);
      background: #30363d;
    }
  </style>
</head>
<body>

  <header>
    <h1>ESP32-S3 TFT Display Simulation</h1>
    <div class="badge-bar">
      <div class="badge">
        <div id="bleDot" class="dot"></div>
        <span id="bleText">BLE: Đang chờ iPhone...</span>
      </div>
      <div class="badge">
        <div class="dot online anim"></div>
        <span>Wi-Fi AP (192.168.4.1)</span>
      </div>
    </div>
  </header>

  <!-- Virtual Physical TFT Screen (240x320 / 320x240 Landscape Mode) -->
  <div class="tft-container">
    
    <!-- Left 50%: Live Mini Map -->
    <div class="left-map">
      <div class="map-grid"></div>
      <div id="routeLine" class="route-line"></div>
      <div class="user-marker"></div>
      <div class="compass-pill">GPS 3D LOCK</div>
    </div>

    <!-- Right 50%: Turn HUD & Telemetry -->
    <div class="right-hud">
      <div class="top-turn-row">
        <div class="turn-icon-box" id="turnIconBox">
          <!-- Turn Arrow SVG (Dynamically Injected) -->
          <svg viewBox="0 0 24 24" id="turnSvg">
            <path d="M12 2L4 10h5v10h6V10h5L12 2z"/>
          </svg>
        </div>
        <div>
          <div class="turn-distance" id="distTxt">0<small>m</small></div>
        </div>
      </div>

      <div class="speedometer-card">
        <div>
          <div class="speed-val" id="speedTxt">0</div>
        </div>
        <div class="speed-lbl">KM/H</div>
      </div>

      <div class="street-banner">
        <div class="street-text" id="streetTxt">Tiep tuc</div>
      </div>

      <div class="bottom-eta-row">
        <div class="eta-clock" id="arrivalTxt">DEN: --:--</div>
        <div class="eta-remain" id="etaTxt">CON: 0 ph</div>
      </div>
    </div>

    <!-- ANCS Call/SMS Alert Overlay -->
    <div id="popupOverlay" class="popup-overlay">
      <div id="popupIcon" style="font-size: 2rem;">📞</div>
      <div id="popupTitle" class="popup-title">CUOC GOI DEN</div>
      <div id="popupSub" class="popup-sub">iPhone Connected</div>
    </div>

  </div>

  <!-- Interactive Test Panel (Previewing Without Phone) -->
  <div class="control-panel">
    <h3>
      <span>Bảng Giả Lập & Thử Nghiệm</span>
      <span style="font-size: 0.75rem; color: var(--cyan);" id="fpsVal">15 FPS</span>
    </h3>
    <div class="btn-grid">
      <button class="btn" onclick="testNav(6, 150, 42, 'Pho Dinh Cong', 5, '10:50')">⬅️ Rẽ trái 150m</button>
      <button class="btn" onclick="testNav(2, 450, 48, 'Duong Giai Phong', 12, '10:57')">➡️ Rẽ phải 450m</button>
      <button class="btn" onclick="testNav(0, 1200, 55, 'Pho Xa Dan', 22, '11:07')">⬆️ Đi thẳng 1.2km</button>
      <button class="btn" onclick="testNav(8, 80, 25, 'Vong xuyen Big C', 3, '10:48')">🔄 Vòng xuyến 80m</button>
      <button class="btn" onclick="testCall('Me Yeu (0912345678)')">📞 Test Cuộc Gọi Đến</button>
      <button class="btn" onclick="testSms('Zalo', 'Dang o dau the?')">💬 Test Tin Nhắn Zalo</button>
    </div>
  </div>

  <script>
    const turnIcons = {
      0: `<path d="M12 2L4 10h5v10h6V10h5L12 2z"/>`, // Straight
      1: `<path d="M14 4l-1.4 1.4 2.6 2.6H8c-2.2 0-4 1.8-4 4v6h2v-6c0-1.1.9-2 2-2h7.2l-2.6 2.6L14 18l6-7-6-7z"/>`, // Slight Right
      2: `<path d="M19 12l-7-7v4H6a2 2 0 0 0-2 2v9h4v-7h4v4l7-7z"/>`, // Right
      3: `<path d="M19 12l-7-7v4H6a2 2 0 0 0-2 2v9h4v-7h4v4l7-7z"/>`, // Sharp Right
      4: `<path d="M6 14v-4c0-3.3 2.7-6 6-6s6 2.7 6 6v7h2v-7c0-4.4-3.6-8-8-8s-8 3.6-8 8v4H1l4.5 5.5L10 14H6z"/>`, // U-Turn
      5: `<path d="M10 4l1.4 1.4-2.6 2.6H16c2.2 0 4 1.8 4 4v6h-2v-6c0-1.1-.9-2-2-2H8.8l2.6 2.6L10 18l-6-7 6-7z"/>`, // Slight Left
      6: `<path d="M5 12l7-7v4h6a2 2 0 0 1 2 2v9h-4v-7h-4v4l-7-7z"/>`, // Left
      7: `<path d="M5 12l7-7v4h6a2 2 0 0 1 2 2v9h-4v-7h-4v4l-7-7z"/>`, // Sharp Left
      8: `<path d="M12 2a10 10 0 1 0 10 10A10 10 0 0 0 12 2zm1 14.9V14h-2v2.9A8 8 0 0 1 4.1 11H7V9H4.1A8 8 0 0 1 11 4.1V7h2V4.1A8 8 0 0 1 19.9 11H17v2h2.9a8 8 0 0 1-6.9 3.9z"/>`, // Roundabout
      9: `<path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z"/>` // Arrive
    };

    function updateUi(data) {
      // BLE Badge
      const bleDot = document.getElementById('bleDot');
      const bleText = document.getElementById('bleText');
      if (data.ble) {
        bleDot.className = 'dot online anim';
        bleText.innerText = 'iPhone Đã Kết Nối';
      } else {
        bleDot.className = 'dot';
        bleText.innerText = 'BLE: Đang chờ iPhone...';
      }

      // Distance
      const distTxt = document.getElementById('distTxt');
      if (data.dist >= 1000) {
        distTxt.innerHTML = (data.dist / 1000).toFixed(1) + '<small>km</small>';
      } else {
        distTxt.innerHTML = data.dist + '<small>m</small>';
      }

      // Turn Icon
      const turnSvg = document.getElementById('turnSvg');
      turnSvg.innerHTML = turnIcons[data.turn] || turnIcons[0];

      // Speed & Street
      document.getElementById('speedTxt').innerText = data.speed;
      document.getElementById('streetTxt').innerText = data.street || 'Tiep tuc';

      // ETA
      document.getElementById('arrivalTxt').innerText = 'DEN: ' + (data.arrival || '--:--');
      document.getElementById('etaTxt').innerText = 'CON: ' + data.eta + ' ph';

      // Map Route Line tilt
      const routeLine = document.getElementById('routeLine');
      if (data.turn === 2 || data.turn === 1) routeLine.style.transform = 'translate(-50%, -50%) rotate(35deg)';
      else if (data.turn === 6 || data.turn === 5) routeLine.style.transform = 'translate(-50%, -50%) rotate(-35deg)';
      else routeLine.style.transform = 'translate(-50%, -50%) rotate(0deg)';

      // Popup
      const popup = document.getElementById('popupOverlay');
      if (data.popup && data.popup !== 'NONE') {
        popup.style.display = 'flex';
        popup.className = 'popup-overlay ' + (data.popup === 'CALL' ? 'call' : 'sms');
        document.getElementById('popupIcon').innerText = data.popup === 'CALL' ? '📞' : '💬';
        document.getElementById('popupTitle').innerText = data.title || 'THONG BAO';
        document.getElementById('popupSub').innerText = data.msg || 'iPhone Notification';
      } else {
        popup.style.display = 'none';
      }
    }

    // Live Polling loop from ESP32 REST API (~15 FPS)
    async function pollStatus() {
      try {
        const res = await fetch('/api/status');
        if (res.ok) {
          const data = await res.json();
          updateUi(data);
        }
      } catch (e) {}
      setTimeout(pollStatus, 100);
    }
    pollStatus();

    // Client-side testing handlers
    function testNav(turn, dist, speed, street, eta, arrival) {
      fetch(`/api/test?turn=${turn}&dist=${dist}&speed=${speed}&street=${encodeURIComponent(street)}&eta=${eta}&arrival=${arrival}`);
    }
    function testCall(name) {
      fetch(`/api/test_call?name=${encodeURIComponent(name)}`);
    }
    function testSms(sender, msg) {
      fetch(`/api/test_sms?sender=${encodeURIComponent(sender)}&msg=${encodeURIComponent(msg)}`);
    }
  </script>
</body>
</html>
)rawliteral";

// =========================================================================
// Web Server Request Handlers
// =========================================================================
void handleRoot() {
  server.send_P(200, "text/html", PAGE_INDEX);
}

void handleStatusApi() {
  // Check if popup expired
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
  String name = server.hasArg("name") ? server.arg("name") : "Cuoc goi den";
  popupTitle = name;
  popupMsg = "Cuoc goi den tu iPhone";
  popupType = "CALL";
  popupExpire = millis() + 8000;

  display.showCallAlert(name.c_str());
  server.send(200, "text/plain", "OK");
}

void handleTestSms() {
  String sender = server.hasArg("sender") ? server.arg("sender") : "Tin nhan";
  String msg = server.hasArg("msg") ? server.arg("msg") : "Ban co thong bao moi";
  popupTitle = sender;
  popupMsg = msg;
  popupType = "SMS";
  popupExpire = millis() + 6000;

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
// 2. Custom Navigation Characteristic Callback (BLE RX from iPhone)
// =========================================================================
class NavCharCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic) {
    std::string value = pCharacteristic->getValue();
    if (value.length() == 0) return;

    Serial.printf("[BLE RX Nav]: %s\n", value.c_str());

    JsonDocument doc;
    DeserializationError error = deserializeJson(doc, value.c_str());

    if (!error) {
      curTurn = doc["turn"] | 0;
      curDist = doc["dist"] | 0;
      curTotalDist = doc["tot_dist"] | 0;
      curSpeed = doc["speed"] | 0;
      curEta = doc["eta"] | 0;
      curStreet = String(doc["street"] | "Tiep tuc");
      curArrival = String(doc["arrival"] | "--:--");

      display.setNavData(curTurn, curDist, curTotalDist, curSpeed, curEta, curStreet.c_str());
    } else {
      Serial.printf("[JSON] Loi parse JSON: %s\n", error.c_str());
    }
  }
};

// =========================================================================
// Setup & Loop
// =========================================================================
void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n=== ESP32-S3 SMART NAVIGATOR WITH WEB PREVIEW ===");

  // 1. Khởi động Wi-Fi SoftAP để điện thoại/máy tính truy cập Web
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);
  IPAddress IP = WiFi.softAPIP();
  Serial.printf("[WiFi AP] Da bat Hotspot Wi-Fi: %s (Pass: %s)\n", AP_SSID, AP_PASS);
  Serial.printf("[WiFi AP] Truy cap giao dien tai: http://%s\n", IP.toString().c_str());

  // 2. Cấu hình WebServer
  server.on("/", HTTP_GET, handleRoot);
  server.on("/api/status", HTTP_GET, handleStatusApi);
  server.on("/api/test", HTTP_GET, handleTestNav);
  server.on("/api/test_call", HTTP_GET, handleTestCall);
  server.on("/api/test_sms", HTTP_GET, handleTestSms);
  server.begin();
  Serial.println("[HTTP] Web Server dang chay tren port 80!");

  // 3. Khởi động màn hình TFT (nếu có gắn)
  display.init();

  // 4. Khởi động BLE Server
  NimBLEDevice::init("ESP32_NAV_ANCS");
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
  pAdvertising->addServiceUUID(ancsServiceUUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  Serial.println("[BLE] ESP32 da bat dau phat Bluetooth (ANCS + Navigation)!");
}

void loop() {
  // Xử lý các yêu cầu Web Server từ điện thoại thứ 2
  server.handleClient();

  // Cập nhật màn hình phần cứng TFT (nếu có gắn)
  display.update();
  
  delay(10); // Loop nhạy 10ms mượt mà
}

