import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/esp_payload.dart';
import '../services/ble_service.dart';

class BleScreen extends StatefulWidget {
  const BleScreen({super.key});

  @override
  State<BleScreen> createState() => _BleScreenState();
}

class _BleScreenState extends State<BleScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
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
              const SizedBox(height: 10),
              // Notification Alert Test Row
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildTestButton('📞 Test Cuộc gọi', () {
                      bleService.sendAlertNotification(
                        type: 'CALL',
                        title: 'Nguyễn Văn A',
                        message: 'Cuộc gọi đến từ iPhone',
                      );
                    }, bleService.isConnected),
                    const SizedBox(width: 8),
                    _buildTestButton('💬 Test Tin nhắn SMS', () {
                      bleService.sendAlertNotification(
                        type: 'SMS',
                        title: 'Mẹ',
                        message: 'Con về ăn cơm nhé!',
                      );
                    }, bleService.isConnected),
                    const SizedBox(width: 8),
                    _buildTestButton('💬 Test Zalo', () {
                      bleService.sendAlertNotification(
                        type: 'ZALO',
                        title: 'Zalo Bạn Thân',
                        message: 'Đang ở đâu thế em?',
                      );
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
}
