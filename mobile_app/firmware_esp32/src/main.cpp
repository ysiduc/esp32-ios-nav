#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include "display_ui.h"

// =========================================================================
// Wi-Fi SoftAP Configuration (100% Offline Standalone Web Server)
// =========================================================================
const char* AP_SSID = "ESP32-Navigator-Screen";
const char* AP_PASS = "12345678";

WebServer server(80);

// UUIDs for Custom Navigation Service
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
volatile uint8_t curTurn = 6; // Default to Left turn for preview
volatile uint16_t curDist = 410;
volatile uint16_t curTotalDist = 1200;
volatile uint8_t curSpeed = 38;
volatile uint8_t curEta = 2;
volatile int curHeading = 180;
String curStreet = "P. NGUYEN CANH DI";
String curArrival = "11:09";

// ANCS / Notification State
String popupTitle = "";
String popupMsg = "";
String popupType = "NONE"; // "CALL", "SMS", "NONE"
unsigned long popupExpire = 0;

// =========================================================================
// 100% OFFLINE HTML5 CANVAS MAP & DUAL HUD SCREEN (NO EXTERNAL INTERNET NEEDED)
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
    body {
      background: #080C14;
      color: #fff;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      display: flex;
      flex-direction: column;
      align-items: center;
      min-height: 100vh;
      padding: 10px;
      user-select: none;
      -webkit-user-select: none;
    }
    header {
      text-align: center;
      margin-bottom: 10px;
      width: 100%;
      max-width: 440px;
    }
    .header-title {
      font-size: 1.05rem;
      font-weight: 800;
      color: #00F0FF;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 6px;
    }
    .status-row {
      display: flex;
      justify-content: center;
      gap: 8px;
      margin-top: 4px;
    }
    .pill {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      padding: 2px 10px;
      border-radius: 99px;
      font-size: 0.7rem;
      font-weight: 700;
      background: #151D2A;
      border: 1px solid #222F42;
    }
    .dot { width: 7px; height: 7px; border-radius: 50%; background: #64748b; }
    .dot.active { background: #05FFA1; box-shadow: 0 0 6px #05FFA1; }

    /* Physical Screen Shell Matching Exact iOS App Mockup */
    .device-shell {
      position: relative;
      width: 100%;
      max-width: 420px;
      height: 255px;
      background: #1C232D;
      border-radius: 24px;
      border: 6px solid #2B3545;
      box-shadow: 0 16px 40px rgba(0,0,0,0.9);
      overflow: hidden;
      padding: 4px;
      display: flex;
      flex-direction: column;
    }

    /* Top Hardware Bar */
    .hw-bar {
      height: 20px;
      background: rgba(0,0,0,0.8);
      border-radius: 6px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 8px;
      font-size: 0.65rem;
      font-family: monospace;
      font-weight: bold;
      margin-bottom: 4px;
      z-index: 100;
    }
    .ble-tag { color: #ff5555; }
    .ble-tag.connected { color: #00F0FF; }
    .battery { color: #05FFA1; }

    /* 50/50 Split Area */
    .screen-area {
      flex: 1;
      display: flex;
      gap: 6px;
      position: relative;
      background: #000;
      border-radius: 12px;
      overflow: hidden;
      padding: 4px;
    }

    /* LEFT 50%: Pure Offline Vector Map Canvas */
    .map-box {
      flex: 1;
      height: 100%;
      border-radius: 10px;
      overflow: hidden;
      border: 1.2px solid rgba(0, 240, 255, 0.4);
      position: relative;
      background: #E8ECEF;
    }
    #mapCanvas {
      width: 100%;
      height: 100%;
      display: block;
    }
    .map-live-tag {
      position: absolute;
      bottom: 4px;
      left: 4px;
      background: rgba(0,0,0,0.75);
      color: #00F0FF;
      font-size: 0.55rem;
      font-family: monospace;
      font-weight: 800;
      padding: 2px 5px;
      border-radius: 4px;
      z-index: 10;
    }

    /* RIGHT 50%: HUD Box */
    .hud-box {
      flex: 1;
      height: 100%;
      background: #141B26;
      border-radius: 10px;
      border: 1px solid rgba(255,255,255,0.08);
      padding: 8px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
    }

    /* Turn Direction & Distance */
    .turn-row {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .turn-badge {
      width: 44px;
      height: 44px;
      background: rgba(0, 240, 255, 0.15);
      border: 1.5px solid #00F0FF;
      border-radius: 10px;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .turn-badge svg {
      width: 30px;
      height: 30px;
      fill: #00F0FF;
    }
    .turn-dist-col {
      display: flex;
      flex-direction: column;
    }
    .dist-val {
      font-size: 1.3rem;
      font-weight: 900;
      font-family: monospace;
      color: #ffffff;
      line-height: 1;
    }
    .speed-val {
      font-size: 0.75rem;
      font-weight: 800;
      font-family: monospace;
      color: #05FFA1;
      margin-top: 3px;
    }

    /* Street Banner */
    .street-card {
      background: #0D131C;
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 6px;
      padding: 5px 6px;
      text-align: center;
    }
    .street-name {
      font-size: 0.75rem;
      font-weight: 800;
      color: #FFB800;
      font-family: monospace;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      text-transform: uppercase;
    }

    /* ETA Footer */
    .eta-card {
      background: #080C12;
      border-radius: 6px;
      padding: 4px 8px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-family: monospace;
    }
    .eta-left { font-size: 0.65rem; color: #94a3b8; }
    .eta-clock { color: #00F0FF; font-weight: bold; font-size: 0.8rem; }
    .eta-mins { color: #05FFA1; font-weight: bold; font-size: 0.8rem; }

    /* ANCS Popup (Incoming Call & SMS) */
    .ancs-popup {
      position: absolute;
      inset: 4px;
      background: rgba(0, 43, 27, 0.98);
      border-radius: 12px;
      border: 2.5px solid #05FFA1;
      display: none;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      text-align: center;
      padding: 12px;
      z-index: 2000;
      animation: pulsePop 0.8s infinite alternate;
    }
    .ancs-popup.sms {
      background: rgba(43, 31, 0, 0.98);
      border-color: #FFB800;
    }
    @keyframes pulsePop {
      from { box-shadow: 0 0 10px rgba(5,255,161,0.5); }
      to { box-shadow: 0 0 25px rgba(5,255,161,0.9); }
    }
    .popup-hdr {
      font-size: 0.85rem;
      font-weight: 900;
      color: #05FFA1;
      letter-spacing: 1px;
    }
    .ancs-popup.sms .popup-hdr { color: #FFB800; }
    .popup-title {
      font-size: 1.25rem;
      font-weight: 900;
      color: #fff;
      margin: 6px 0;
    }
    .popup-sub {
      font-size: 0.75rem;
      color: #cbd5e1;
    }

    /* Test Controls */
    .control-box {
      margin-top: 10px;
      width: 100%;
      max-width: 420px;
      background: #141B26;
      border: 1px solid #222F42;
      border-radius: 14px;
      padding: 10px;
    }
    .ctrl-title {
      font-size: 0.78rem;
      font-weight: 700;
      color: #94a3b8;
      margin-bottom: 6px;
    }
    .grid-btns {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 6px;
    }
    .btn {
      background: #1C2636;
      border: 1px solid #2E3E56;
      color: #fff;
      padding: 8px;
      border-radius: 8px;
      font-size: 0.72rem;
      font-weight: 600;
      cursor: pointer;
    }
    .btn:active { transform: scale(0.97); background: #2A3B54; }
    .btn.call { border-color: #05FFA1; color: #05FFA1; }
    .btn.sms { border-color: #FFB800; color: #FFB800; }
  </style>
</head>
<body>

  <header>
    <div class="header-title">
      <span>📺 Màn Hình ESP32 Smart Navigator</span>
    </div>
    <div class="status-row">
      <div class="pill">
        <div id="bleDot" class="dot"></div>
        <span id="bleText">BLE: Đang chờ iPhone...</span>
      </div>
      <div class="pill">
        <div class="dot active"></div>
        <span>Wi-Fi Hotspot (192.168.4.1)</span>
      </div>
    </div>
  </header>

  <!-- Physical Enclosure Mockup -->
  <div class="device-shell">
    <div class="hw-bar">
      <div id="hwBle" class="ble-tag">NO BLE</div>
      <div id="clockTxt">11:09</div>
      <div class="battery">100% 🔋</div>
    </div>

    <div class="screen-area">
      <!-- LEFT 50%: Pure Offline Map Canvas (Identical to Google Maps) -->
      <div class="map-box">
        <canvas id="mapCanvas"></canvas>
        <div class="map-live-tag">MAP LIVE</div>
      </div>

      <!-- RIGHT 50%: Navigation HUD -->
      <div class="hud-box">
        <div class="turn-row">
          <div class="turn-badge" id="turnIconBox">
            <svg viewBox="0 0 24 24" id="turnSvg">
              <path d="M12 2L4 10h5v10h6V10h5L12 2z"/>
            </svg>
          </div>
          <div class="turn-dist-col">
            <div class="dist-val" id="distTxt">410m</div>
            <div class="speed-val" id="speedTxt">38 km/h</div>
          </div>
        </div>

        <div class="street-card">
          <div class="street-name" id="streetTxt">P. NGUYEN CANH DI</div>
        </div>

        <div class="eta-card">
          <div>
            <div class="eta-left">DỰ KIẾN</div>
            <div class="eta-clock" id="arrivalTxt">11:09</div>
          </div>
          <div style="text-align: right;">
            <div class="eta-left" id="totalDistTxt">1.2 km</div>
            <div class="eta-mins" id="etaTxt">2 ph</div>
          </div>
        </div>
      </div>

      <!-- ANCS Call / SMS Alert Popup -->
      <div id="ancsPopup" class="ancs-popup">
        <div class="popup-hdr" id="popupHdr">CUOC GOI DEN</div>
        <div class="popup-title" id="popupTitle">NGUYEN VAN A</div>
        <div class="popup-sub" id="popupSub">iPhone Notification</div>
      </div>
    </div>
  </div>

  <!-- Interactive Controls -->
  <div class="control-box">
    <div class="ctrl-title">Thử Nghiệm Tính Năng (Test Controls)</div>
    <div class="grid-btns">
      <button class="btn" onclick="testNav(6, 410, 38, 'P. Nguyen Canh Di', 2, '11:09')">⬅️ Rẽ trái 410m</button>
      <button class="btn" onclick="testNav(2, 659, 42, 'Pho Nguyen Huu Tho', 2, '11:09')">➡️ Rẽ phải 659m</button>
      <button class="btn" onclick="testNav(0, 1200, 50, 'Duong Giai Phong', 10, '11:18')">⬆️ Đi thẳng 1.2km</button>
      <button class="btn" onclick="testNav(8, 80, 25, 'Vong Xuyen Big C', 1, '11:10')">🔄 Vòng xuyến 80m</button>
      <button class="btn call" onclick="testCall('Nguyen Van A')">📞 Test Cuộc Gọi Đến</button>
      <button class="btn sms" onclick="testSms('Me', 'Con ve nha an com nhe!')">💬 Test Tin Nhắn SMS</button>
    </div>
  </div>

  <script>
    // =========================================================================
    // 1. PURE OFFLINE HTML5 CANVAS REALISTIC MAP ENGINE (Zero CDN / No Internet)
    // =========================================================================
    const canvas = document.getElementById('mapCanvas');
    const ctx = canvas.getContext('2d');
    let mapOffset = 0;
    let turnAngle = -35; // Default left bend

    function resizeCanvas() {
      const rect = canvas.parentElement.getBoundingClientRect();
      canvas.width = rect.width * window.devicePixelRatio;
      canvas.height = rect.height * window.devicePixelRatio;
      ctx.scale(window.devicePixelRatio, window.devicePixelRatio);
    }
    window.addEventListener('resize', resizeCanvas);
    setTimeout(resizeCanvas, 50);

    function drawRealisticMap() {
      const w = canvas.width / window.devicePixelRatio;
      const h = canvas.height / window.devicePixelRatio;
      if (!w || !h) return;

      // 1. Background Landcover (Google Maps light slate style)
      ctx.fillStyle = '#E8ECEF';
      ctx.fillRect(0, 0, w, h);

      // 2. Realistic Building Blocks
      ctx.fillStyle = '#D9E0E6';
      ctx.fillRect(10, 15, w * 0.35, 45);
      ctx.fillRect(10, 70, w * 0.35, 55);
      ctx.fillRect(10, 135, w * 0.35, 60);

      ctx.fillRect(w * 0.65, 10, w * 0.3, 50);
      ctx.fillRect(w * 0.65, 70, w * 0.3, 60);
      ctx.fillRect(w * 0.65, 140, w * 0.3, 50);

      // 3. Minor Cross Streets
      ctx.strokeStyle = '#FFFFFF';
      ctx.lineWidth = 14;
      ctx.beginPath();
      ctx.moveTo(0, 65);
      ctx.lineTo(w, 65);
      ctx.moveTo(0, 130);
      ctx.lineTo(w, 130);
      ctx.stroke();

      // 4. Main Arterial Road (Center)
      ctx.strokeStyle = '#FFFFFF';
      ctx.lineWidth = 32;
      ctx.beginPath();
      ctx.moveTo(w * 0.5, h);
      ctx.lineTo(w * 0.5, 0);
      ctx.stroke();

      // 5. Active Cyan Navigation Route (With Glow)
      ctx.save();
      ctx.strokeStyle = '#0084FF';
      ctx.lineWidth = 10;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.shadowColor = 'rgba(0, 132, 255, 0.6)';
      ctx.shadowBlur = 8;

      ctx.beginPath();
      ctx.moveTo(w * 0.5, h + 20);
      ctx.lineTo(w * 0.5, h * 0.5);

      // Bend route line according to turn code
      const rad = (turnAngle * Math.PI) / 180;
      const targetX = (w * 0.5) + Math.sin(rad) * 90;
      const targetY = (h * 0.5) - Math.cos(rad) * 90;
      ctx.lineTo(targetX, targetY);
      ctx.stroke();
      ctx.restore();

      // 6. Street Name Labels on Map
      ctx.save();
      ctx.fillStyle = '#64748B';
      ctx.font = 'bold 9px sans-serif';
      ctx.translate(w * 0.5 - 6, h * 0.85);
      ctx.rotate(-Math.PI / 2);
      ctx.fillText(currentStreetDisplay, 0, 0);
      ctx.restore();

      // 7. Landmark Icons (Bus Stop / POI)
      ctx.fillStyle = '#3B82F6';
      ctx.beginPath();
      ctx.arc(20, h - 20, 6, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = '#fff';
      ctx.font = 'bold 8px sans-serif';
      ctx.fillText('B', 17, h - 17);

      // 8. Vehicle Position Marker (Always Strictly Centered)
      const cx = w * 0.5;
      const cy = h * 0.5;

      // Outer Pulse Ring
      ctx.fillStyle = 'rgba(0, 132, 255, 0.2)';
      ctx.beginPath();
      ctx.arc(cx, cy, 18, 0, Math.PI * 2);
      ctx.fill();

      // Inner Blue Circle
      ctx.fillStyle = '#0084FF';
      ctx.strokeStyle = '#FFFFFF';
      ctx.lineWidth = 2.5;
      ctx.beginPath();
      ctx.arc(cx, cy, 11, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();

      // Directional Heading Arrow
      ctx.save();
      ctx.translate(cx, cy);
      ctx.rotate(rad);
      ctx.fillStyle = '#FFFFFF';
      ctx.beginPath();
      ctx.moveTo(0, -6);
      ctx.lineTo(-4, 3);
      ctx.lineTo(4, 3);
      ctx.closePath();
      ctx.fill();
      ctx.restore();

      requestAnimationFrame(drawRealisticMap);
    }
    requestAnimationFrame(drawRealisticMap);

    let currentStreetDisplay = 'P. NGUYEN CANH DI';

    // =========================================================================
    // 2. HUD & Turn Icon SVGs
    // =========================================================================
    const turnIcons = {
      0: `<path d="M12 2L4 10h5v10h6V10h5L12 2z"/>`,
      1: `<path d="M14 4l-1.4 1.4 2.6 2.6H8c-2.2 0-4 1.8-4 4v6h2v-6c0-1.1.9-2 2-2h7.2l-2.6 2.6L14 18l6-7-6-7z"/>`,
      2: `<path d="M19 12l-7-7v4H6a2 2 0 0 0-2 2v9h4v-7h4v4l7-7z"/>`,
      3: `<path d="M19 12l-7-7v4H6a2 2 0 0 0-2 2v9h4v-7h4v4l7-7z"/>`,
      4: `<path d="M6 14v-4c0-3.3 2.7-6 6-6s6 2.7 6 6v7h2v-7c0-4.4-3.6-8-8-8s-8 3.6-8 8v4H1l4.5 5.5L10 14H6z"/>`,
      5: `<path d="M10 4l1.4 1.4-2.6 2.6H16c2.2 0 4 1.8 4 4v6h-2v-6c0-1.1-.9-2-2-2H8.8l2.6 2.6L10 18l-6-7 6-7z"/>`,
      6: `<path d="M5 12l7-7v4h6a2 2 0 0 1 2 2v9h-4v-7h-4v4l-7-7z"/>`,
      7: `<path d="M5 12l7-7v4h6a2 2 0 0 1 2 2v9h-4v-7h-4v4l-7-7z"/>`,
      8: `<path d="M12 2a10 10 0 1 0 10 10A10 10 0 0 0 12 2zm1 14.9V14h-2v2.9A8 8 0 0 1 4.1 11H7V9H4.1A8 8 0 0 1 11 4.1V7h2V4.1A8 8 0 0 1 19.9 11H17v2h2.9a8 8 0 0 1-6.9 3.9z"/>`,
      9: `<path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z"/>`
    };

    function updateUi(data) {
      // 1. BLE Status
      const bleDot = document.getElementById('bleDot');
      const bleText = document.getElementById('bleText');
      const hwBle = document.getElementById('hwBle');

      if (data.ble) {
        bleDot.className = 'dot active';
        bleText.innerText = 'iPhone Đã Kết Nối';
        hwBle.innerText = 'ESP32 BLE';
        hwBle.className = 'ble-tag connected';
      } else {
        bleDot.className = 'dot';
        bleText.innerText = 'BLE: Đang chờ iPhone...';
        hwBle.innerText = 'NO BLE';
        hwBle.className = 'ble-tag';
      }

      // 2. Metrics
      const distTxt = document.getElementById('distTxt');
      distTxt.innerText = data.dist >= 1000 ? (data.dist / 1000).toFixed(1) + 'km' : data.dist + 'm';
      document.getElementById('speedTxt').innerText = data.speed + ' km/h';
      
      const st = data.street || 'SAN SANG DAN DUONG';
      document.getElementById('streetTxt').innerText = st.toUpperCase();
      currentStreetDisplay = st;

      document.getElementById('arrivalTxt').innerText = data.arrival || '--:--';
      document.getElementById('etaTxt').innerText = data.eta + ' ph';
      
      if (data.tot_dist) {
        document.getElementById('totalDistTxt').innerText = (data.tot_dist / 1000).toFixed(1) + ' km';
      }

      // 3. Turn Arrow & Map Angle
      document.getElementById('turnSvg').innerHTML = turnIcons[data.turn] || turnIcons[0];
      if (data.turn === 2 || data.turn === 1 || data.turn === 3) turnAngle = 40;
      else if (data.turn === 6 || data.turn === 5 || data.turn === 7) turnAngle = -40;
      else turnAngle = 0;

      // 4. ANCS Popup
      const popup = document.getElementById('ancsPopup');
      if (data.popup && data.popup !== 'NONE') {
        popup.style.display = 'flex';
        popup.className = 'ancs-popup ' + (data.popup === 'CALL' ? 'call' : 'sms');
        document.getElementById('popupHdr').innerText = data.popup === 'CALL' ? 'CUOC GOI DEN' : 'SMS / ZALO';
        document.getElementById('popupTitle').innerText = data.title || 'THONG BAO';
        document.getElementById('popupSub').innerText = data.msg || 'iPhone Notification';
      } else {
        popup.style.display = 'none';
      }
    }

    // Clock
    setInterval(() => {
      const d = new Date();
      const h = String(d.getHours()).padStart(2, '0');
      const m = String(d.getMinutes()).padStart(2, '0');
      document.getElementById('clockTxt').innerText = `${h}:${m}`;
    }, 1000);

    // Live Polling
    async function pollStatus() {
      try {
        const res = await fetch('/api/status');
        if (res.ok) {
          const data = await res.json();
          updateUi(data);
        }
      } catch(e) {}
      setTimeout(pollStatus, 120);
    }
    pollStatus();

    // Handlers
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
// 2. Custom Navigation Characteristic Callback
// =========================================================================
class NavCharCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic) {
    std::string value = pCharacteristic->getValue();
    if (value.length() == 0) return;

    Serial.printf("[BLE RX]: %s\n", value.c_str());

    JsonDocument doc;
    DeserializationError error = deserializeJson(doc, value.c_str());

    if (!error) {
      // 1. Check for Direct Notification Packets from App
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

      // 2. Navigation Telemetry Payload
      curTurn = doc["turn"] | 0;
      curDist = doc["dist"] | 0;
      curTotalDist = doc["tot_dist"] | 0;
      curSpeed = doc["speed"] | 0;
      curEta = doc["eta"] | 0;
      curStreet = String(doc["street"] | "Tiep tuc");
      curArrival = String(doc["arrival"] | "--:--");
      if (doc["head"].is<int>()) curHeading = doc["head"];

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
  Serial.println("\n=== ESP32-S3 SMART NAVIGATOR INITIALIZING ===");

  // 1. Start Wi-Fi SoftAP
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);
  IPAddress IP = WiFi.softAPIP();
  Serial.printf("[WiFi AP] Hotspot: %s (Pass: %s)\n", AP_SSID, AP_PASS);
  Serial.printf("[WiFi AP] Live URL: http://%s\n", IP.toString().c_str());

  // 2. Start Web Server
  server.on("/", HTTP_GET, handleRoot);
  server.on("/api/status", HTTP_GET, handleStatusApi);
  server.on("/api/test", HTTP_GET, handleTestNav);
  server.on("/api/test_call", HTTP_GET, handleTestCall);
  server.on("/api/test_sms", HTTP_GET, handleTestSms);
  server.begin();

  // 3. Start Display (if hardware attached)
  display.init();

  // 4. Start NimBLE Server
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
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  Serial.println("[BLE] ESP32 da san sang!");
}

void loop() {
  server.handleClient();
  display.update();
  delay(10);
}
