import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/esp_payload.dart';
import '../services/ble_service.dart';
import '../services/phone_call_service.dart';
import '../widgets/firmware_update_sheet.dart';

class BleScreen extends StatefulWidget {
  final VoidCallback? onBackToMap;
  const BleScreen({super.key, this.onBackToMap});

  @override
  State<BleScreen> createState() => _BleScreenState();
}

class _BleScreenState extends State<BleScreen> with SingleTickerProviderStateMixin {
  static const Color _bgColor = Color(0xFFF2F2F7);
  static const Color _cardColor = Color(0xFFFFFFFF);
  static const Color _primaryBlue = Color(0xFF007AFF);
  static const Color _successGreen = Color(0xFF34C759);
  static const Color _dangerRed = Color(0xFFFF3B30);
  static const Color _warningAmber = Color(0xFFFF9500);
  static const Color _textPrimary = Color(0xFF1C1C1E);
  static const Color _textSecondary = Color(0xFF8E8E93);
  static const Color _borderColor = Color(0xFFE5E5EA);

  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final bleService = Provider.of<BleService>(context, listen: false);
      bleService.checkSystemDevices();
      if (!bleService.isConnected && !bleService.isScanning) {
        bleService.startScan();
      }
    });
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
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _cardColor,
        foregroundColor: _textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        surfaceTintColor: _cardColor,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: _primaryBlue, size: 20),
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
            Icon(Icons.bluetooth_searching_rounded, color: _primaryBlue, size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Kết nối Hoa hướng dương',
                style: TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  letterSpacing: -0.3,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded, color: _primaryBlue),
            tooltip: 'Đổi tên Bluetooth & Wi-Fi ESP32',
            onPressed: () => _showDeviceConfigSheet(context, bleService),
          ),
          IconButton(
            icon: Icon(
              bleService.isScanning ? Icons.stop_circle_outlined : Icons.refresh_rounded,
              color: _primaryBlue,
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            decoration: const BoxDecoration(
              color: _cardColor,
              border: Border(bottom: BorderSide(color: _borderColor, width: 0.8)),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorColor: _primaryBlue,
              indicatorWeight: 2.5,
              labelColor: _primaryBlue,
              unselectedLabelColor: _textSecondary,
              labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              tabs: const [
                Tab(
                  icon: Icon(Icons.devices_rounded, size: 18),
                  iconMargin: EdgeInsets.only(bottom: 2),
                  text: 'Thiết bị & Cài đặt',
                ),
                Tab(
                  icon: Icon(Icons.terminal_rounded, size: 18),
                  iconMargin: EdgeInsets.only(bottom: 2),
                  text: 'Nhật ký TX/RX',
                ),
              ],
            ),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDeviceListTab(bleService),
          _buildLogsAndTestingTab(bleService),
        ],
      ),
    );
  }

  Widget _buildDeviceListTab(BleService bleService) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. BLE Connection Status Card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _cardColor,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: bleService.isConnected
                          ? _successGreen.withAlpha(140)
                          : _borderColor,
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(10),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: (bleService.isConnected ? _successGreen : _dangerRed).withAlpha(24),
                        ),
                        child: Icon(
                          bleService.isConnected
                              ? Icons.bluetooth_connected_rounded
                              : Icons.bluetooth_disabled_rounded,
                          color: bleService.isConnected ? _successGreen : _dangerRed,
                          size: 23,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              bleService.isConnected
                                  ? 'Đã kết nối: ${bleService.connectedDeviceName}'
                                  : (bleService.isConnecting
                                      ? 'Đang kết nối...'
                                      : 'Chưa kết nối ESP32'),
                              style: TextStyle(
                                color: bleService.isConnected ? const Color(0xFF1E8E3E) : _textPrimary,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              bleService.isConnected
                                  ? 'Sẵn sàng truyền dữ liệu lộ trình & bản đồ'
                                  : 'Bấm quét hoặc chạm vào thiết bị ESP32 bên dưới',
                              style: const TextStyle(color: _textSecondary, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      if (bleService.isConnected) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          style: TextButton.styleFrom(
                            backgroundColor: _dangerRed.withAlpha(20),
                            foregroundColor: _dangerRed,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          ),
                          onPressed: () => bleService.disconnect(),
                          child: const Text('Ngắt', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // 2. ESP32 Bluetooth Name & Wi-Fi SoftAP Settings Card
                _buildDeviceConfigCard(bleService),

                const SizedBox(height: 12),

                // 2b. ESP32 Firmware OTA Update via .zip Card
                _buildFirmwareUpdateCard(bleService),

                const SizedBox(height: 12),

                // 3. Apple ANCS Pairing Guide Banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: _primaryBlue.withAlpha(14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _primaryBlue.withAlpha(45)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 1),
                        child: Icon(Icons.notifications_active_rounded, color: _primaryBlue, size: 20),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Khi ghép đôi lần đầu: Bấm "Ghép đôi" (Pair) & "Cho phép" trên iPhone. Sau đó vào Cài đặt > Bluetooth > chữ (i) bên cạnh "${bleService.customBleName}" > Bật "Chia sẻ thông báo hệ thống" để hiện cuộc gọi, tin nhắn & nhạc.',
                          style: const TextStyle(color: Color(0xFF3A3A3C), fontSize: 11.5, height: 1.38),
                        ),
                      ),
                    ],
                  ),
                ),

                // 4. System Connected (Bonded) ESP32 Fast-Connect Card
                if (bleService.systemBondedDevice != null && !bleService.isConnected) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _primaryBlue, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: _primaryBlue.withAlpha(24),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _primaryBlue.withAlpha(22),
                          ),
                          child: const Icon(Icons.bluetooth_connected_rounded, color: _primaryBlue, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                bleService.systemBondedDevice!.platformName.isNotEmpty
                                    ? bleService.systemBondedDevice!.platformName
                                    : bleService.customBleName,
                                style: const TextStyle(
                                  color: _textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                'Đã ghép nối sẵn trong Bluetooth iPhone',
                                style: TextStyle(color: _primaryBlue, fontSize: 11.5, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _primaryBlue,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          ),
                          onPressed: () => bleService.connectToDevice(
                            bleService.systemBondedDevice!,
                            displayName: bleService.systemBondedDevice!.platformName.isNotEmpty
                                ? bleService.systemBondedDevice!.platformName
                                : bleService.customBleName,
                          ),
                          child: const Text('Kết nối', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 16),

                // 5. Device List Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'DANH SÁCH THIẾT BỊ (${bleService.discoveredDevices.length})',
                      style: const TextStyle(
                        color: _textSecondary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                    if (bleService.isScanning)
                      const Row(
                        children: [
                          SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2, color: _primaryBlue),
                          ),
                          SizedBox(width: 6),
                          Text('Đang quét...', style: TextStyle(color: _primaryBlue, fontSize: 12, fontWeight: FontWeight.w600)),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),

        // 6. Discovered Devices List
        if (bleService.discoveredDevices.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bluetooth_searching_rounded, size: 52, color: _textSecondary.withAlpha(110)),
                  const SizedBox(height: 10),
                  Text(
                    bleService.isScanning
                        ? 'Đang tìm kiếm ${bleService.customBleName}...'
                        : 'Chưa tìm thấy thiết bị nào\nBấm nút làm mới ở góc trên để quét',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _textSecondary, fontSize: 13.5, height: 1.4),
                  ),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            sliver: SliverList.separated(
              itemCount: bleService.discoveredDevices.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final item = bleService.discoveredDevices[index];
                final isThisConnected = bleService.connectedDevice?.remoteId == item.device.remoteId;
                final lowerName = item.name.toLowerCase();
                final customLower = bleService.customBleName.trim().toLowerCase();
                final isEsp32 = lowerName.contains('ysiduc') ||
                    lowerName.contains('esp32') ||
                    lowerName.contains('nav') ||
                    (customLower.isNotEmpty && lowerName.contains(customLower));

                return Container(
                  decoration: BoxDecoration(
                    color: _cardColor,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isThisConnected
                          ? _successGreen
                          : (isEsp32 ? _primaryBlue.withAlpha(110) : _borderColor),
                      width: isThisConnected ? 1.5 : 1.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(6),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: isEsp32 ? _primaryBlue.withAlpha(20) : const Color(0xFFF2F2F7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        isEsp32 ? Icons.developer_board_rounded : Icons.bluetooth_rounded,
                        color: isEsp32 ? _primaryBlue : _textSecondary,
                        size: 21,
                      ),
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            style: TextStyle(
                              color: _textPrimary,
                              fontWeight: isEsp32 ? FontWeight.w700 : FontWeight.w500,
                              fontSize: 14.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isEsp32)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            margin: const EdgeInsets.only(left: 6),
                            decoration: BoxDecoration(
                              color: _primaryBlue.withAlpha(22),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'ESP32',
                              style: TextStyle(color: _primaryBlue, fontSize: 10, fontWeight: FontWeight.w700),
                            ),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      'RSSI: ${item.rssi} dBm • ${item.device.remoteId.str}',
                      style: const TextStyle(color: _textSecondary, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isThisConnected ? _dangerRed.withAlpha(22) : _primaryBlue,
                        foregroundColor: isThisConnected ? _dangerRed : Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
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

  Widget _buildFirmwareUpdateCard(BleService bleService) {
    final fwVer = bleService.espFirmwareVersion;
    final subtitle = fwVer != null && fwVer.isNotEmpty
        ? 'Phiên bản trên mạch: v$fwVer • Nạp qua file .zip'
        : 'Chọn file firmware .zip để cập nhật ESP32 qua Wi-Fi';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _borderColor, width: 1.1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF5856D6).withAlpha(22),
            ),
            child: const Icon(
              Icons.system_update_rounded,
              color: Color(0xFF5856D6),
              size: 21,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Cập nhật Firmware ESP32',
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(color: _textSecondary, fontSize: 11.5),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF5856D6).withAlpha(22),
              foregroundColor: const Color(0xFF5856D6),
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.folder_zip_rounded, size: 15),
            label: const Text('Nạp .zip', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
            onPressed: () => showFirmwareUpdateSheet(context),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceConfigCard(BleService bleService) {
    final isWifi = bleService.isWifiConnected;
    final useHotspot = bleService.hotspotModeEnabled;
    final staJoined = bleService.espStaConnectedToHotspot;
    final hotspotName = bleService.hotspotSsid.trim();

    final String subtitleText;
    if (isWifi) {
      subtitleText =
          '${bleService.wifiIp}:${bleService.wifiPort} • Stream 30 FPS${useHotspot ? ' (Hotspot)' : ''}';
    } else if (useHotspot) {
      subtitleText = staJoined
          ? 'ESP32 IP: ${bleService.espStaIp} • Chờ stream bản đồ'
          : 'BT: ${bleService.customBleName} • Hotspot: ${hotspotName.isNotEmpty ? hotspotName : 'Chưa nhập tên'}';
    } else {
      subtitleText = 'Bluetooth: ${bleService.customBleName} • Wi-Fi: ${bleService.wifiSsid}';
    }

    final String statusHint;
    if (isWifi) {
      statusHint = 'Đang truyền bản đồ HD qua Wi-Fi ổn định (${bleService.wifiIp}:${bleService.wifiPort}).';
    } else if (useHotspot) {
      if (hotspotName.isEmpty) {
        statusHint = 'Bấm "Cài đặt" để nhập Tên Wi-Fi cá nhân và Mật khẩu Hotspot trên iPhone.';
      } else if (staJoined) {
        statusHint = 'ESP32 đã vào Wi-Fi "$hotspotName" (${bleService.espStaIp}). Đang mở luồng stream...';
      } else {
        statusHint =
            'Bật Điểm phát sóng cá nhân "$hotspotName" trên iPhone; ESP32 sẽ tự kết nối để nhận bản đồ và bạn vẫn dùng mạng SIM.';
      }
    } else {
      statusHint =
          'Vào Wi-Fi "${bleService.wifiSsid}" (Mật khẩu: ${bleService.wifiPass}) trên iPhone để truyền bản đồ 30 FPS.';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isWifi ? _successGreen.withAlpha(150) : _borderColor,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (isWifi ? _successGreen : _primaryBlue).withAlpha(22),
                ),
                child: Icon(
                  isWifi
                      ? Icons.wifi_tethering_rounded
                      : (useHotspot ? Icons.cell_wifi_rounded : Icons.wifi_rounded),
                  color: isWifi ? _successGreen : _primaryBlue,
                  size: 21,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isWifi ? 'Wi-Fi Stream ESP32: Đã kết nối' : 'Cài đặt Bluetooth & Wi-Fi ESP32',
                      style: TextStyle(
                        color: isWifi ? const Color(0xFF1E8E3E) : _textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitleText,
                      style: const TextStyle(color: _textSecondary, fontSize: 11.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryBlue.withAlpha(20),
                  foregroundColor: _primaryBlue,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.edit_rounded, size: 15),
                label: const Text('Cài đặt', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                onPressed: () => _showDeviceConfigSheet(context, bleService),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: useHotspot ? _primaryBlue.withAlpha(14) : _bgColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: useHotspot ? _primaryBlue.withAlpha(70) : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.wifi_tethering_rounded,
                  color: useHotspot ? _primaryBlue : _textSecondary,
                  size: 19,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Hotspot cá nhân',
                        style: TextStyle(
                          color: _textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        useHotspot
                            ? (hotspotName.isNotEmpty
                                ? 'Bật: ESP32 vào "$hotspotName" (giữ mạng SIM)'
                                : 'Chưa nhập tên Wi-Fi cá nhân')
                            : 'Tắt: ESP32 tự phát Wi-Fi "${bleService.wifiSsid}"',
                        style: const TextStyle(color: _textSecondary, fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: useHotspot,
                  activeTrackColor: _successGreen,
                  onChanged: (enabled) => _onHotspotSwitchToggled(context, bleService, enabled),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: isWifi ? _successGreen.withAlpha(18) : const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  isWifi
                      ? Icons.check_circle_rounded
                      : (useHotspot && staJoined ? Icons.sensors_rounded : Icons.wifi_lock_rounded),
                  color: isWifi
                      ? const Color(0xFF1E8E3E)
                      : (useHotspot && staJoined ? _primaryBlue : _textSecondary),
                  size: 15,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    statusHint,
                    style: TextStyle(
                      color: isWifi ? const Color(0xFF1E8E3E) : const Color(0xFF3A3A3C),
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onHotspotSwitchToggled(
    BuildContext context,
    BleService bleService,
    bool enabled,
  ) async {
    final ssid = bleService.hotspotSsid.trim();
    final pass = bleService.hotspotPass;
    if (enabled && (ssid.isEmpty || (pass.isNotEmpty && pass.length < 8))) {
      _showDeviceConfigSheet(context, bleService, initialHotspotEnabled: true);
      return;
    }
    final sent = await bleService.setHotspotMode(enabled);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent
              ? (enabled
                  ? 'Đã chuyển ESP32 sang kết nối Hotspot "$ssid".'
                  : 'Đã chuyển ESP32 về phát Wi-Fi "${bleService.wifiSsid}".')
              : 'Đã lưu chế độ ${enabled ? "Hotspot cá nhân" : "ESP32 phát Wi-Fi"}. Kết nối BLE để đồng bộ ESP32.',
        ),
        backgroundColor: sent ? _successGreen : _warningAmber,
      ),
    );
  }

  void _showDeviceConfigSheet(
    BuildContext context,
    BleService bleService, {
    bool? initialHotspotEnabled,
  }) {
    final bleNameController = TextEditingController(text: bleService.customBleName);
    final ssidController = TextEditingController(text: bleService.wifiSsid);
    final passController = TextEditingController(text: bleService.wifiPass);
    final hotspotSsidController = TextEditingController(text: bleService.hotspotSsid);
    final hotspotPassController = TextEditingController(text: bleService.hotspotPass);
    bool useHotspot = initialHotspotEnabled ?? bleService.hotspotModeEnabled;
    bool obscurePass = false;
    bool obscureHotspotPass = false;
    bool isSaving = false;
    String? validationError;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            return SingleChildScrollView(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 28,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD1D1D6),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _primaryBlue.withAlpha(20),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.tune_rounded, color: _primaryBlue, size: 22),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Cài đặt Bluetooth & Wi-Fi ESP32',
                          style: TextStyle(
                            color: _textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: _textSecondary),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _buildConfigInput(
                    controller: bleNameController,
                    label: 'Tên Bluetooth ESP32',
                    hint: 'Ví dụ: Hoa hướng dương',
                    icon: Icons.bluetooth_rounded,
                    maxLength: 20,
                  ),
                  const SizedBox(height: 12),
                  _buildConfigInput(
                    controller: ssidController,
                    label: 'Tên Wi-Fi phát từ ESP32 (SSID)',
                    hint: 'Ví dụ: Hoa hướng dương',
                    icon: Icons.wifi_rounded,
                    maxLength: 28,
                  ),
                  const SizedBox(height: 12),
                  _buildConfigInput(
                    controller: passController,
                    label: 'Mật khẩu Wi-Fi ESP32 (tối thiểu 8 ký tự)',
                    hint: 'Tối thiểu 8 ký tự WPA2',
                    icon: Icons.lock_outline_rounded,
                    maxLength: 32,
                    obscureText: obscurePass,
                    onToggleObscure: () => setModalState(() => obscurePass = !obscurePass),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: useHotspot ? _primaryBlue.withAlpha(10) : const Color(0xFFF9F9FB),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: useHotspot ? _primaryBlue.withAlpha(90) : _borderColor,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.wifi_tethering_rounded,
                              color: useHotspot ? _primaryBlue : _textSecondary,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Hotspot cá nhân (giữ mạng SIM)',
                                    style: TextStyle(
                                      color: _textPrimary,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    'Bật: ESP32 vào Wi-Fi dưới đây • Tắt: ESP32 phát Wi-Fi',
                                    style: TextStyle(color: _textSecondary, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: useHotspot,
                              activeTrackColor: _successGreen,
                              onChanged: (val) => setModalState(() => useHotspot = val),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _buildConfigInput(
                          controller: hotspotSsidController,
                          label: 'Tên Wi-Fi / Hotspot cá nhân',
                          hint: 'Tên điểm phát sóng của điện thoại',
                          icon: Icons.phonelink_ring_rounded,
                          maxLength: 32,
                        ),
                        const SizedBox(height: 10),
                        _buildConfigInput(
                          controller: hotspotPassController,
                          label: 'Mật khẩu Wi-Fi cá nhân (tối thiểu 8 ký tự)',
                          hint: 'Để trống nếu Wi-Fi không mật khẩu',
                          icon: Icons.vpn_key_outlined,
                          maxLength: 63,
                          obscureText: obscureHotspotPass,
                          onToggleObscure: () =>
                              setModalState(() => obscureHotspotPass = !obscureHotspotPass),
                        ),
                      ],
                    ),
                  ),
                  if (validationError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      validationError!,
                      style: const TextStyle(color: _dangerRed, fontSize: 12.5, fontWeight: FontWeight.w500),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _bgColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          bleService.isConnected ? Icons.info_outline_rounded : Icons.warning_amber_rounded,
                          color: bleService.isConnected ? _primaryBlue : _warningAmber,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            bleService.isConnected
                                ? (useHotspot
                                    ? 'Hãy bật Hotspot cá nhân trước khi lưu để ESP32 kết nối ngay. Bạn vẫn dùng được mạng 4G/5G SIM để tải bản đồ.'
                                    : 'Wi-Fi mới áp dụng ngay lập tức. Nếu đổi tên Bluetooth, ESP32 sẽ tự khởi động lại sau 1 giây để phát tên mới.')
                                : 'Chưa kết nối BLE với ESP32. Cài đặt sẽ được lưu và tự đồng bộ khi kết nối lại BLE.',
                            style: const TextStyle(color: Color(0xFF3A3A3C), fontSize: 12, height: 1.38),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primaryBlue,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      icon: isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.save_rounded, size: 19),
                      label: Text(
                        isSaving ? 'Đang gửi sang ESP32...' : 'Lưu & Áp dụng cho ESP32',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                      ),
                      onPressed: isSaving
                          ? null
                          : () async {
                              final newBle = bleNameController.text.trim();
                              final newSsid = ssidController.text.trim();
                              final newPass = passController.text;
                              final newHotspotSsid = hotspotSsidController.text.trim();
                              final newHotspotPass = hotspotPassController.text;
                              if (newBle.isEmpty || newSsid.isEmpty) {
                                setModalState(() =>
                                    validationError = 'Tên Bluetooth và tên Wi-Fi ESP32 không được để trống.');
                                return;
                              }
                              if (newPass.length < 8) {
                                setModalState(() =>
                                    validationError = 'Mật khẩu Wi-Fi ESP32 cần ít nhất 8 ký tự theo chuẩn WPA2.');
                                return;
                              }
                              if (useHotspot && newHotspotSsid.isEmpty) {
                                setModalState(() =>
                                    validationError = 'Vui lòng nhập Tên Wi-Fi / Hotspot cá nhân khi bật chế độ Hotspot.');
                                return;
                              }
                              if (newHotspotPass.isNotEmpty && newHotspotPass.length < 8) {
                                setModalState(() => validationError =
                                    'Mật khẩu Wi-Fi cá nhân phải để trống (Wi-Fi mở) hoặc ít nhất 8 ký tự.');
                                return;
                              }
                              setModalState(() {
                                validationError = null;
                                isSaving = true;
                              });
                              final sent = await bleService.sendDeviceConfig(
                                bleName: newBle,
                                ssid: newSsid,
                                pass: newPass,
                                hotspotMode: useHotspot,
                                hotspotSsid: newHotspotSsid,
                                hotspotPass: newHotspotPass,
                              );
                              if (ctx.mounted) {
                                Navigator.pop(ctx);
                              }
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      sent
                                          ? (useHotspot
                                              ? 'Đã gửi cấu hình & bật Hotspot "$newHotspotSsid" sang ESP32!'
                                              : 'Đã cập nhật BT "$newBle" & Wi-Fi "$newSsid" sang ESP32!')
                                          : 'Đã lưu cấu hình trên app. Hãy kết nối BLE để đồng bộ xuống ESP32.',
                                    ),
                                    backgroundColor: sent ? _successGreen : _warningAmber,
                                  ),
                                );
                              }
                            },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      bleNameController.dispose();
      ssidController.dispose();
      passController.dispose();
      hotspotSsidController.dispose();
      hotspotPassController.dispose();
    });
  }

  Widget _buildConfigInput({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    int maxLength = 28,
    bool obscureText = false,
    VoidCallback? onToggleObscure,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      maxLength: maxLength,
      style: const TextStyle(color: _textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: _textSecondary, fontSize: 13),
        hintStyle: const TextStyle(color: Color(0xFFC7C7CC), fontSize: 13),
        prefixIcon: Icon(icon, color: _primaryBlue, size: 20),
        suffixIcon: onToggleObscure == null
            ? null
            : IconButton(
                icon: Icon(
                  obscureText ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                  color: _textSecondary,
                  size: 20,
                ),
                onPressed: onToggleObscure,
              ),
        counterText: '',
        filled: true,
        fillColor: _bgColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _primaryBlue, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  Widget _buildLogsAndTestingTab(BleService bleService) {
    return Column(
      children: [
        // Quick Test Buttons Bar
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: const BoxDecoration(
            color: _cardColor,
            border: Border(bottom: BorderSide(color: _borderColor, width: 0.8)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'GỬI GÓI TIN THỬ NGHIỆM SANG ESP32',
                style: TextStyle(color: _textSecondary, fontSize: 11, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildTestButton('➡️ Rẽ phải 150m', () {
                      bleService.sendNavPayload(
                        EspNavPayload(
                          isNavigating: true,
                          turnCode: 2,
                          distanceToTurn: 150,
                          totalDistance: 3200,
                          etaMinutes: 8,
                          streetName: 'Nguyen Hue',
                          currentSpeed: 35,
                          stepIndex: 1,
                          totalSteps: 5,
                        ),
                      );
                    }, bleService.isConnected),
                    const SizedBox(width: 8),
                    _buildTestButton('⬅️ Rẽ trái 80m', () {
                      bleService.sendNavPayload(
                        EspNavPayload(
                          isNavigating: true,
                          turnCode: 6,
                          distanceToTurn: 80,
                          totalDistance: 2100,
                          etaMinutes: 5,
                          streetName: 'Le Loi',
                          currentSpeed: 40,
                          stepIndex: 2,
                          totalSteps: 5,
                        ),
                      );
                    }, bleService.isConnected),
                    const SizedBox(width: 8),
                    _buildTestButton('🔄 Vòng xuyến 300m', () {
                      bleService.sendNavPayload(
                        EspNavPayload(
                          isNavigating: true,
                          turnCode: 8,
                          distanceToTurn: 300,
                          totalDistance: 1500,
                          etaMinutes: 3,
                          streetName: 'Vong Xuyen Dan Chu',
                          currentSpeed: 25,
                          stepIndex: 3,
                          totalSteps: 5,
                        ),
                      );
                    }, bleService.isConnected),
                    const SizedBox(width: 8),
                    _buildTestButton('🏁 Đã đến nơi', () {
                      bleService.sendNavPayload(
                        EspNavPayload(
                          isNavigating: true,
                          turnCode: 9,
                          distanceToTurn: 0,
                          totalDistance: 0,
                          etaMinutes: 0,
                          streetName: 'Diem Den',
                          currentSpeed: 0,
                          stepIndex: 5,
                          totalSteps: 5,
                        ),
                      );
                    }, bleService.isConnected),
                    const SizedBox(width: 8),
                    _buildTestButton('📞 Test Cuộc gọi', () {
                      final callService = Provider.of<PhoneCallService>(context, listen: false);
                      callService.triggerMockCall(name: 'Mẹ (0912.345.678)', number: '0912 345 678');
                    }, bleService.isConnected),
                    const SizedBox(width: 8),
                    _buildTestButton('💬 Test Tin nhắn', () {
                      final callService = Provider.of<PhoneCallService>(context, listen: false);
                      callService.triggerMockSms(
                        sender: 'Zalo: Anh Nam',
                        message: 'Bạn đang ở đâu đấy? Về ăn cơm nhé!',
                      );
                    }, bleService.isConnected),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Logs Header & Action Bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'NHẬT KÝ GÓI TIN (TX / RX)',
                      style: TextStyle(color: _textPrimary, fontSize: 11.5, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${bleService.logs.length} bản ghi • MTU: ${bleService.currentMtu}',
                      style: const TextStyle(color: _textSecondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryBlue.withAlpha(20),
                  foregroundColor: _primaryBlue,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.share_rounded, size: 15),
                label: const Text('Xuất file', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                onPressed: bleService.logs.isEmpty
                    ? null
                    : () async {
                        final logText = bleService.exportLogsAsText();
                        await Clipboard.setData(ClipboardData(text: logText));
                        try {
                          await const MethodChannel('com.ysiduc.esp32_nav/location').invokeMethod(
                            'shareLog',
                            {
                              'text': logText,
                              'fileName': 'esp32_tx_rx_log_${DateTime.now().millisecondsSinceEpoch}.txt',
                            },
                          );
                        } catch (_) {}
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Đã mở bảng xuất file và sao chép toàn bộ nhật ký!'),
                              backgroundColor: _successGreen,
                            ),
                          );
                        }
                      },
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.copy_rounded, color: _textSecondary, size: 18),
                tooltip: 'Sao chép nhật ký',
                onPressed: bleService.logs.isEmpty
                    ? null
                    : () async {
                        final logText = bleService.exportLogsAsText();
                        await Clipboard.setData(ClipboardData(text: logText));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Đã sao chép toàn bộ nhật ký!'),
                              backgroundColor: _primaryBlue,
                            ),
                          );
                        }
                      },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: _textSecondary, size: 19),
                tooltip: 'Xóa nhật ký',
                onPressed: () => bleService.clearLogs(),
              ),
            ],
          ),
        ),

        // Live Log Console
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _borderColor),
            ),
            child: bleService.logs.isEmpty
                ? const Center(
                    child: Text(
                      'Chưa có dữ liệu truyền nhận...',
                      style: TextStyle(color: _textSecondary, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    itemCount: bleService.logs.length,
                    itemBuilder: (context, index) {
                      final log = bleService.logs[index];
                      final timeStr =
                          '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}';

                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '[$timeStr] ',
                              style: const TextStyle(
                                color: _textSecondary,
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                            Expanded(
                              child: Text(
                                log.message,
                                style: TextStyle(
                                  color: log.isError
                                      ? _dangerRed
                                      : (log.isTx ? const Color(0xFF1E8E3E) : _primaryBlue),
                                  fontSize: 11.5,
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
        backgroundColor: _bgColor,
        foregroundColor: isEnabled ? _primaryBlue : _textSecondary,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: isEnabled ? _primaryBlue.withAlpha(60) : _borderColor),
        ),
      ),
      onPressed: isEnabled ? onPressed : null,
      child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}
