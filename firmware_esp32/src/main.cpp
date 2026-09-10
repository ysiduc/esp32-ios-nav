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
static volatile size_t jpegFrameLen = 0;
static volatile unsigned long lastFrameTime = 0;
static uint8_t currentBleFrameId = 255;
static size_t bleJpegBytesReceived = 0;

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
volatile uint8_t curTurn = 6;
volatile uint16_t curDist = 410;
volatile uint16_t curTotalDist = 1200;
volatile uint8_t curSpeed = 38;
volatile uint8_t curEta = 2;
volatile int curHeading = 180;
String curStreet = "PHO DAI TU";
String curArrival = "11:17";

// ANCS / Notification State
String popupTitle = "";
String popupMsg = "";
String popupType = "NONE";
unsigned long popupExpire = 0;

// =========================================================================
// Web Page: Ultra-Realistic Google Maps Navigation + 20 FPS Stream Receiver
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
      gap: 6px;
      letter-spacing: 0.5px;
    }
    .status-row {
      display: flex;
      justify-content: center;
      gap: 8px;
      margin-top: 5px;
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
    }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: #64748b; }
    .dot.active { background: var(--accent-green); box-shadow: 0 0 8px var(--accent-green); }

    /* Physical ESP32 Screen Enclosure Mockup */
    .device-shell {
      position: relative;
      width: 100%;
      max-width: 420px;
      height: 260px;
      background: #1C232D;
      border-radius: 24px;
      border: 6px solid #2B3545;
      box-shadow: 0 16px 40px rgba(0,0,0,0.85);
      overflow: hidden;
      padding: 4px;
      display: flex;
      flex-direction: column;
    }

    /* Top Hardware Status Bar */
    .hw-bar {
      height: 22px;
      background: rgba(10, 14, 22, 0.95);
      border-radius: 8px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 10px;
      font-size: 0.68rem;
      font-family: monospace;
      font-weight: bold;
      margin-bottom: 4px;
      z-index: 100;
    }
    .ble-tag { color: #ff5555; }
    .ble-tag.connected { color: var(--accent); }
    .battery { color: var(--accent-green); }

    /* Screen Area */
    .screen-area {
      flex: 1;
      position: relative;
      background: #000;
      border-radius: 12px;
      overflow: hidden;
      display: flex;
    }

    /* Direct Camera / App Image Stream */
    #realAppImg {
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      object-fit: fill;
      display: none;
      z-index: 50;
      border-radius: 8px;
    }

    /* Split 50/50 Screen Layout */
    .split-layout {
      width: 100%;
      height: 100%;
      display: flex;
      gap: 6px;
      padding: 4px;
      transition: opacity 0.2s ease;
    }

    /* LEFT 50%: Ultra-Realistic Vector Google Maps */
    .map-box {
      flex: 1;
      height: 100%;
      border-radius: 10px;
      overflow: hidden;
      border: 1.5px solid rgba(0, 240, 255, 0.35);
      position: relative;
      background: #e5e3df;
    }
    #mapCanvas {
      width: 100%;
      height: 100%;
      display: block;
    }
    .map-live-tag {
      position: absolute;
      bottom: 5px;
      left: 5px;
      background: rgba(15, 23, 42, 0.85);
      color: var(--accent);
      font-size: 0.58rem;
      font-family: monospace;
      font-weight: 800;
      padding: 2px 6px;
      border-radius: 4px;
      border: 1px solid rgba(0, 240, 255, 0.3);
      z-index: 10;
      display: flex;
      align-items: center;
      gap: 4px;
    }
    .map-compass {
      position: absolute;
      top: 5px;
      right: 5px;
      background: rgba(15, 23, 42, 0.85);
      color: #fff;
      font-size: 0.6rem;
      font-weight: 900;
      width: 20px;
      height: 20px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      border: 1px solid rgba(255,255,255,0.2);
      z-index: 10;
    }
    .speed-limit-badge {
      position: absolute;
      top: 5px;
      left: 5px;
      width: 22px;
      height: 22px;
      border-radius: 50%;
      background: #fff;
      border: 2.5px solid #ef4444;
      color: #000;
      font-size: 0.6rem;
      font-weight: 900;
      display: flex;
      align-items: center;
      justify-content: center;
      font-family: sans-serif;
      z-index: 10;
      box-shadow: 0 2px 4px rgba(0,0,0,0.3);
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

    .turn-row {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .turn-badge {
      width: 44px;
      height: 44px;
      background: rgba(0, 240, 255, 0.15);
      border: 1.5px solid var(--accent);
      border-radius: 10px;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .turn-badge svg {
      width: 30px;
      height: 30px;
      fill: var(--accent);
    }
    .turn-dist-col {
      display: flex;
      flex-direction: column;
    }
    .dist-val {
      font-size: 1.35rem;
      font-weight: 900;
      font-family: monospace;
      color: #ffffff;
      line-height: 1;
    }
    .speed-val {
      font-size: 0.78rem;
      font-weight: 800;
      font-family: monospace;
      color: var(--accent-green);
      margin-top: 3px;
    }

    .street-card {
      background: #0D131C;
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 6px;
      padding: 5px 6px;
      text-align: center;
    }
    .street-name {
      font-size: 0.78rem;
      font-weight: 800;
      color: var(--gold);
      font-family: monospace;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      text-transform: uppercase;
    }

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
    .eta-clock { color: var(--accent); font-weight: bold; font-size: 0.82rem; }
    .eta-mins { color: var(--accent-green); font-weight: bold; font-size: 0.82rem; }

    /* ANCS Popup Overlay */
    .ancs-popup {
      position: absolute;
      inset: 4px;
      background: rgba(6, 44, 30, 0.98);
      border-radius: 12px;
      border: 2.5px solid var(--accent-green);
      display: none;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      text-align: center;
      padding: 12px;
      z-index: 2000;
      box-shadow: 0 0 30px rgba(5,255,161,0.8);
      animation: popIn 0.3s cubic-bezier(0.175, 0.885, 0.32, 1.275);
    }
    @keyframes popIn {
      from { transform: scale(0.85); opacity: 0; }
      to { transform: scale(1); opacity: 1; }
    }
    .ancs-popup.sms {
      background: rgba(44, 32, 4, 0.98);
      border-color: var(--gold);
      box-shadow: 0 0 30px rgba(255,184,0,0.8);
    }
    .popup-hdr {
      font-size: 0.85rem;
      font-weight: 900;
      color: var(--accent-green);
      letter-spacing: 1px;
    }
    .ancs-popup.sms .popup-hdr { color: var(--gold); }
    .popup-title {
      font-size: 1.3rem;
      font-weight: 900;
      color: #fff;
      margin: 6px 0;
    }
    .popup-sub {
      font-size: 0.78rem;
      color: #cbd5e1;
    }

    /* Test Controls Dashboard */
    .control-box {
      margin-top: 12px;
      width: 100%;
      max-width: 420px;
      background: #141B26;
      border: 1px solid #222F42;
      border-radius: 14px;
      padding: 12px;
    }
    .ctrl-title {
      font-size: 0.8rem;
      font-weight: 700;
      color: #94a3b8;
      margin-bottom: 8px;
      display: flex;
      justify-content: space-between;
      align-items: center;
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
      padding: 9px;
      border-radius: 8px;
      font-size: 0.75rem;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.15s ease;
    }
    .btn:active { transform: scale(0.96); background: #2A3B54; }
    .btn.call { border-color: var(--accent-green); color: var(--accent-green); }
    .btn.sms { border-color: var(--gold); color: var(--gold); }
    .btn.theme { grid-column: span 2; border-color: #38bdf8; color: #38bdf8; margin-top: 4px; }
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

  <!-- Physical Screen Enclosure Mockup -->
  <div class="device-shell">
    <div class="hw-bar">
      <div id="hwBle" class="ble-tag">NO BLE</div>
      <div id="clockTxt">11:17</div>
      <div class="battery">100% 🔋</div>
    </div>

    <div class="screen-area">
      <!-- 1. Real Google Maps Stream from iOS App -->
      <img id="realAppImg" alt="Live App Stream" />

      <!-- 2. Split 50/50 Screen Layout (Ultra-Realistic Vector Map Engine) -->
      <div class="split-layout" id="splitLayout">
        <!-- LEFT 50%: Live Vector Map Canvas -->
        <div class="map-box">
          <canvas id="mapCanvas"></canvas>
          <div class="map-live-tag">
            <span style="display:inline-block;width:5px;height:5px;background:#00F0FF;border-radius:50%"></span>
            MAP LIVE
          </div>
          <div class="map-compass">N</div>
          <div class="speed-limit-badge">50</div>
        </div>

        <!-- RIGHT 50%: Navigation HUD -->
        <div class="hud-box">
          <div class="turn-row">
            <div class="turn-badge" id="turnIconBox">
              <svg viewBox="0 0 24 24" id="turnSvg">
                <path d="M5 12l7-7v4h6a2 2 0 0 1 2 2v9h-4v-7h-4v4l-7-7z"/>
              </svg>
            </div>
            <div class="turn-dist-col">
              <div class="dist-val" id="distTxt">410m</div>
              <div class="speed-val" id="speedTxt">38 km/h</div>
            </div>
          </div>

          <div class="street-card">
            <div class="street-name" id="streetTxt">PHỐ ĐẠI TỪ</div>
          </div>

          <div class="eta-card">
            <div>
              <div class="eta-left">DỰ KIẾN</div>
              <div class="eta-clock" id="arrivalTxt">11:17</div>
            </div>
            <div style="text-align: right;">
              <div class="eta-left" id="totalDistTxt">0.7 km</div>
              <div class="eta-mins" id="etaTxt">1 ph</div>
            </div>
          </div>
        </div>
      </div>

      <!-- ANCS Call / SMS Alert Popup -->
      <div id="ancsPopup" class="ancs-popup">
        <div class="popup-hdr" id="popupHdr">CUỘC GỌI ĐẾN</div>
        <div class="popup-title" id="popupTitle">NGUYỄN VĂN A</div>
        <div class="popup-sub" id="popupSub">iPhone Notification</div>
      </div>
    </div>
  </div>

  <!-- Interactive Controls Dashboard -->
  <div class="control-box">
    <div class="ctrl-title">
      <span>Thử Nghiệm Tính Năng (Test Controls)</span>
      <span id="streamIndicator" style="font-size: 0.72rem; color: #00F0FF;">Vector HD Map Active</span>
    </div>
    <div class="grid-btns">
      <button class="btn" onclick="testNav(6, 410, 38, 'Phố Đại Từ', 1, '11:17')">⬅️ Rẽ trái 410m</button>
      <button class="btn" onclick="testNav(2, 659, 42, 'Nguyễn Hữu Thọ', 2, '11:18')">➡️ Rẽ phải 659m</button>
      <button class="btn" onclick="testNav(0, 1200, 50, 'Đường Giải Phóng', 5, '11:22')">⬆️ Đi thẳng 1.2km</button>
      <button class="btn" onclick="testNav(8, 80, 25, 'Bán Đảo Linh Đàm', 1, '11:17')">🔄 Vòng xuyến 80m</button>
      <button class="btn call" onclick="testCall('Nguyễn Văn A')">📞 Test Cuộc Gọi Đến</button>
      <button class="btn sms" onclick="testSms('Mẹ', 'Con về nhà ăn cơm nhé!')">💬 Test Tin Nhắn SMS</button>
      <button class="btn theme" onclick="toggleMapTheme()">🌓 Chuyển Chế Độ Ngày / Đêm Google Maps</button>
    </div>
  </div>

  <script>
    // 1. High-Speed Live Stream Receiver
    const realAppImg = document.getElementById('realAppImg');
    const splitLayout = document.getElementById('splitLayout');
    const streamIndicator = document.getElementById('streamIndicator');
    let streamActive = false;

    function refreshLiveStream() {
      const testImg = new Image();
      testImg.src = '/api/frame.jpg?t=' + Date.now();
      testImg.onload = function() {
        realAppImg.src = testImg.src;
        realAppImg.style.display = 'block';
        splitLayout.style.opacity = '0';
        if (!streamActive) {
          streamIndicator.innerText = 'STREAMING 20 FPS ⚡';
          streamIndicator.style.color = '#05FFA1';
          streamActive = true;
        }
      };
      testImg.onerror = function() {
        if (streamActive) {
          realAppImg.style.display = 'none';
          splitLayout.style.opacity = '1';
          streamIndicator.innerText = 'Vector HD Map Active';
          streamIndicator.style.color = '#00F0FF';
          streamActive = false;
        }
      };
    }
    setInterval(refreshLiveStream, 60);

    // 2. Ultra-Realistic Google Maps Vector Rendering Engine
    const canvas = document.getElementById('mapCanvas');
    const ctx = canvas.getContext('2d');
    let isDarkMode = false;
    let targetTurnAngle = -45;
    let currentTurnAngle = -45;
    let currentStreetDisplay = 'PHỐ ĐẠI TỪ';
    let animPhase = 0;

    function toggleMapTheme() {
      isDarkMode = !isDarkMode;
    }

    function resizeCanvas() {
      const rect = canvas.parentElement.getBoundingClientRect();
      canvas.width = rect.width * (window.devicePixelRatio || 1);
      canvas.height = rect.height * (window.devicePixelRatio || 1);
      ctx.scale(window.devicePixelRatio || 1, window.devicePixelRatio || 1);
    }
    window.addEventListener('resize', resizeCanvas);
    setTimeout(resizeCanvas, 50);

    function renderGoogleMapsVector() {
      const dpr = window.devicePixelRatio || 1;
      const w = canvas.width / dpr;
      const h = canvas.height / dpr;
      if (!w || !h) {
        requestAnimationFrame(renderGoogleMapsVector);
        return;
      }

      animPhase = (animPhase + 0.05) % 1.0;
      currentTurnAngle += (targetTurnAngle - currentTurnAngle) * 0.1;

      // Color Palettes (Google Maps Day vs Night)
      const colors = isDarkMode ? {
        land: '#1f2937',
        water: '#0e304f',
        park: '#133a27',
        buildingTop: '#2d3748',
        buildingSide: '#1a202c',
        roadMajor: '#384656',
        roadMinor: '#273444',
        roadBorder: '#111827',
        yellowLine: '#eab308',
        text: '#94a3b8',
        routeMain: '#3b82f6',
        routeGlow: 'rgba(59, 130, 246, 0.6)',
        routeInner: '#93c5fd'
      } : {
        land: '#f2efe9',
        water: '#aad5df',
        park: '#cce6c7',
        buildingTop: '#e8e6dc',
        buildingSide: '#d5d3c8',
        roadMajor: '#ffffff',
        roadMinor: '#ffffff',
        roadBorder: '#d6d3cc',
        yellowLine: '#fbc02d',
        text: '#64748b',
        routeMain: '#3b82f6',
        routeGlow: 'rgba(59, 130, 246, 0.6)',
        routeInner: '#bfdbfe'
      };

      // 1. Land Background
      ctx.fillStyle = colors.land;
      ctx.fillRect(0, 0, w, h);

      // 2. Water / Lake Feature (Curved organic body on right)
      ctx.fillStyle = colors.water;
      ctx.beginPath();
      ctx.moveTo(w * 0.75, 0);
      ctx.bezierCurveTo(w * 0.65, h * 0.3, w * 0.85, h * 0.6, w * 0.7, h);
      ctx.lineTo(w, h);
      ctx.lineTo(w, 0);
      ctx.closePath();
      ctx.fill();

      // 3. Park / Green Spaces
      ctx.fillStyle = colors.park;
      ctx.beginPath();
      ctx.roundRect(8, 8, w * 0.32, h * 0.28, 8);
      ctx.fill();

      ctx.beginPath();
      ctx.roundRect(8, h * 0.68, w * 0.32, h * 0.28, 8);
      ctx.fill();

      // 4. Realistic 3D Building Polygons with Depth Shadows
      function draw3dBuilding(bx, by, bw, bh) {
        // Shadow / Side
        ctx.fillStyle = colors.buildingSide;
        ctx.fillRect(bx + 2, by + 2, bw, bh);
        // Roof Top
        ctx.fillStyle = colors.buildingTop;
        ctx.fillRect(bx, by, bw, bh);
        ctx.strokeStyle = colors.roadBorder;
        ctx.lineWidth = 0.5;
        ctx.strokeRect(bx, by, bw, bh);
      }

      draw3dBuilding(12, h * 0.4, w * 0.28, 22);
      draw3dBuilding(12, h * 0.52, w * 0.28, 26);
      draw3dBuilding(w * 0.68, h * 0.12, 38, 28);
      draw3dBuilding(w * 0.72, h * 0.72, 34, 34);

      // 5. Secondary Roads / Side Streets
      ctx.strokeStyle = colors.roadBorder;
      ctx.lineWidth = 18;
      ctx.beginPath();
      ctx.moveTo(0, h * 0.38); ctx.lineTo(w, h * 0.38);
      ctx.moveTo(0, h * 0.66); ctx.lineTo(w, h * 0.66);
      ctx.stroke();

      ctx.strokeStyle = colors.roadMinor;
      ctx.lineWidth = 14;
      ctx.beginPath();
      ctx.moveTo(0, h * 0.38); ctx.lineTo(w, h * 0.38);
      ctx.moveTo(0, h * 0.66); ctx.lineTo(w, h * 0.66);
      ctx.stroke();

      // 6. Arterial Highway / Main Avenue
      ctx.strokeStyle = colors.roadBorder;
      ctx.lineWidth = 32;
      ctx.beginPath();
      ctx.moveTo(w * 0.48, h);
      ctx.lineTo(w * 0.48, 0);
      ctx.stroke();

      ctx.strokeStyle = colors.roadMajor;
      ctx.lineWidth = 28;
      ctx.beginPath();
      ctx.moveTo(w * 0.48, h);
      ctx.lineTo(w * 0.48, 0);
      ctx.stroke();

      // Highway Center Yellow Dashed Divider Line
      ctx.strokeStyle = colors.yellowLine;
      ctx.lineWidth = 1.5;
      ctx.setLineDash([5, 4]);
      ctx.beginPath();
      ctx.moveTo(w * 0.48, h);
      ctx.lineTo(w * 0.48, 0);
      ctx.stroke();
      ctx.setLineDash([]);

      // Zebra Crosswalks at Intersections
      ctx.strokeStyle = isDarkMode ? '#475569' : '#e2e8f0';
      ctx.lineWidth = 2;
      for (let i = 0; i < 6; i++) {
        let x = w * 0.38 + i * 4;
        ctx.beginPath();
        ctx.moveTo(x, h * 0.36); ctx.lineTo(x, h * 0.40);
        ctx.stroke();
      }

      // 7. Active Navigation Route Polyline (Google Navigation Blue)
      ctx.save();
      ctx.strokeStyle = colors.routeMain;
      ctx.lineWidth = 9;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.shadowColor = colors.routeGlow;
      ctx.shadowBlur = 8;

      ctx.beginPath();
      ctx.moveTo(w * 0.48, h + 5);
      ctx.lineTo(w * 0.48, h * 0.5);

      const rad = (currentTurnAngle * Math.PI) / 180;
      const targetX = (w * 0.48) + Math.sin(rad) * 90;
      const targetY = (h * 0.5) - Math.cos(rad) * 90;
      ctx.lineTo(targetX, targetY);
      ctx.stroke();

      // Inner Core Line
      ctx.shadowBlur = 0;
      ctx.strokeStyle = colors.routeInner;
      ctx.lineWidth = 3;
      ctx.stroke();
      ctx.restore();

      // Animated Forward-Flowing Chevrons (>>>)
      ctx.save();
      ctx.fillStyle = '#ffffff';
      for (let k = 0; k < 3; k++) {
        let frac = (animPhase + k * 0.33) % 1.0;
        let px = w * 0.48;
        let py = h * 0.9 - frac * (h * 0.35);
        ctx.beginPath();
        ctx.moveTo(px - 3, py + 2);
        ctx.lineTo(px, py - 2);
        ctx.lineTo(px + 3, py + 2);
        ctx.lineWidth = 1.5;
        ctx.strokeStyle = '#ffffff';
        ctx.stroke();
      }
      ctx.restore();

      // Street Name Labels along Road
      ctx.save();
      ctx.fillStyle = colors.text;
      ctx.font = 'bold 8px sans-serif';
      ctx.translate(w * 0.48 - 6, h * 0.88);
      ctx.rotate(-Math.PI / 2);
      ctx.fillText(currentStreetDisplay, 0, 0);
      ctx.restore();

      // 8. 3D Vehicle Marker (Google Maps Location Puck)
      const cx = w * 0.48;
      const cy = h * 0.5;

      // Radar Pulse Halo
      ctx.fillStyle = 'rgba(59, 130, 246, ' + (0.35 * (1 - animPhase)) + ')';
      ctx.beginPath();
      ctx.arc(cx, cy, 12 + animPhase * 16, 0, Math.PI * 2);
      ctx.fill();

      // Blue Puck with White Border
      ctx.fillStyle = '#3b82f6';
      ctx.strokeStyle = '#ffffff';
      ctx.lineWidth = 2.5;
      ctx.beginPath();
      ctx.arc(cx, cy, 9, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();

      // Directional Heading Arrow
      ctx.save();
      ctx.translate(cx, cy);
      ctx.rotate(rad);
      ctx.fillStyle = '#ffffff';
      ctx.beginPath();
      ctx.moveTo(0, -5.5);
      ctx.lineTo(-4, 3.5);
      ctx.lineTo(0, 1.5);
      ctx.lineTo(4, 3.5);
      ctx.closePath();
      ctx.fill();
      ctx.restore();

      requestAnimationFrame(renderGoogleMapsVector);
    }
    requestAnimationFrame(renderGoogleMapsVector);

    // SVG Turn Icons
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

      const distTxt = document.getElementById('distTxt');
      distTxt.innerText = data.dist >= 1000 ? (data.dist / 1000).toFixed(1) + 'km' : data.dist + 'm';
      document.getElementById('speedTxt').innerText = data.speed + ' km/h';

      const st = data.street || 'PHỐ ĐẠI TỪ';
      document.getElementById('streetTxt').innerText = st.toUpperCase();
      currentStreetDisplay = st.toUpperCase();

      document.getElementById('arrivalTxt').innerText = data.arrival || '11:17';
      document.getElementById('etaTxt').innerText = (data.eta || 1) + ' ph';

      if (data.tot_dist) {
        document.getElementById('totalDistTxt').innerText = (data.tot_dist / 1000).toFixed(1) + ' km';
      }

      document.getElementById('turnSvg').innerHTML = turnIcons[data.turn] || turnIcons[6];

      if (data.turn === 2 || data.turn === 1 || data.turn === 3) targetTurnAngle = 45;
      else if (data.turn === 6 || data.turn === 5 || data.turn === 7) targetTurnAngle = -45;
      else if (data.turn === 4) targetTurnAngle = -170;
      else if (data.turn === 8) targetTurnAngle = 90;
      else targetTurnAngle = 0;

      const popup = document.getElementById('ancsPopup');
      if (data.popup && data.popup !== 'NONE') {
        popup.style.display = 'flex';
        popup.className = 'ancs-popup ' + (data.popup === 'CALL' ? 'call' : 'sms');
        document.getElementById('popupHdr').innerText = data.popup === 'CALL' ? 'CUỘC GỌI ĐẾN' : 'SMS / ZALO';
        document.getElementById('popupTitle').innerText = data.title || 'THÔNG BÁO';
        document.getElementById('popupSub').innerText = data.msg || 'iPhone Notification';
      } else {
        popup.style.display = 'none';
      }
    }

    setInterval(() => {
      const d = new Date();
      document.getElementById('clockTxt').innerText = String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
    }, 1000);

    async function pollStatus() {
      try {
        const res = await fetch('/api/status');
        if (res.ok) {
          const data = await res.json();
          updateUi(data);
        }
      } catch(e) {}
      setTimeout(pollStatus, 150);
    }
    pollStatus();

    function testNav(turn, dist, speed, street, eta, arrival) {
      updateUi({
        ble: true,
        turn: turn,
        dist: dist,
        speed: speed,
        street: street,
        eta: eta,
        arrival: arrival,
        tot_dist: dist + 300,
        popup: 'NONE'
      });
      fetch(`/api/test?turn=${turn}&dist=${dist}&speed=${speed}&street=${encodeURIComponent(street)}&eta=${eta}&arrival=${arrival}`);
    }

    function testCall(name) {
      updateUi({
        ble: true,
        turn: 6,
        dist: 410,
        speed: 38,
        street: 'PHỐ ĐẠI TỪ',
        eta: 1,
        arrival: '11:17',
        popup: 'CALL',
        title: name,
        msg: 'Cuộc gọi đến từ iPhone'
      });
      fetch(`/api/test_call?name=${encodeURIComponent(name)}`);
      setTimeout(() => {
        const p = document.getElementById('ancsPopup');
        if (p) p.style.display = 'none';
      }, 7000);
    }

    function testSms(sender, msg) {
      updateUi({
        ble: true,
        turn: 6,
        dist: 410,
        speed: 38,
        street: 'PHỐ ĐẠI TỪ',
        eta: 1,
        arrival: '11:17',
        popup: 'SMS',
        title: sender,
        msg: msg
      });
      fetch(`/api/test_sms?sender=${encodeURIComponent(sender)}&msg=${encodeURIComponent(msg)}`);
      setTimeout(() => {
        const p = document.getElementById('ancsPopup');
        if (p) p.style.display = 'none';
      }, 6000);
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

// Receive Direct 20-30 FPS High-Speed JPEG Image from iPhone
void handlePostFrame() {
  WiFiClient client = server.client();
  int contentLength = server.header("Content-Length").toInt();
  if (contentLength > 0 && contentLength < (int)sizeof(jpegFrameBuf)) {
    size_t readBytes = 0;
    unsigned long t0 = millis();
    while (readBytes < (size_t)contentLength && (millis() - t0 < 300)) {
      while (client.available() && readBytes < (size_t)contentLength) {
        jpegFrameBuf[readBytes++] = client.read();
      }
    }
    if (readBytes > 100) {
      jpegFrameLen = readBytes;
      lastFrameTime = millis();
      #if defined(DISPLAY_TFT_ST7789)
      TJpgDec.drawJpg(0, 0, jpegFrameBuf, jpegFrameLen);
      #endif
    }
  }
  server.send(200, "text/plain", "OK");
}

void handleGetFrame() {
  if (jpegFrameLen > 100 && (millis() - lastFrameTime < 6000)) {
    server.sendHeader("Cache-Control", "no-cache, no-store, must-revalidate");
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

    // 1. Check for Binary Chunked JPEG Packet (Magic 0xAA 0xBB from iPhone Stream)
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
        memcpy(jpegFrameBuf + bleJpegBytesReceived, value.data() + 5, payloadLen);
        bleJpegBytesReceived += payloadLen;
      }

      if (chunkIdx == totalChunks - 1 && bleJpegBytesReceived > 100) {
        jpegFrameLen = bleJpegBytesReceived;
        lastFrameTime = millis();
        #if defined(DISPLAY_TFT_ST7789)
        TJpgDec.drawJpg(0, 0, jpegFrameBuf, jpegFrameLen);
        #endif
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
  Serial.println("\n=== ESP32-S3 SMART NAVIGATOR WITH GOOGLE MAPS ENGINE ===");

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

  Serial.println("[BLE] ESP32 da san sang nhan luong 20 FPS!");
}

void loop() {
  server.handleClient();
  display.update();
  delay(2);
}
