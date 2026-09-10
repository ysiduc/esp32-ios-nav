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
#include <TJpg_Decoder.h>
bool tft_output(int16_t x, int16_t y, uint16_t w, uint16_t h, uint16_t* bitmap) {
  if (y >= tft.height()) return 0;
  tft.pushImage(x, y, w, h, bitmap);
  return 1;
}
#endif

DisplayManager display;
NimBLEServer* pServer = nullptr;
NimBLECharacteristic* pNavChar = nullptr;

// Navigation & Telemetry State
volatile bool bleConnected = false;
volatile uint8_t curTurn = 2; // Right turn
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
    }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: #64748b; }
    .dot.active { background: var(--accent-green); box-shadow: 0 0 8px var(--accent-green); }

    /* Physical ESP32 Screen Enclosure Mockup (Exact 1:1 match to Image 2) */
    .device-shell {
      position: relative;
      width: 100%;
      max-width: 420px;
      height: 255px;
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
      font-size: 0.7rem;
      font-family: monospace;
      font-weight: bold;
      margin-bottom: 4px;
      z-index: 100;
    }
    .ble-tag {
      color: #ff5555;
      display: flex;
      align-items: center;
      gap: 4px;
    }
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

    /* Direct Map Image Stream (Only placed inside left 50% map box) */
    #realAppImg {
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      object-fit: cover;
      display: none;
      z-index: 5;
    }

    /* Split 50/50 Screen Layout (Exact match to iOS App Simulation) */
    .split-layout {
      width: 100%;
      height: 100%;
      display: flex;
      gap: 6px;
      padding: 4px;
      transition: opacity 0.2s ease;
    }

    /* LEFT 50%: Real Google Maps Stream from iOS OR Vector Map */
    .map-box {
      flex: 1;
      height: 100%;
      border-radius: 10px;
      overflow: hidden;
      border: 1.5px solid rgba(0, 240, 255, 0.3);
      position: relative;
      background: #edf2f7;
    }
    #mapCanvas {
      width: 100%;
      height: 100%;
      display: block;
    }
    .map-live-tag {
      position: absolute;
      bottom: 6px;
      left: 6px;
      background: rgba(0, 0, 0, 0.85);
      color: #ffffff;
      font-size: 0.58rem;
      font-family: monospace;
      font-weight: 800;
      padding: 2px 6px;
      border-radius: 4px;
      border: 1px solid rgba(255, 255, 255, 0.15);
      z-index: 10;
      letter-spacing: 0.5px;
    }

    /* RIGHT 50%: Navigation HUD Box */
    .hud-box {
      flex: 1;
      height: 100%;
      background: #0C1017;
      border-radius: 10px;
      border: 1px solid rgba(255,255,255,0.06);
      padding: 8px 10px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
    }

    .turn-row {
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .turn-badge {
      width: 44px;
      height: 44px;
      background: rgba(0, 240, 255, 0.12);
      border: 1.5px solid var(--accent);
      border-radius: 10px;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .turn-badge svg {
      width: 28px;
      height: 28px;
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
      line-height: 1.1;
    }
    .speed-val {
      font-size: 0.78rem;
      font-weight: 800;
      font-family: monospace;
      color: var(--accent-green);
      margin-top: 2px;
    }

    .street-card {
      background: #0E141E;
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 6px;
      padding: 6px;
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
      letter-spacing: 0.5px;
    }

    .eta-card {
      background: #0A0E16;
      border-radius: 6px;
      padding: 5px 8px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-family: monospace;
    }
    .eta-left { font-size: 0.65rem; color: #64748b; font-weight: bold; }
    .eta-clock { color: var(--accent); font-weight: bold; font-size: 0.82rem; }
    .eta-mins { color: var(--accent-green); font-weight: bold; font-size: 0.82rem; }

    /* ANCS Notification Popup Overlay */
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

  <!-- Physical Screen Enclosure Mockup (Image 2) -->
  <div class="device-shell">
    <div class="hw-bar">
      <div id="hwBle" class="ble-tag connected">
        <svg viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="M17.71 7.71L12 2h-1v7.59L6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 11 14.41V22h1l5.71-5.71-4.3-4.29 4.3-4zm-4.71-1.3l2.59 2.59L13 11.59V6.41zm0 11.18v-5.18l2.59 2.59-2.59 2.59z"/></svg>
        <span>ESP32 BLE</span>
      </div>
      <div id="clockTxt">11:24</div>
      <div class="battery">100% 🔋</div>
    </div>

    <div class="screen-area">
      <!-- Split 50/50 Screen Layout (Image 2 Exact Layout) -->
      <div class="split-layout" id="splitLayout">
        <!-- LEFT 50%: Real Google Maps Stream from iOS OR Vector Map -->
        <div class="map-box">
          <canvas id="mapCanvas"></canvas>
          <img id="realAppImg" alt="Live Map Stream" />
          <div class="map-live-tag">MAP LIVE</div>
        </div>

        <!-- RIGHT 50%: Navigation HUD -->
        <div class="hud-box">
          <div class="turn-row">
            <div class="turn-badge" id="turnIconBox">
              <svg viewBox="0 0 24 24" id="turnSvg">
                <path d="M19 12l-7-7v4H6a2 2 0 0 0-2 2v9h4v-7h4v4l7-7z"/>
              </svg>
            </div>
            <div class="turn-dist-col">
              <div class="dist-val" id="distTxt">595m</div>
              <div class="speed-val" id="speedTxt">0 km/h</div>
            </div>
          </div>

          <div class="street-card">
            <div class="street-name" id="streetTxt">PHÓ ĐẠI TỪ</div>
          </div>

          <div class="eta-card">
            <div>
              <div class="eta-left">DỰ KIẾN</div>
              <div class="eta-clock" id="arrivalTxt">11:25</div>
            </div>
            <div style="text-align: right;">
              <div class="eta-left">THỜI GIAN</div>
              <div class="eta-mins" id="etaTxt">1 ph</div>
            </div>
          </div>

          <div style="display: flex; justify-content: space-between; font-size: 0.62rem; color: #64748b; font-family: monospace; font-weight: bold; padding: 0 2px;">
            <span>QUÃNG ĐƯỜNG</span>
            <span id="totalDistTxt" style="color: var(--accent);">0.7 km</span>
          </div>
        </div>
      </div>

      <!-- ANCS Incoming Call / SMS Notification Popup -->
      <div class="ancs-popup" id="ancsPopup">
        <div class="popup-hdr" id="popupHdr">CUỘC GỌI ĐẾN</div>
        <div class="popup-title" id="popupTitle">Nguyễn Văn A</div>
        <div class="popup-sub" id="popupSub">iPhone Notification</div>
      </div>
    </div>
  </div>

  <!-- Test Controls Dashboard -->
  <div class="control-box">
    <div class="ctrl-title">
      <span>⚙️ Trạng Thái Luồng Map & Thử Nghiệm</span>
      <span id="streamIndicator" style="color: #00F0FF; font-size: 0.72rem;">Chế độ: Bản đồ Vector & HUD BLE</span>
    </div>
    <div class="grid-btns">
      <button class="btn" onclick="testNav(2, 595, 0, 'Phố Đại Từ', 1, '11:25')">➡️ Rẽ phải 595m (Mặc định)</button>
      <button class="btn" onclick="testNav(6, 410, 38, 'Phố Đại Từ', 1, '11:25')">⬅️ Rẽ trái 410m</button>
      <button class="btn" onclick="testNav(0, 1200, 50, 'Đường Giải Phóng', 5, '11:30')">⬆️ Đi thẳng 1.2km</button>
      <button class="btn" onclick="testNav(8, 80, 25, 'Bán Đảo Linh Đàm', 1, '11:26')">🔄 Vòng xuyến 80m</button>
      <button class="btn call" onclick="testCall('Nguyễn Văn A')">📞 Test Cuộc Gọi Đến</button>
      <button class="btn sms" onclick="testSms('Mẹ', 'Con về nhà ăn cơm nhé!')">💬 Test Tin Nhắn SMS</button>
    </div>
  </div>

  <script>
    // 1. High-Speed Live Map Stream Receiver (Only displays on Left 50% map-box)
    const realAppImg = document.getElementById('realAppImg');
    const streamIndicator = document.getElementById('streamIndicator');
    let streamActive = false;
    let lastFrameReceived = 0;

    function refreshLiveStream() {
      const testImg = new Image();
      testImg.src = '/api/frame.jpg?t=' + Date.now();
      testImg.onload = function() {
        realAppImg.src = testImg.src;
        realAppImg.style.display = 'block';
        lastFrameReceived = Date.now();
        if (!streamActive) {
          streamIndicator.innerText = '🔴 LIVE: Đang nhận JPEG Map 20 FPS ⚡';
          streamIndicator.style.color = '#05FFA1';
          streamActive = true;
        }
      };
      testImg.onerror = function() {
        if (streamActive && (Date.now() - lastFrameReceived > 2500)) {
          realAppImg.style.display = 'none';
          streamIndicator.innerText = '🗺️ Chế độ: Bản đồ Vector & HUD BLE (Tiết kiệm pin / Khóa màn hình)';
          streamIndicator.style.color = '#00F0FF';
          streamActive = false;
        }
      };
    }
    setInterval(refreshLiveStream, 50);

    // 2. OpenStreetMap Authentic Vector Map Engine (100% Identical to Image 2)
    const canvas = document.getElementById('mapCanvas');
    const ctx = canvas.getContext('2d');
    let targetTurn = 2; // Right turn default
    let pulseVal = 0;

    function resizeCanvas() {
      const rect = canvas.parentElement.getBoundingClientRect();
      canvas.width = rect.width * (window.devicePixelRatio || 1);
      canvas.height = rect.height * (window.devicePixelRatio || 1);
      ctx.scale(window.devicePixelRatio || 1, window.devicePixelRatio || 1);
    }
    window.addEventListener('resize', resizeCanvas);
    setTimeout(resizeCanvas, 50);

    function renderImage2ExactMap() {
      const dpr = window.devicePixelRatio || 1;
      const w = canvas.width / dpr;
      const h = canvas.height / dpr;
      if (!w || !h) {
        requestAnimationFrame(renderImage2ExactMap);
        return;
      }

      pulseVal = (pulseVal + 0.04) % 1.0;

      // 1. Map Base Background (Clean 2D Google Maps Tone)
      ctx.fillStyle = '#E5ECEF';
      ctx.fillRect(0, 0, w, h);

      const roadW = 28;
      const mainX = w * 0.50;
      const crossY1 = h * 0.32;
      const crossY2 = h * 0.78;

      // 2. Square City Blocks / Buildings (Orthogonal Grid Form)
      function drawBlock(bx, by, bw, bh) {
        if (bw <= 0 || bh <= 0) return;
        ctx.fillStyle = '#F8F9FA';
        ctx.strokeStyle = '#CBD5E1';
        ctx.lineWidth = 1.2;
        ctx.beginPath();
        if (ctx.roundRect) ctx.roundRect(bx, by, bw, bh, 4);
        else ctx.rect(bx, by, bw, bh);
        ctx.fill();
        ctx.stroke();
      }

      const leftW = mainX - roadW/2 - 8;
      const rightX = mainX + roadW/2 + 8;
      const rightW = w - rightX - 8;

      // Top Blocks
      drawBlock(6, 6, leftW, crossY1 - roadW/2 - 10);
      drawBlock(rightX, 6, rightW, crossY1 - roadW/2 - 10);

      // Middle Blocks
      drawBlock(6, crossY1 + roadW/2 + 6, leftW, crossY2 - crossY1 - roadW - 12);
      drawBlock(rightX, crossY1 + roadW/2 + 6, rightW, crossY2 - crossY1 - roadW - 12);

      // Bottom Blocks
      drawBlock(6, crossY2 + roadW/2 + 6, leftW, h - crossY2 - roadW/2 - 10);
      drawBlock(rightX, crossY2 + roadW/2 + 6, rightW, h - crossY2 - roadW/2 - 10);

      // 3. Orthogonal Roads (Clean Right-Angle Grid)
      function drawRoad(x1, y1, x2, y2, width) {
        ctx.strokeStyle = '#CBD5E1';
        ctx.lineWidth = width;
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
        ctx.stroke();

        ctx.strokeStyle = '#FFFFFF';
        ctx.lineWidth = width - 4;
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
        ctx.stroke();
      }

      // Horizontal Cross Streets (100% Straight Horizontal)
      drawRoad(-5, crossY1, w + 5, crossY1, roadW - 4);
      drawRoad(-5, crossY2, w + 5, crossY2, roadW - 6);

      // Vertical Main Avenue (100% Straight Vertical Center)
      drawRoad(mainX, h + 5, mainX, -5, roadW);

      // 4. Clean Street Labels
      ctx.fillStyle = '#64748B';
      ctx.font = 'bold 8.5px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
      
      // Horizontal Street Name
      ctx.fillText('PHỐ ĐẠI TỪ', 10, crossY1 - 6);

      // Vertical Street Name
      ctx.save();
      ctx.translate(mainX - 6, h * 0.74);
      ctx.rotate(-Math.PI / 2);
      ctx.fillText('Đ. NGUYỄN CẢNH DỊ', 0, 0);
      ctx.restore();

      // 5. Active Navigation Route Polyline (Vibrant Cyan Polyline)
      const turnY = crossY1;
      const puckY = h * 0.58;

      ctx.save();
      ctx.strokeStyle = '#00B4D8';
      ctx.lineWidth = 6;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.beginPath();
      ctx.moveTo(mainX, h);
      ctx.lineTo(mainX, turnY);

      if (targetTurn === 2 || targetTurn === 1 || targetTurn === 3) {
        // Right turn path at intersection
        ctx.lineTo(w + 5, turnY);
      } else if (targetTurn === 6 || targetTurn === 5 || targetTurn === 7) {
        // Left turn path at intersection
        ctx.lineTo(-5, turnY);
      } else {
        // Straight
        ctx.lineTo(mainX, -5);
      }
      ctx.stroke();
      ctx.restore();

      // 6. Navigation Vehicle Puck (Centered 2D GPS Puck)
      const cx = mainX;
      const cy = puckY;

      // Pulsing Halo
      ctx.fillStyle = 'rgba(0, 180, 216, ' + (0.35 * (1 - pulseVal)) + ')';
      ctx.beginPath();
      ctx.arc(cx, cy, 12 + pulseVal * 10, 0, Math.PI * 2);
      ctx.fill();

      // Vehicle Puck Disc
      ctx.fillStyle = '#0084FF';
      ctx.strokeStyle = '#FFFFFF';
      ctx.lineWidth = 2.2;
      ctx.beginPath();
      ctx.arc(cx, cy, 9.5, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();

      // Sharp White Directional Triangle/Arrow inside
      ctx.fillStyle = '#FFFFFF';
      ctx.beginPath();
      ctx.moveTo(cx, cy - 5.5);
      ctx.lineTo(cx - 4, cy + 3.5);
      ctx.lineTo(cx, cy + 1.5);
      ctx.lineTo(cx + 4, cy + 3.5);
      ctx.closePath();
      ctx.fill();

      requestAnimationFrame(renderImage2ExactMap);
    }
    requestAnimationFrame(renderImage2ExactMap);

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
        hwBle.className = 'ble-tag connected';
      } else {
        bleDot.className = 'dot';
        bleText.innerText = 'BLE: Đang chờ iPhone...';
        hwBle.className = 'ble-tag connected';
      }

      const distTxt = document.getElementById('distTxt');
      distTxt.innerText = data.dist >= 1000 ? (data.dist / 1000).toFixed(1) + 'km' : data.dist + 'm';
      document.getElementById('speedTxt').innerText = data.speed + ' km/h';

      const st = data.street || 'PHÓ ĐẠI TỪ';
      document.getElementById('streetTxt').innerText = st.toUpperCase();

      document.getElementById('arrivalTxt').innerText = data.arrival || '11:25';
      document.getElementById('etaTxt').innerText = (data.eta || 1) + ' ph';

      if (data.tot_dist) {
        document.getElementById('totalDistTxt').innerText = (data.tot_dist / 1000).toFixed(1) + ' km';
      }

      document.getElementById('turnSvg').innerHTML = turnIcons[data.turn] || turnIcons[2];
      targetTurn = data.turn;

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
        tot_dist: 700,
        popup: 'NONE'
      });
      fetch(`/api/test?turn=${turn}&dist=${dist}&speed=${speed}&street=${encodeURIComponent(street)}&eta=${eta}&arrival=${arrival}`);
    }

    function testCall(name) {
      updateUi({
        ble: true,
        turn: 2,
        dist: 595,
        speed: 0,
        street: 'PHÓ ĐẠI TỪ',
        eta: 1,
        arrival: '11:25',
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
        turn: 2,
        dist: 595,
        speed: 0,
        street: 'PHÓ ĐẠI TỪ',
        eta: 1,
        arrival: '11:25',
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
  int contentLength = server.header("Content-Length").toInt();
  if (contentLength > 0 && contentLength < (int)sizeof(jpegFrameBuf)) {
    WiFiClient client = server.client();
    size_t readBytes = 0;
    unsigned long t0 = millis();
    while (readBytes < (size_t)contentLength && (millis() - t0 < 350)) {
      if (client.available()) {
        size_t chunk = client.readBytes((char*)(jpegFrameBuf + readBytes), contentLength - readBytes);
        readBytes += chunk;
      } else {
        delay(1);
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
  pAdvertising->setMinInterval(16); // 10ms fast advertising
  pAdvertising->setMaxInterval(32); // 20ms
  pAdvertising->setMinPreferred(6); // 7.5ms min interval
  pAdvertising->setMaxPreferred(12); // 15ms max interval
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  Serial.println("[BLE] ESP32 da san sang nhan luong 20 FPS qua Bluetooth BLE (MTU 517)!");
}

void loop() {
  server.handleClient();
  display.update();
  delay(2);
}
