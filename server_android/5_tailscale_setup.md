# Kết nối iPhone ↔ Android Server qua Tailscale

## Tailscale là gì?

Tailscale tạo mạng riêng ảo (VPN mesh) miễn phí giữa các thiết bị.
- Android phone nhận IP cố định dạng `100.x.x.x` (không bao giờ đổi)
- iPhone kết nối đến `http://100.x.x.x:3000` từ bất kỳ đâu
- Không cần domain, không cần port forward, không cần router config
- Miễn phí cho cá nhân (100 thiết bị)

## Cài đặt (5 phút)

### Bước 1: Tạo tài khoản Tailscale
Truy cập https://tailscale.com và đăng ký (dùng Google/GitHub)

### Bước 2: Cài Tailscale trên Android
- Tải từ Play Store: **Tailscale**
- Mở app → Sign in → chọn tài khoản vừa tạo
- Bật Tailscale lên
- Ghi lại IP Tailscale của Android (dạng `100.x.x.x`)

### Bước 3: Cài Tailscale trên iPhone
- Tải từ App Store: **Tailscale**  
- Mở app → Sign in → CÙNG tài khoản với Android
- Bật Tailscale lên

### Bước 4: Test kết nối
Từ iPhone, dùng trình duyệt truy cập:
```
http://100.x.x.x:3000/catalog        (test Martin tiles)
http://100.x.x.x:8989/health         (test GraphHopper)
http://100.x.x.x:2322/api?q=hanoi    (test Photon search)
```

### Bước 5: Cập nhật iOS app
Sửa 1 dòng trong code:
```swift
// NavServerConfig — trong ValhallaRoutingService.swift
public static let serverBase = "http://100.x.x.x"  // IP Tailscale của Android
```

## Ưu điểm

| | Tailscale | Domain thuê | Ngrok |
|--|-----------|-------------|-------|
| Chi phí | Miễn phí | ~$10-20/năm | Có giới hạn free |
| IP cố định | ✅ Luôn cố định | ✅ | ❌ Đổi mỗi lần |
| HTTPS | ✅ Tự động | Cần setup | ✅ |
| Tốc độ | Nhanh (peer-to-peer) | Phụ thuộc | Qua proxy |
| Setup | 5 phút | Phức tạp | 2 phút |
| Hoạt động offline | Không | Không | Không |
