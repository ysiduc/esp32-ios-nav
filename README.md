# ESP32 iOS Navigation & ANCS Notifications

Hệ thống điều hướng chỉ đường Turn-by-Turn tích hợp bản đồ **OpenStreetMap / OpenFreeMap** và hiển thị thông báo cuộc gọi, tin nhắn từ iPhone lên màn hình **ESP32** (hỗ trợ phát triển và build trên **Arch Linux** không cần máy Mac).

---

## 🌟 Tính năng nổi bật

1. **Ứng dụng iOS (Flutter):**
   - Bản đồ **OpenStreetMap / OpenFreeMap** tốc độ cao với các kiểu giao diện Bright / Dark / Standard.
   - Tìm kiếm địa điểm & đường phố bằng tiếng Việt (OpenStreetMap Nominatim).
   - Chỉ đường Turn-by-Turn chính xác từng mét qua **OSRM Engine** (Open Source Routing Machine).
   - Quản lý kết nối Bluetooth Low Energy (BLE) tự động quét, ghép đôi và truyền gói tin lộ trình sang ESP32.
   - Chế độ **Mô phỏng lộ trình (Simulation Mode)** trực tiếp trên máy không cần ra ngoài đường.
   - Màn hình **Mô phỏng ESP32 (Virtual Screen Mirror)** trên app giúp kiểm thử trước giao diện phần cứng.

2. **Phần cứng ESP32:**
   - **Kênh kép ANCS + BLE GATT:**
     - Tự động nhận thông báo Cuộc gọi đến, SMS, Zalo, Messenger trực tiếp từ iOS Notification Center.
     - Nhận dữ liệu lộ trình: Icon mũi tên rẽ, khoảng cách đếm lùi, tên đường, tốc độ xe (km/h).
   - Hỗ trợ cả màn hình OLED SSD1306 (128x64) và màn hình màu TFT ST7789.

3. **CI/CD Tự Động Build iOS Không Cần Mac:**
   - Cấu hình sẵn GitHub Actions workflow (`.github/workflows/build_ios.yml`) chạy trên macOS-14 Cloud để tự xuất file `.ipa`.

---

## 📁 Cấu trúc thư mục

- `mobile_app/`: Mã nguồn ứng dụng Flutter iOS/Android
- `firmware_esp32/`: Mã nguồn C++ nạp cho ESP32 (PlatformIO)
- `docs/`: Tài liệu chi tiết
  - `docs/BUILD_IOS_GUIDE.md`: Hướng dẫn build file .ipa và cài vào iPhone từ Arch Linux
  - `docs/ESP32_FLASH_GUIDE.md`: Hướng dẫn nạp code ESP32 và nối dây
  - `docs/PROTOCOL_SPEC.md`: Đặc tả chi tiết gói tin truyền thông BLE
