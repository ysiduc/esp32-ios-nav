# Hướng Dẫn Build và Cài Đặt App iOS Trên Arch Linux (Không Cần Mac)

Tài liệu này hướng dẫn chi tiết cách biên dịch (build) mã nguồn Flutter thành file cài đặt `.ipa` và nạp vào iPhone của bạn trực tiếp từ hệ điều hành Arch Linux.

---

## Cách 1: Tự động Build `.ipa` bằng GitHub Actions (Khuyên dùng - Miễn phí)

GitHub cung cấp miễn phí máy ảo macOS (`macos-14`) trên Cloud với đầy đủ Xcode và Flutter.

### Bước 1: Khởi tạo Git và đẩy code lên GitHub
Mở Terminal trên Arch Linux và chạy:

```bash
cd /home/ysiduc/esp32_ios_nav

# 1. Khởi tạo kho git
git init
git add .
git commit -m "Initial commit: Flutter iOS OSM Nav + ESP32 ANCS"

# 2. Tạo repository trên GitHub (Private hoặc Public)
# Đổi your-username/esp32-ios-nav thành repo của bạn
git remote add origin https://github.com/your-username/esp32-ios-nav.git
git branch -M main
git push -u origin main
```

### Bước 2: Tải file `.ipa` từ GitHub Actions
1. Truy cập vào GitHub repo của bạn -> Vào tab **Actions**.
2. Workflow **"Build iOS IPA Package"** sẽ tự động chạy trong khoảng 3 - 5 phút.
3. Khi biểu tượng tick xanh hiện lên, bấm vào lượt build đó và cuộn xuống mục **Artifacts**.
4. Tải file `esp32_nav_ios_ipa.zip` về máy Arch Linux và giải nén ra file `esp32_nav_app.ipa`.

---

## Cách 2: Cài file `.ipa` vào iPhone từ Arch Linux

Bạn không cần tài khoản Apple Developer $99/năm. Bạn chỉ cần Apple ID cá nhân miễn phí và một trong các công cụ sau:

### Lựa chọn A: Dùng Sideloadly (Rất nhanh & Ổn định)
1. Cài đặt **Sideloadly** trên máy tính (hoặc qua WINE/VM).
2. Cắm iPhone vào máy tính qua cáp USB -> Chọn **Tin cậy máy tính này (Trust This Computer)** trên iPhone.
3. Mở Sideloadly, kéo thả file `esp32_nav_app.ipa` vào.
4. Nhập Apple ID cá nhân của bạn và bấm **Start**.
5. Sau khi nạp xong: Trên iPhone vào **Cài đặt (Settings) -> Cài đặt chung (General) -> Quản lý VPN & Thiết bị (VPN & Device Management)** -> Bấm **Tin cậy (Trust)** chứng chỉ Apple ID của bạn.

### Lựa chọn B: Dùng AltStore / SideStore
1. Cài AltStore lên iPhone.
2. Mở file `.ipa` thông qua ứng dụng AltStore trên iPhone để cài đặt.

---

## Cách 3: Chạy trực tiếp qua Máy ảo macOS trên Arch Linux (Docker-OSX / KVM)

Nếu máy Arch Linux của bạn có phần cứng mạnh (RAM $\ge$ 16GB, CPU hỗ trợ ảo hóa VT-x/AMD-V):

```bash
# Cài đặt docker và qemu
sudo pacman -S docker qemu-full virt-manager

# Chạy macOS Ventura/Sonoma trực tiếp trong Docker
docker run -it \
    --device /dev/kvm \
    -p 50922:10022 \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -e "DISPLAY=${DISPLAY:-:0.0}" \
    sickcodes/docker-osx:latest
```

Trong máy ảo macOS, bạn mở Xcode, cắm iPhone qua USB Passthrough để nạp trực tiếp qua nút **Run (Command + R)**.
