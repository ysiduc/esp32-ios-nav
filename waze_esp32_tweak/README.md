# Waze ESP32 Navigation & Virtual HUD Tweak

Tweak dành cho ứng dụng **Waze iOS** để tích hợp trực tiếp với thiết bị dẫn đường **ESP32 (OLED / TFT ST7789)**.

---

## 🌟 Tính năng chính

1. **Trích xuất dữ liệu điều hướng từ Waze theo thời gian thực**:
   - Khoảng cách tới ngã rẽ đếm ngược từng mét (`distanceToTurn`).
   - Tên đường tiếp theo và câu chỉ dẫn (`nextStreetName`).
   - Mũi tên rẽ chuẩn hóa (Đi thẳng, Rẽ trái, Rẽ phải, Vòng xuyến, Quay đầu,...).
   - Tốc độ thực tế (`currentSpeed`) & Giới hạn tốc độ của biển báo (`speedLimit`).
   - Giờ dự kiến đến nơi (`ETA`) & Tổng quãng đường còn lại.

2. **Kênh truyền thông BLE nhị phân (100% tương thích firmware ESP32)**:
   - Sử dụng chuẩn `NavBinaryPacket` đóng gói với Magic Header `0xAA` và XOR Checksum.
   - Giao tiếp qua BLE GATT Service `0000FFE0-0000-1000-8000-00805F9B34FB` (0xFFE0), Characteristic `0000FFE1-0000-1000-8000-00805F9B34FB` (0xFFE1).
   - Tự động quét và kết nối lại khi xe nổ máy.

3. **Màn hình ảo mô phỏng ESP32 HUD trực tiếp trên Waze (Virtual HUD Mirror)**:
   - Cửa sổ nổi dạng kính mờ (Glassmorphism), có thể kéo thả di chuyển tự do trên màn hình Waze.
   - Hiển thị đầy đủ giao diện đồng hồ HUD: Mũi tên rẽ, khoảng cách, tốc độ lớn, biển báo giới hạn tốc độ viền đỏ, trạng thái kết nối BLE (Xanh lá / Đỏ) và ảnh thu nhỏ bản đồ (Minimap).

4. **Stream hình ảnh Bản đồ Waze thời gian thực (ST7789 TFT)**:
   - Tích hợp máy chủ WebSocket siêu nhẹ chạy trên cổng `8080`.
   - Chụp viewport quanh xe của Waze (Metal view), nén JPEG chất lượng cao dung lượng thấp (~4KB/frame), stream mượt mà sang ESP32 qua Wi-Fi Hotspot `172.20.10.1:8080`.

---

## 🚀 Cách Build File IPA trên GitHub Actions (Không cần Mac)

1. Đẩy commit lên GitHub:
   ```bash
   git add waze_esp32_tweak/ .github/workflows/build_waze_ipa.yml
   git commit -m "feat: Add Waze ESP32 HUD Tweak & IPA packaging workflow"
   git push origin main
   ```
2. Vào tab **Actions** trên GitHub -> chọn **Build Waze ESP32 HUD IPA** -> nhấn **Run workflow**.
3. Điền link tải trực tiếp file Waze IPA đã decrypt (nếu muốn) hoặc tải file `WazeESP32Nav.dylib` về máy.
4. Tải file `Waze-ESP32-HUD-PRODUCTION.ipa` từ Artifacts về cài đặt lên iPhone bằng **TrollStore** hoặc **Sideloadly**.
