# Đặc Tả Giao Thức Truyền Nhận Dữ Liệu (iOS <-> ESP32)

---

## 1. Kênh Thông Báo iOS (Apple Notification Center Service - ANCS)

- **Cơ chế:** ESP32 đóng vai trò BLE Client kết nối vào Service ANCS ngầm của iOS.
- **Service UUID:** `7905F431-B5CE-4E99-A40F-4B1E122D00D0`
- **Notification Source Characteristic:** `9FBF120D-6301-42D9-8C58-25E699A21DBD`

### Mã Danh Mục Thông Báo (Category ID):
| Category ID | Định danh | Hành vi trên ESP32 |
|-------------|-----------|--------------------|
| `0x01`      | `CategoryIDIncomingCall` | Hiện Popup Nhấp nháy "CUỘC GỌI ĐẾN" kèm tên người gọi |
| `0x02`      | `CategoryIDMissedCall`   | Hiện Icon cuộc gọi nhỡ |
| `0x04`      | `CategoryIDSocial`       | Hiện Popup "TIN NHẮN / ZALO / MESSENGER" |
| `0x06`      | `CategoryIDEmail`        | Hiện Popup "EMAIL MỚI" |

---

## 2. Kênh Chỉ Đường & Bản Đồ (Custom Navigation BLE GATT)

- **Service UUID:** `0000FFE0-0000-1000-8000-00805F9B34FB` (0xFFE0)
- **Characteristic UUID (Write):** `0000FFE1-0000-1000-8000-00805F9B34FB` (0xFFE1)

### Định dạng gói tin JSON (Truyền định kỳ 1.5s hoặc khi chuyển bước):
```json
{
  "turn": 2,
  "dist": 150,
  "tot_dist": 4200,
  "eta": 12,
  "street": "Nguyen Hue",
  "speed": 38,
  "step": 2,
  "tot_steps": 8
}
```

### Bảng Mã Hướng Rẽ (`turn`):
| Mã `turn` | Ý nghĩa | Icon hiển thị |
|-----------|---------|---------------|
| `0`       | Đi thẳng (Straight) | ⬆️ Mũi tên thẳng |
| `1`       | Chếch phải (Slight Right) | ↗️ Mũi tên chếch phải |
| `2`       | Rẽ phải (Turn Right) | ➡️ Mũi tên rẽ phải |
| `3`       | Rẽ gắt phải (Sharp Right) | ⤴️ Mũi tên gắt phải |
| `4`       | Quay đầu (U-Turn) | ↩️ Mũi tên quay đầu |
| `5`       | Rẽ gắt trái (Sharp Left) | ⤵️ Mũi tên gắt trái |
| `6`       | Rẽ trái (Turn Left) | ⬅️ Mũi tên rẽ trái |
| `7`       | Chếch trái (Slight Left) | ↖️ Mũi tên chếch trái |
| `8`       | Vòng xuyến (Roundabout) | 🔄 Vòng xuyến |
| `9`       | Đã đến đích (Arrived) | 🏁 Lá cờ đích |
| `10`      | Bắt đầu di chuyển | 🧭 Bắt đầu |
