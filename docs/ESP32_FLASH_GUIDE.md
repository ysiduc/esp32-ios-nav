# Hướng Dẫn Nạp Code Cho ESP32 Trên Arch Linux

Dự án hỗ trợ cả màn hình **OLED SSD1306 (I2C)** và màn hình màu **TFT ST7789 (SPI)**.

---

## 1. Cài đặt PlatformIO Core trên Arch Linux

```bash
# Cài đặt qua pacman hoặc yay
sudo pacman -S platformio-core
# hoặc dùng pip
python3 -m pip install -U platformio
```

Cấp quyền truy cập cổng Serial USB (tránh lỗi permission denied khi nạp):
```bash
sudo usermod -aG uucp $USER
sudo usermod -aG lock $USER
```
*(Đăng xuất hoặc khởi động lại máy để quyền có hiệu lực)*.

---

## 2. Sơ đồ nối dây (Pinout)

### A. Màn hình OLED SSD1306 128x64 (I2C):
| Chân OLED | Chân ESP32 |
|-----------|------------|
| VCC       | 3.3V       |
| GND       | GND        |
| SCL       | GPIO 22    |
| SDA       | GPIO 21    |

### B. Màn hình TFT ST7789 240x240 (SPI):
| Chân TFT  | Chân ESP32 |
|-----------|------------|
| VCC       | 3.3V / 5V  |
| GND       | GND        |
| SCL / SCK | GPIO 18    |
| SDA / MOSI| GPIO 23    |
| RES / RST | GPIO 4     |
| DC        | GPIO 2     |
| CS        | GPIO 5     |
| BL (LED)  | 3.3V       |

---

## 3. Biên dịch và Nạp Code

Cắm ESP32 vào cổng USB trên Arch Linux:

```bash
cd /home/ysiduc/esp32_ios_nav/firmware_esp32

# 1. Nạp cho bản màn hình OLED
pio run -e esp32_oled -t upload

# 2. Xem Serial Monitor trực tiếp
pio device monitor -b 115200
```

*(Nếu dùng màn hình màu TFT, đổi `-e esp32_oled` thành `-e esp32_tft_color`).*

---

## 4. Ghép đôi Bluetooth với iPhone

1. Sau khi nạp code, ESP32 sẽ phát tên **`ESP32_NAV_ANCS`**.
2. Trên iPhone: Mở **Cài đặt (Settings) -> Bluetooth**.
3. Chọn **ESP32_NAV_ANCS** để kết nối.
4. iPhone sẽ hiện hộp thoại:
   - *"Yêu cầu ghép đôi Bluetooth?"* $\rightarrow$ Chọn **Ghép đôi (Pair)**.
   - *"Cho phép ESP32 hiển thị thông báo iPhone?"* $\rightarrow$ Chọn **Cho phép (Allow)**.
5. Xong! Kể từ bây giờ:
   - Mọi cuộc gọi đến và SMS sẽ tự động báo lên màn hình ESP32 qua ANCS.
   - Mở App Flutter trên iPhone -> chọn điểm đến và bấm "Bắt đầu điều hướng" để ESP32 hiển thị lộ trình, khoảng cách và hướng rẽ.
