# Hướng Dẫn Nạp Code ESP32 Bằng PlatformIO (20 FPS JPEG Stream)

Dự án firmware ESP32 này nhận luồng hình ảnh điều hướng 50/50 (Mini Map + Bảng chỉ đường) được stream trực tiếp từ ứng dụng điện thoại ở tốc độ **20 FPS** qua Wi-Fi / BLE.

---

## 1. Cấu Trúc Dự Án PlatformIO

```
firmware_esp32/
├── platformio.ini       # File cấu hình PlatformIO (driver ST7789/GC9A01, tần số 240MHz, thư viện)
├── include/
│   └── config.h         # Cấu hình Wi-Fi, URL Stream (8080) và UUID Bluetooth
└── src/
    └── main.cpp         # Mã nguồn C++ giải mã JPEG bằng phần cứng TJpg_Decoder và hiển thị lên TFT
```

---

## 2. Sơ Đồ Cắm Dây (ESP32 <-> Màn Hình TFT LCD)

Mặc định cấu hình chuẩn SPI tốc độ cao (40MHz - 80MHz):

| Chân Màn hình TFT (ST7789/GC9A01) | Chân ESP32 (Mặc định) | Ghi chú |
| :--- | :--- | :--- |
| **VCC** | **3.3V hoặc 5V** | Tùy module màn hình |
| **GND** | **GND** | Nối chung mass |
| **SCL / SCLK** | **GPIO 18** | SPI Clock |
| **SDA / MOSI** | **GPIO 23** | SPI Data (MOSI) |
| **RES / RST** | **GPIO 4** | Reset màn hình |
| **DC / RS** | **GPIO 2** | Data / Command |
| **CS** | **GPIO 5** | Chip Select |
| **BLK / BL** | **GPIO 15 hoặc 3.3V** | Đèn nền màn hình (Backlight) |

*(Bạn có thể đổi các chân này trong file `platformio.ini` tại mục `build_flags`)*

---

## 3. Các Bước Nạp Code Bằng PlatformIO

### Cách 1: Nạp bằng VSCode (PlatformIO IDE Extension)
1. Mở thư mục `firmware_esp32` trong VSCode.
2. Bấm vào biểu tượng **PlatformIO** (con kiến 🐜) ở thanh bên trái.
3. Cắm cáp USB kết nối ESP32 vào máy tính.
4. Bấm **Build** (biểu tượng dấu tích `✓`) để biên dịch.
5. Bấm **Upload** (biểu tượng mũi tên `→`) để nạp code vào ESP32.

### Cách 2: Nạp bằng dòng lệnh PlatformIO CLI
Mở terminal trong thư mục `firmware_esp32`:

```bash
# 1. Biên dịch dự án
pio run

# 2. Nạp code vào ESP32
pio run -t upload

# 3. Mở Serial Monitor để theo dõi FPS
pio device monitor -b 115200
```

---

## 4. Cách Sử Dụng Với App Điện Thoại

1. Mở tính năng **Điểm phát sóng cá nhân (Personal Hotspot)** trên điện thoại:
   - Tên Wi-Fi: `iPhone` (hoặc sửa trong `include/config.h`)
   - Mật khẩu: `12345678`
2. Bật nguồn ESP32, màn hình sẽ tự động kết nối Wi-Fi và báo `WiFi: DA KET NOI`.
3. Mở ứng dụng trên điện thoại -> Vào tab **Màn hình ESP32**:
   - Bấm **"Bật Stream"** (chọn `20 FPS`).
   - Màn hình ESP32 sẽ lập tức hiển thị luồng bản đồ Mini Map bên trái + Mũi tên chỉ đường bên phải ở tốc độ 20 khung hình/giây siêu mượt!
