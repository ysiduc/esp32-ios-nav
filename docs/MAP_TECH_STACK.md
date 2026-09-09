# Kiến Trúc Toàn Bộ Stack Bản Đồ Tự Chủ (Self-Hosted Navigation Ecosystem)

Hệ thống điều hướng mã nguồn mở độc lập kết nối ESP32 với các thành phần công nghệ:

---

## 1. Thành phần Công nghệ

| Chức năng | Công nghệ mã nguồn mở | Ưu điểm cốt lõi |
|-----------|------------------------|-----------------|
| **Dữ liệu nền** | **OpenStreetMap (OSM)** | Dữ liệu đường sá, địa danh toàn cầu, cập nhật liên tục |
| **Tile Server** | **Martin (Rust) / Tegola** | Phục vụ Vector Tiles MVT siêu nhẹ (< 50MB RAM), đọc file `.pmtiles` hoặc `.mbtiles` |
| **Frontend Map** | **MapLibre GL / FlutterMap** | Render bản đồ Vector & Raster mượt mà 60fps, hỗ trợ 3D |
| **Routing & Navigation** | **Valhalla (C++)** | Tính toán lộ trình thông minh, đa phương tiện (ô tô, xe máy, xe đạp), hỗ trợ chỉ làn đường và độ dốc |
| **Geocoding & Search** | **Photon (Elasticsearch)** | Tìm kiếm địa chỉ thời gian thực (Typeahead Autocomplete), tự sửa lỗi gõ sai |
| **Thiết bị hiển thị** | **ESP32 BLE HUD** | Nhận gói tin chỉ đường (turn, distance, street, speed) + Thông báo cuộc gọi/tin nhắn iOS ANCS |

---

## 2. Cách Chạy Stack Server Nhanh Trên Linux (Docker)

Tạo file `docker-compose.yml` trên máy chủ:

```bash
docker compose up -d
```

Các Endpoint dịch vụ sẽ hoạt động tại:
- **Martin Tile Server:** `http://your-server-ip:3000/tiles/{z}/{x}/{y}`
- **Valhalla Routing:** `http://your-server-ip:8002/route`
- **Photon Geocoding:** `http://your-server-ip:2322/api`
