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
volatile double curLat = 20.9785;  // Default: Ha Noi (Pho Nguyen Canh Di)
volatile double curLng = 105.8322;
volatile int curHeading = 0;
String curStreet = "San sang dan duong";
String curArrival = "--:--";

// ANCS State
String popupTitle = "";
String popupMsg = "";
String popupType = "NONE"; // "CALL", "SMS", "NONE"
unsigned long popupExpire = 0;

// =========================================================================
// High-Fidelity Web Page: Real HD Google Maps / OSM Mini Map + 50/50 HUD
// =========================================================================
const char PAGE_INDEX[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>ESP32 Smart Navigator Screen</title>
  <!-- Google Fonts & Leaflet Map CSS -->
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #0b0f17;
      color: #fff;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      display: flex;
      flex-direction: column;
      align-items: center;
      min-height: 100vh;
      padding: 12px;
    }
    header {
      text-align: center;
      margin-bottom: 12px;
      width: 100%;
      max-width: 480px;
    }
    .header-title {
      font-size: 1.1rem;
      font-weight: 800;
      color: #00F0FF;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
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
      gap: 5px;
      padding: 3px 10px;
      border-radius: 99px;
      font-size: 0.72rem;
      font-weight: 700;
      background: #161e28;
      border: 1px solid #233044;
    }
    .dot { width: 7px; height: 7px; border-radius: 50%; background: #64748b; }
    .dot.active { background: #05FFA1; box-shadow: 0 0 6px #05FFA1; }

    /* Realistic ESP32 Device Frame (Matching iOS Screen 2) */
    .device-shell {
      position: relative;
      width: 100%;
      max-width: 420px;
      height: 250px;
      background: #1E242C;
      border-radius: 26px;
      border: 6px solid #30363D;
      box-shadow: 0 20px 50px rgba(0,0,0,0.9);
      overflow: hidden;
      padding: 4px;
      display: flex;
      flex-direction: column;
    }

    /* Top Hardware Bar */
    .hw-bar {
      height: 22px;
      background: rgba(0,0,0,0.7);
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
    .ble-status { color: #ff5555; }
    .ble-status.connected { color: #00F0FF; }
    .battery { color: #05FFA1; }

    /* 50/50 Screen Area */
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

    /* LEFT 50%: Live HD Map */
    .map-box {
      flex: 1;
      height: 100%;
      border-radius: 10px;
      overflow: hidden;
      border: 1.2px solid rgba(0, 240, 255, 0.4);
      position: relative;
      background: #0f172a;
    }
    #map {
      width: 100%;
      height: 100%;
      background: #0f172a;
    }
    .map-live-tag {
      position: absolute;
      bottom: 4px;
      left: 4px;
      background: rgba(0,0,0,0.8);
      color: #00F0FF;
      font-size: 0.55rem;
      font-family: monospace;
      font-weight: 800;
      padding: 1px 5px;
      border-radius: 4px;
      z-index: 1000;
    }

    /* Custom Centered Car/Vehicle Icon on Leaflet */
    .vehicle-marker {
      width: 28px;
      height: 28px;
      background: #0084FF;
      border: 2px solid #ffffff;
      border-radius: 50%;
      box-shadow: 0 0 10px #0084FF;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: transform 0.2s linear;
    }
    .vehicle-arrow {
      width: 0;
      height: 0;
      border-left: 5px solid transparent;
      border-right: 5px solid transparent;
      border-bottom: 8px solid #ffffff;
      margin-bottom: 2px;
    }

    /* RIGHT 50%: HUD Display */
    .hud-box {
      flex: 1;
      height: 100%;
      background: #161E28;
      border-radius: 10px;
      border: 1px solid rgba(255,255,255,0.08);
      padding: 8px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
    }

    /* Turn Header */
    .turn-row {
      display: flex;
      align-items: center;
      gap: 6px;
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
      font-size: 1.25rem;
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
      margin-top: 2px;
    }

    /* Street Banner */
    .street-card {
      background: #0F172A;
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 6px;
      padding: 4px 6px;
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

    /* Arrival / ETA footer */
    .eta-card {
      background: #0A0E14;
      border-radius: 6px;
      padding: 4px 8px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-family: monospace;
    }
    .eta-left {
      font-size: 0.65rem;
      color: #94a3b8;
    }
    .eta-clock {
      color: #00F0FF;
      font-weight: bold;
      font-size: 0.8rem;
    }
    .eta-mins {
      color: #05FFA1;
      font-weight: bold;
      font-size: 0.8rem;
    }

    /* ANCS Popup (Incoming Call & SMS) */
    .ancs-popup {
      position: absolute;
      inset: 6px;
      background: rgba(0, 43, 27, 0.96);
      border-radius: 12px;
      border: 2px solid #05FFA1;
      display: none;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      text-align: center;
      padding: 12px;
      z-index: 2000;
      backdrop-filter: blur(8px);
    }
    .ancs-popup.sms {
      background: rgba(43, 31, 0, 0.96);
      border-color: #FFB800;
    }
    .popup-hdr {
      font-size: 0.9rem;
      font-weight: 800;
      color: #05FFA1;
      letter-spacing: 1px;
    }
    .ancs-popup.sms .popup-hdr { color: #FFB800; }
    .popup-title {
      font-size: 1.2rem;
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
      margin-top: 14px;
      width: 100%;
      max-width: 420px;
      background: #161E28;
      border: 1px solid #233044;
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
    }
    .grid-btns {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 6px;
    }
    .btn {
      background: #212B38;
      border: 1px solid #303E50;
      color: #fff;
      padding: 8px;
      border-radius: 8px;
      font-size: 0.72rem;
      font-weight: 600;
      cursor: pointer;
    }
    .btn:active { transform: scale(0.97); }
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
    <!-- Status Line -->
    <div class="hw-bar">
      <div id="hwBle" class="ble-status">NO BLE</div>
      <div id="clockTxt">10:52</div>
      <div class="battery">100% 🔋</div>
    </div>

    <!-- 50/50 Screen Area -->
    <div class="screen-area">
      <!-- LEFT 50%: Live Mini Map Canvas -->
      <div class="map-box">
        <div id="map"></div>
        <div class="map-live-tag">MAP LIVE</div>
      </div>

      <!-- RIGHT 50%: Turn Directions, Speed & ETA -->
      <div class="hud-box">
        <div class="turn-row">
          <div class="turn-badge" id="turnIconBox">
            <svg viewBox="0 0 24 24" id="turnSvg">
              <path d="M12 2L4 10h5v10h6V10h5L12 2z"/>
            </svg>
          </div>
          <div class="turn-dist-col">
            <div class="dist-val" id="distTxt">0m</div>
            <div class="speed-val" id="speedTxt">0 km/h</div>
          </div>
        </div>

        <div class="street-card">
          <div class="street-name" id="streetTxt">SAN SANG DAN DUONG</div>
        </div>

        <div class="eta-card">
          <div>
            <div class="eta-left">DỰ KIẾN</div>
            <div class="eta-clock" id="arrivalTxt">10:52</div>
          </div>
          <div style="text-align: right;">
            <div class="eta-left" id="totalDistTxt">0.0 km</div>
            <div class="eta-mins" id="etaTxt">0 ph</div>
          </div>
        </div>
      </div>

      <!-- ANCS Popup -->
      <div id="ancsPopup" class="ancs-popup">
        <div class="popup-hdr" id="popupHdr">CUOC GOI DEN</div>
        <div class="popup-title" id="popupTitle">NGUYEN VAN A</div>
        <div class="popup-sub" id="popupSub">iPhone Notification</div>
      </div>
    </div>
  </div>

  <!-- Interactive Controls -->
  <div class="control-box">
    <div class="ctrl-title">
      <span>Thử Nghiệm Tính Năng (Test Controls)</span>
    </div>
    <div class="grid-btns">
      <button class="btn" onclick="testNav(6, 410, 38, 'P. Nguyen Canh Di', 1, '10:53', 20.9785, 105.8322, 180)">⬅️ Rẽ trái 410m (P. Nguyễn Cảnh Dị)</button>
      <button class="btn" onclick="testNav(2, 250, 42, 'Pho Dinh Cong', 3, '10:55', 20.9820, 105.8390, 90)">➡️ Rẽ phải 250m (Phố Định Công)</button>
      <button class="btn" onclick="testNav(0, 1200, 50, 'Duong Giai Phong', 10, '11:02', 20.9890, 105.8420, 0)">⬆️ Đi thẳng 1.2km (Đường Giải Phóng)</button>
      <button class="btn" onclick="testNav(8, 80, 25, 'Vong Xuyen Big C', 2, '10:54', 21.0040, 105.7920, 270)">🔄 Vòng xuyến 80m</button>
      <button class="btn call" onclick="testCall('Nguyen Van A')">📞 Test Cuộc Gọi Đến</button>
      <button class="btn sms" onclick="testSms('Me', 'Con ve nha an com nhe!')">💬 Test Tin Nhắn SMS</button>
    </div>
  </div>

  <script>
    // 1. Initialize Real Leaflet Map with Google Retina Vector Tiles
    let map = null;
    let vehicleMarker = null;
    let currentLatLng = [20.9785, 105.8322];

    try {
      map = L.map('map', {
        center: currentLatLng,
        zoom: 17,
        zoomControl: false,
        attributionControl: false
      });

      // Google HD Retina Maps vector tile layer
      L.tileLayer('https://mt1.google.com/vt/lyrs=m&scale=2&hl=vi&x={x}&y={y}&z={z}', {
        maxZoom: 20,
        subdomains:['mt0','mt1','mt2','mt3']
      }).addTo(map);

      // Custom Vehicle Icon
      const vehicleHtml = `
        <div id="vIcon" class="vehicle-marker">
          <div class="vehicle-arrow"></div>
        </div>`;
      const customIcon = L.divIcon({
        className: 'custom-vehicle-icon',
        html: vehicleHtml,
        iconSize: [28, 28],
        iconAnchor: [14, 14]
      });

      vehicleMarker = L.marker(currentLatLng, { icon: customIcon }).addTo(map);
    } catch(e) {
      console.log('Leaflet tile fallback:', e);
    }

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
      // 1. BLE Header
      const bleDot = document.getElementById('bleDot');
      const bleText = document.getElementById('bleText');
      const hwBle = document.getElementById('hwBle');

      if (data.ble) {
        bleDot.className = 'dot active';
        bleText.innerText = 'iPhone Đã Kết Nối';
        hwBle.innerText = 'ESP32 BLE';
        hwBle.className = 'ble-status connected';
      } else {
        bleDot.className = 'dot';
        bleText.innerText = 'BLE: Đang chờ iPhone...';
        hwBle.innerText = 'NO BLE';
        hwBle.className = 'ble-status';
      }

      // 2. HUD Metrics
      const distTxt = document.getElementById('distTxt');
      if (data.dist >= 1000) {
        distTxt.innerText = (data.dist / 1000).toFixed(1) + 'km';
      } else {
        distTxt.innerText = data.dist + 'm';
      }

      document.getElementById('speedTxt').innerText = data.speed + ' km/h';
      document.getElementById('streetTxt').innerText = data.street || 'SAN SANG DAN DUONG';
      document.getElementById('arrivalTxt').innerText = data.arrival || '--:--';
      document.getElementById('etaTxt').innerText = data.eta + ' ph';
      
      if (data.tot_dist) {
        document.getElementById('totalDistTxt').innerText = (data.tot_dist / 1000).toFixed(1) + ' km';
      }

      // 3. Turn Arrow SVG
      document.getElementById('turnSvg').innerHTML = turnIcons[data.turn] || turnIcons[0];

      // 4. Update Leaflet Map Position & Heading
      if (data.lat && data.lng && map) {
        const newPos = [data.lat, data.lng];
        map.panTo(newPos, { animate: true, duration: 0.5 });
        if (vehicleMarker) {
          vehicleMarker.setLatLng(newPos);
          const vIcon = document.getElementById('vIcon');
          if (vIcon && data.head !== undefined) {
            vIcon.style.transform = `rotate(${data.head}deg)`;
          }
        }
      }

      // 5. ANCS Popup
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

    // Test handlers
    function testNav(turn, dist, speed, street, eta, arrival, lat, lng, head) {
      fetch(`/api/test?turn=${turn}&dist=${dist}&speed=${speed}&street=${encodeURIComponent(street)}&eta=${eta}&arrival=${arrival}&lat=${lat}&lng=${lng}&head=${head}`);
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
  doc["lat"] = curLat;
  doc["lng"] = curLng;
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
  if (server.hasArg("lat")) curLat = server.arg("lat").toDouble();
  if (server.hasArg("lng")) curLng = server.arg("lng").toDouble();
  if (server.hasArg("head")) curHeading = server.arg("head").toInt();

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
// 2. Custom Navigation Characteristic Callback (Receives Navigation & Popups)
// =========================================================================
class NavCharCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic) {
    std::string value = pCharacteristic->getValue();
    if (value.length() == 0) return;

    Serial.printf("[BLE RX]: %s\n", value.c_str());

    JsonDocument doc;
    DeserializationError error = deserializeJson(doc, value.c_str());

    if (!error) {
      // Check for Direct Notification Packets from iOS App
      if (doc["type"] == "CALL") {
        const char* name = doc["title"] | "Cuoc goi den";
        popupTitle = name;
        popupMsg = doc["msg"] | "Cuoc goi den tu iPhone";
        popupType = "CALL";
        popupExpire = millis() + 8000;
        display.showCallAlert(name);
        return;
      } else if (doc["type"] == "SMS") {
        const char* sender = doc["title"] | "Tin nhan";
        const char* content = doc["msg"] | "Thong bao moi";
        popupTitle = sender;
        popupMsg = content;
        popupType = "SMS";
        popupExpire = millis() + 6000;
        display.showSmsAlert(sender, content);
        return;
      }

      // Navigation Telemetry Payload
      curTurn = doc["turn"] | 0;
      curDist = doc["dist"] | 0;
      curTotalDist = doc["tot_dist"] | 0;
      curSpeed = doc["speed"] | 0;
      curEta = doc["eta"] | 0;
      curStreet = String(doc["street"] | "Tiep tuc");
      curArrival = String(doc["arrival"] | "--:--");
      if (doc.containsKey("lat")) curLat = doc["lat"];
      if (doc.containsKey("lng")) curLng = doc["lng"];
      if (doc.containsKey("head")) curHeading = doc["head"];

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

  // 4. Start NimBLE Server with Bonding for iOS ANCS
  NimBLEDevice::init("ESP32_NAV_ANCS");
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setSecurityInitKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setSecurityRespKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);

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

  Serial.println("[BLE] Da phat Bluetooth (ANCS + Navigation)!");
}

void loop() {
  server.handleClient();
  display.update();
  delay(10);
}
