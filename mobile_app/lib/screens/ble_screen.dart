import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/esp_payload.dart';
import '../services/ble_service.dart';

class BleScreen extends StatefulWidget {
  final VoidCallback? onBackToMap;
  const BleScreen({super.key, this.onBackToMap});

  @override
  State<BleScreen> createState() => _BleScreenState();
}

class _BleScreenState extends State<BleScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final TextEditingController _wifiSsidController = TextEditingController(text: 'iPhone');
  final TextEditingController _wifiPassController = TextEditingController();
  bool _obscureWifiPass = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _wifiSsidController.dispose();
    _wifiPassController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF00F0FF)),
          tooltip: 'Quay lại Bản đồ',
          onPressed: () {
            if (widget.onBackToMap != null) {
              widget.onBackToMap!();
            } else if (Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          },
        ),
        title: const Row(
          children: [
            Icon(Icons.bluetooth_searching_rounded, color: Color(0xFF00F0FF)),
            SizedBox(width: 10),
            Text('Kết nối ESP32 BLE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              bleService.isScanning ? Icons.stop_circle_outlined : Icons.refresh_rounded,
              color: const Color(0xFF00F0FF),
            ),
            tooltip: bleService.isScanning ? 'Dừng quét' : 'Quét thiết bị',
            onPressed: () {
              if (bleService.isScanning) {
                bleService.stopScan();
              } else {
                bleService.startScan();
              }
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF00F0FF),
          labelColor: const Color(0xFF00F0FF),
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(icon: Icon(Icons.devices_rounded, size: 20), text: 'Thiết bị quét được'),
            Tab(icon: Icon(Icons.terminal_rounded, size: 20), text: 'Nhật ký gói tin TX/RX'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // Tab 1: Device List & Status
          _buildDeviceListTab(bleService),

          // Tab 2: Live Log & Test Packet Sender
          _buildLogsAndTestingTab(bleService),
        ],
      ),
    );
  }

  Widget _buildDeviceListTab(BleService bleService) {
    return Column(
      children: [
        // Connection Status Banner
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: bleService.isConnected ? const Color(0xFF05FFA1) : Colors.white12,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (bleService.isConnected ? const Color(0xFF05FFA1) : Colors.redAccent).withAlpha(40),
                ),
                child: Icon(
                  bleService.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: bleService.isConnected ? const Color(0xFF05FFA1) : Colors.redAccent,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bleService.isConnected
                          ? 'ĐÃ KẾT NỐI: ${bleService.connectedDeviceName}'
                          : (bleService.isConnecting ? 'ĐANG KẾT NỐI...' : 'CHƯA KẾT NỐI ESP32'),
                      style: TextStyle(
                        color: bleService.isConnected ? const Color(0xFF05FFA1) : Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      bleService.isConnected
                          ? 'Sẵn sàng truyền dữ liệu lộ trình & bản đồ'
                          : 'Bấm quét và chọn ESP32 trong danh sách bên dưới',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (bleService.isConnected)
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent.withAlpha(50),
                    foregroundColor: Colors.redAccent,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => bleService.disconnect(),
                  child: const Text('Ngắt', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
            ],
          ),
        ),

        // WiFi Hotspot Configuration Card for iPhone Hotspot connection
        if (bleService.isConnected) _buildWifiConfigCard(bleService),

        // Apple ANCS Notification Guide Banner
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF38BDF8).withAlpha(60)),
          ),
          child: Row(
            children: [
              const Icon(Icons.notifications_active_rounded, color: Color(0xFF38BDF8), size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Để hiện Tên/SĐT cuộc gọi & tin nhắn Zalo/SMS lên ESP32: Vào Cài đặt iPhone > Bluetooth > chạm chữ (i) bên cạnh "ESP32-S3 Navi" > Bật "Chia sẻ thông báo hệ thống".',
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5, height: 1.3),
                ),
              ),
            ],
          ),
        ),

        // Scanning Indicator or Device Count
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'DANH SÁCH THIẾT BỊ (${bleService.discoveredDevices.length})',
                style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5),
              ),
              if (bleService.isScanning)
                const Row(
                  children: [
                    SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00F0FF))),
                    SizedBox(width: 8),
                    Text('Đang quét...', style: TextStyle(color: Color(0xFF00F0FF), fontSize: 12)),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Devices ListView
        Expanded(
          child: bleService.discoveredDevices.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bluetooth_searching, size: 56, color: Colors.white.withAlpha(50)),
                      const SizedBox(height: 12),
                      Text(
                        bleService.isScanning ? 'Đang tìm kiếm ESP32...' : 'Chưa tìm thấy thiết bị nào\nBấm nút quét ở góc trên để bắt đầu',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white54, fontSize: 14),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: bleService.discoveredDevices.length,
                  separatorBuilder: (ctx, idx) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = bleService.discoveredDevices[index];
                    final isThisConnected = bleService.connectedDevice?.remoteId == item.device.remoteId;
                    final isEsp32 = item.name.toLowerCase().contains('esp32') || item.name.toLowerCase().contains('nav');

                    return Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B22),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isThisConnected
                              ? const Color(0xFF05FFA1)
                              : (isEsp32 ? const Color(0xFF00F0FF).withAlpha(120) : Colors.white10),
                        ),
                      ),
                      child: ListTile(
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: isEsp32 ? const Color(0xFF00F0FF).withAlpha(40) : Colors.white10,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            isEsp32 ? Icons.developer_board : Icons.bluetooth,
                            color: isEsp32 ? const Color(0xFF00F0FF) : Colors.white70,
                          ),
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.name,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: isEsp32 ? FontWeight.bold : FontWeight.normal,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isEsp32)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                margin: const EdgeInsets.only(left: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00F0FF).withAlpha(50),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'ESP32',
                                  style: TextStyle(color: Color(0xFF00F0FF), fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text(
                          'RSSI: ${item.rssi} dBm • ID: ${item.device.remoteId.str}',
                          style: const TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isThisConnected
                                ? Colors.redAccent.withAlpha(50)
                                : const Color(0xFF00F0FF),
                            foregroundColor: isThisConnected ? Colors.redAccent : Colors.black,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () {
                            if (isThisConnected) {
                              bleService.disconnect();
                            } else {
                              bleService.connectToDevice(item.device, displayName: item.name);
                            }
                          },
                          child: Text(
                            isThisConnected ? 'Ngắt' : 'Kết nối',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildLogsAndTestingTab(BleService bleService) {
    return Column(
      children: [
        // Quick Test Buttons Bar
        Container(
          padding: const EdgeInsets.all(12),
          color: const Color(0xFF161B22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('GỬI GÓI TIN THỬ NGHIỆM SANG ESP32', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildTestButton('➡️ Rẽ phải 150m', () {
                      final p = EspNavPayload(
                        turnCode: 2,
                        distanceToTurn: 150,
                        totalDistance: 3200,
                        etaMinutes: 8,
                        streetName: 'Nguyen Hue',
                        currentSpeed: 35,
                        stepIndex: 1,
                        totalSteps: 5,
                      );
                      bleService.sendNavPayload(p);
                    }, bleService.isConnected),
                    const SizedBox(width: 8),
                    _buildTestButton('⬅️ Rẽ trái 80m', () {
                      final p = EspNavPayload(
                        turnCode: 6,
                        distanceToTurn: 80,
                        totalDistance: 2100,
                        etaMinutes: 5,
                        streetName: 'Le Loi',
                        currentSpeed: 40,
                        stepIndex: 2,
                        totalSteps: 5,
                      );
                      bleService.sendNavPayload(p);
                    }, bleService.isConnected),
                    const SizedBox(width: 8),
                    _buildTestButton('🔄 Vòng xuyến 300m', () {
                      final p = EspNavPayload(
                        turnCode: 8,
                        distanceToTurn: 300,
                        totalDistance: 1500,
                        etaMinutes: 3,
                        streetName: 'Vong Xuyen Dan Chu',
                        currentSpeed: 25,
                        stepIndex: 3,
                        totalSteps: 5,
                      );
                      bleService.sendNavPayload(p);
                    }, bleService.isConnected),
                    const SizedBox(width: 8),
                    _buildTestButton('🏁 Đã đến nơi', () {
                      final p = EspNavPayload(
                        turnCode: 9,
                        distanceToTurn: 0,
                        totalDistance: 0,
                        etaMinutes: 0,
                        streetName: 'Diem Den',
                        currentSpeed: 0,
                        stepIndex: 5,
                        totalSteps: 5,
                      );
                      bleService.sendNavPayload(p);
                    }, bleService.isConnected),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Logs Header & Clear Button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('NHẬT KÝ TRUYỀN DỮ LIỆU THỜI GIAN THỰC', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
              TextButton(
                onPressed: () => bleService.clearLogs(),
                child: const Text('Xóa nhật ký', style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            ],
          ),
        ),

        // Live Log Console
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF070A0F),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10),
            ),
            child: bleService.logs.isEmpty
                ? const Center(child: Text('Chưa có dữ liệu truyền nhận...', style: TextStyle(color: Colors.white38, fontSize: 13)))
                : ListView.builder(
                    itemCount: bleService.logs.length,
                    itemBuilder: (context, index) {
                      final log = bleService.logs[index];
                      final timeStr = '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}';

                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('[$timeStr] ', style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: 'monospace')),
                            Expanded(
                              child: Text(
                                log.message,
                                style: TextStyle(
                                  color: log.isError
                                      ? Colors.redAccent
                                      : (log.isTx ? const Color(0xFF05FFA1) : const Color(0xFF00F0FF)),
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildTestButton(String label, VoidCallback onPressed, bool isEnabled) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF21262D),
        foregroundColor: isEnabled ? const Color(0xFF00F0FF) : Colors.white38,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: isEnabled ? onPressed : null,
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _buildWifiConfigCard(BleService bleService) {
    final isWifi = bleService.isWifiConnected;
    final isConnecting = bleService.wifiStatus == 'connecting';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isWifi
              ? const Color(0xFF05FFA1)
              : (isConnecting ? Colors.amber : const Color(0xFF00F0FF).withAlpha(100)),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (isWifi
                          ? const Color(0xFF05FFA1)
                          : (isConnecting ? Colors.amber : const Color(0xFF00F0FF)))
                      .withAlpha(40),
                ),
                child: Icon(
                  isWifi
                      ? Icons.wifi_rounded
                      : (isConnecting ? Icons.wifi_find_rounded : Icons.wifi_tethering_rounded),
                  color: isWifi
                      ? const Color(0xFF05FFA1)
                      : (isConnecting ? Colors.amber : const Color(0xFF00F0FF)),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isWifi
                          ? 'WIFI HOTSPOT: ĐÃ KẾT NỐI'
                          : (isConnecting
                              ? 'ĐANG KẾT NỐI WIFI...'
                              : (bleService.wifiStatus == 'wrong_pass'
                                  ? 'SAI MẬT KHẨU WIFI'
                                  : (bleService.wifiStatus == 'no_ssid'
                                      ? 'KHÔNG TÌM THẤY WIFI'
                                      : 'KẾT NỐI WIFI HOTSPOT'))),
                      style: TextStyle(
                        color: isWifi
                            ? const Color(0xFF05FFA1)
                            : (isConnecting
                                ? Colors.amber
                                : (bleService.wifiStatus == 'wrong_pass' || bleService.wifiStatus == 'no_ssid'
                                    ? Colors.redAccent
                                    : Colors.white)),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isWifi
                          ? 'IP: ${bleService.wifiIp}:${bleService.wifiPort} • Stream khi tắt màn hình'
                          : (isConnecting
                              ? 'Đang gửi cấu hình và chờ ESP32 kết nối...'
                              : (bleService.wifiStatus == 'wrong_pass'
                                  ? 'Bấm Cài đặt để nhập lại mật khẩu đúng'
                                  : (bleService.wifiStatus == 'no_ssid'
                                      ? 'Bật "Tối đa hóa tương thích" trên iPhone!'
                                      : 'Truyền bản đồ tốc độ cao & khi tắt màn hình'))),
                      style: TextStyle(
                        color: (bleService.wifiStatus == 'wrong_pass' || bleService.wifiStatus == 'no_ssid')
                            ? Colors.redAccent.withAlpha(220)
                            : Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isWifi
                      ? Colors.white10
                      : const Color(0xFF00F0FF).withAlpha(40),
                  foregroundColor: isWifi ? Colors.white70 : const Color(0xFF00F0FF),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => _showWifiConfigSheet(context, bleService),
                child: Text(
                  isWifi ? 'Đổi WiFi' : 'Cài đặt',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
          ),
          if (isWifi) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF05FFA1).withAlpha(20),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: Color(0xFF05FFA1), size: 14),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Bản đồ & Lộ trình sẽ truyền qua WiFi kể cả khi iPhone khóa/tắt màn hình.',
                      style: TextStyle(color: Color(0xFF05FFA1), fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showWifiConfigSheet(BuildContext context, BleService bleService) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.wifi_tethering_rounded, color: Color(0xFF00F0FF), size: 24),
                      const SizedBox(width: 10),
                      const Text(
                        'Kết nối WiFi Hotspot iPhone',
                        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.amber.withAlpha(120)),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 16),
                            SizedBox(width: 6),
                            Text('LƯU Ý BẮT BUỘC ĐỂ KẾT NỐI IPHONE:', style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 12)),
                          ],
                        ),
                        SizedBox(height: 6),
                        Text('1. Mở Cài đặt iPhone > Điểm phát sóng cá nhân > BẬT "Cho phép người khác kết nối".', style: TextStyle(color: Colors.white70, fontSize: 11.5)),
                        SizedBox(height: 4),
                        Text('2. ⚠️ BẮT BUỘC: BẬT "Tối đa hóa khả năng tương thích" (Maximize Compatibility) để iPhone phát sóng 2.4GHz cho ESP32. Nếu không bật, ESP32 không thể kết nối!', style: TextStyle(color: Color(0xFF05FFA1), fontWeight: FontWeight.bold, fontSize: 11.5)),
                        SizedBox(height: 4),
                        Text('3. Giữ màn hình Điểm phát sóng cá nhân đang mở trên iPhone trong lúc ESP32 kết nối.', style: TextStyle(color: Colors.white70, fontSize: 11.5)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('TÊN ĐIỂM PHÁT SÓNG (SSID)', style: TextStyle(color: Colors.white60, fontSize: 11, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _wifiSsidController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Ví dụ: iPhone của Duc',
                      hintStyle: const TextStyle(color: Colors.white30),
                      filled: true,
                      fillColor: const Color(0xFF0D1117),
                      prefixIcon: const Icon(Icons.wifi, color: Color(0xFF00F0FF), size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text('MẬT KHẨU WIFI', style: TextStyle(color: Colors.white60, fontSize: 11, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _wifiPassController,
                    obscureText: _obscureWifiPass,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Nhập mật khẩu Hotspot',
                      hintStyle: const TextStyle(color: Colors.white30),
                      filled: true,
                      fillColor: const Color(0xFF0D1117),
                      prefixIcon: const Icon(Icons.lock_outline, color: Color(0xFF00F0FF), size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(_obscureWifiPass ? Icons.visibility_off : Icons.visibility, color: Colors.white54, size: 20),
                        onPressed: () {
                          setModalState(() {
                            _obscureWifiPass = !_obscureWifiPass;
                          });
                        },
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00F0FF),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        final ssid = _wifiSsidController.text.trim();
                        final pass = _wifiPassController.text.trim();
                        if (ssid.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Vui lòng nhập tên WiFi (SSID)')),
                          );
                          return;
                        }
                        bleService.sendWifiConfig(ssid, pass);
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Đã gửi thông tin WiFi "$ssid" sang ESP32. Đang chờ kết nối...'),
                            backgroundColor: const Color(0xFF161B22),
                          ),
                        );
                      },
                      child: const Text(
                        'Gửi sang ESP32 để kết nối',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
