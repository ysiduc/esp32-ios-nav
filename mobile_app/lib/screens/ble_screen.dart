import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ble_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_shadows.dart';
import '../theme/app_typography.dart';
import '../widgets/common/map_card.dart';
import '../widgets/common/primary_action_button.dart';
import '../widgets/common/section_header.dart';
import '../widgets/common/status_badge.dart';
import '../widgets/common/empty_state_card.dart';

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
    _wifiSsidController.dispose();
    _wifiPassController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: AppColors.primary, size: 20),
          tooltip: 'Quay lại Bản đồ',
          onPressed: () {
            if (widget.onBackToMap != null) {
              widget.onBackToMap!();
            } else if (Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          },
        ),
        title: const Text('Kết nối Thiết bị', style: AppTypography.title2),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.canvas,
              borderRadius: AppRadius.roundedMd,
              border: Border.all(color: AppColors.border, width: 0.8),
            ),
            child: TabBar(
              controller: _tabController,
              dividerColor: Colors.transparent,
              dividerHeight: 0,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                boxShadow: AppShadows.card,
              ),
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.textSecondary,
              labelStyle: AppTypography.headline,
              unselectedLabelStyle: AppTypography.body,
              tabs: const [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bluetooth_rounded, size: 18),
                      SizedBox(width: 6),
                      Text('Bluetooth BLE'),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.wifi_rounded, size: 18),
                      SizedBox(width: 6),
                      Text('WiFi Hotspot'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildBleTab(context, bleService),
          _buildWifiTab(context, bleService),
        ],
      ),
    );
  }

  Widget _buildBleTab(BuildContext context, BleService bleService) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        // Hero Connection Card
        _buildHeroStatusCard(bleService),
        const SizedBox(height: 14),

        // System Bonded Fast Connect Card (if bonded in iOS)
        if (bleService.systemBondedDevice != null && !bleService.isConnected) ...[
          MapCard(
            padding: const EdgeInsets.all(14),
            border: Border.all(color: AppColors.primary.withAlpha(80), width: 1.2),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.bluetooth_connected_rounded, color: AppColors.primary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bleService.systemBondedDevice!.platformName.isNotEmpty
                            ? bleService.systemBondedDevice!.platformName
                            : 'ysiducw',
                        style: AppTypography.headline,
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Đã ghép đôi iOS (Hệ thống iPhone)',
                        style: AppTypography.caption,
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: const RoundedRectangleBorder(borderRadius: AppRadius.roundedMd),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                  onPressed: () => bleService.connectToDevice(
                    bleService.systemBondedDevice!,
                    displayName: bleService.systemBondedDevice!.platformName.isNotEmpty
                        ? bleService.systemBondedDevice!.platformName
                        : 'ysiducw',
                  ),
                  child: const Text('Kết nối ngay', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],

        // Device List Section
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            SectionHeader(
              title: 'Thiết bị xung quanh (${bleService.discoveredDevices.length})',
              padding: EdgeInsets.zero,
            ),
            if (bleService.isScanning)
              const Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                  ),
                  SizedBox(width: 6),
                  Text('Đang quét...', style: AppTypography.caption),
                ],
              )
            else
              TextButton.icon(
                icon: const Icon(Icons.refresh_rounded, size: 16, color: AppColors.primary),
                label: const Text('Quét lại', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600, fontSize: 13)),
                onPressed: () => bleService.startScan(),
              ),
          ],
        ),
        const SizedBox(height: 8),

        // Device List or Empty State
        if (bleService.discoveredDevices.isEmpty)
          EmptyStateCard(
            icon: Icons.bluetooth_searching_rounded,
            title: bleService.isScanning ? 'Đang tìm kiếm ESP32...' : 'Chưa tìm thấy thiết bị',
            description: bleService.isScanning
                ? 'Hãy đảm bảo thiết bị ESP32 đã bật nguồn và ở gần bạn.'
                : 'Bấm nút "Quét lại" để tìm kiếm thiết bị xung quanh.',
            action: !bleService.isScanning
                ? PrimaryActionButton(
                    label: 'Bắt đầu quét',
                    icon: Icons.bluetooth_searching_rounded,
                    width: 180,
                    height: 42,
                    onPressed: () => bleService.startScan(),
                  )
                : null,
          )
        else
          MapCard(
            padding: EdgeInsets.zero,
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: bleService.discoveredDevices.length,
              separatorBuilder: (_, __) => Container(height: 0.5, margin: const EdgeInsets.only(left: 64, right: 16), color: AppColors.border),
              itemBuilder: (ctx, i) {
                final item = bleService.discoveredDevices[i];
                final d = item.device;
                final name = d.platformName.isNotEmpty ? d.platformName : 'Thiết bị ESP32';
                final isThisConnected = bleService.isConnected && bleService.connectedDevice?.remoteId == d.remoteId;

                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: isThisConnected ? AppColors.successLight : AppColors.canvas,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.bluetooth_rounded,
                      color: isThisConnected ? AppColors.success : AppColors.primary,
                      size: 20,
                    ),
                  ),
                  title: Text(
                    name,
                    style: AppTypography.headline,
                  ),
                  subtitle: Text(
                    'ID: ${d.remoteId.str}  •  RSSI: ${item.rssi} dBm',
                    style: AppTypography.caption,
                  ),
                  trailing: isThisConnected
                      ? OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.danger,
                            side: const BorderSide(color: AppColors.danger, width: 0.8),
                            shape: const RoundedRectangleBorder(borderRadius: AppRadius.roundedMd),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          ),
                          onPressed: () => bleService.disconnect(),
                          child: const Text('Ngắt', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        )
                      : ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: const RoundedRectangleBorder(borderRadius: AppRadius.roundedMd),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          ),
                          onPressed: () => bleService.connectToDevice(d, displayName: name),
                          child: const Text('Kết nối', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                        ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildHeroStatusCard(BleService bleService) {
    final isConnected = bleService.isConnected;

    return MapCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusBadge(
                text: isConnected
                    ? 'ĐÃ KẾT NỐI'
                    : (bleService.isConnecting ? 'ĐANG KẾT NỐI...' : (bleService.isScanning ? 'ĐANG QUÉT' : 'CHƯA KẾT NỐI')),
                color: isConnected
                    ? AppColors.success
                    : (bleService.isConnecting || bleService.isScanning ? AppColors.warning : AppColors.textSecondary),
                icon: isConnected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            isConnected ? (bleService.connectedDeviceName ?? 'ESP32 Device') : 'Sẵn sàng kết nối',
            style: AppTypography.largeTitle,
          ),
          const SizedBox(height: 4),
          Text(
            isConnected
                ? 'Dữ liệu điều hướng đang được truyền trực tiếp đến màn hình ESP32.'
                : 'Bật nguồn ESP32 và đảm bảo Bluetooth trên iPhone đang bật.',
            style: AppTypography.subheadline,
          ),
          if (isConnected) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(color: AppColors.danger, width: 0.8),
                      shape: const RoundedRectangleBorder(borderRadius: AppRadius.roundedMd),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    label: const Text('Ngắt kết nối', style: TextStyle(fontWeight: FontWeight.w600)),
                    onPressed: () => bleService.disconnect(),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWifiTab(BuildContext context, BleService bleService) {
    final isWifi = bleService.isWifiConnected;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        // WiFi Status Card
        MapCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  StatusBadge(
                    text: isWifi ? 'WIFI HOTSPOT ĐÃ KẾT NỐI' : 'CHƯA KẾT NỐI WIFI',
                    color: isWifi ? AppColors.success : AppColors.textSecondary,
                    icon: Icons.wifi_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                isWifi ? 'IP: ${bleService.wifiIp}' : 'Điểm phát sóng iPhone',
                style: AppTypography.title2,
              ),
              const SizedBox(height: 4),
              Text(
                isWifi
                    ? 'ESP32 đang nhận luồng hình ảnh 20-30 FPS mượt mà qua WiFi Hotspot.'
                    : 'Gửi tên và mật khẩu Hotspot của iPhone để ESP32 tự động kết nối.',
                style: AppTypography.subheadline,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Config Form Card
        const SectionHeader(title: 'Cấu hình Điểm phát sóng (Hotspot)', padding: EdgeInsets.zero),
        const SizedBox(height: 8),
        MapCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Tên Hotspot (Tên iPhone trong Cài đặt)', style: AppTypography.footnote),
              const SizedBox(height: 6),
              TextField(
                controller: _wifiSsidController,
                decoration: const InputDecoration(
                  hintText: 'Ví dụ: iPhone của tôi',
                  filled: true,
                  fillColor: AppColors.canvas,
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: AppRadius.roundedMd,
                    borderSide: BorderSide(color: AppColors.border, width: 0.8),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text('Mật khẩu Hotspot iPhone', style: AppTypography.footnote),
              const SizedBox(height: 6),
              TextField(
                controller: _wifiPassController,
                obscureText: true,
                decoration: const InputDecoration(
                  hintText: 'Nhập mật khẩu WiFi Hotspot',
                  filled: true,
                  fillColor: AppColors.canvas,
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: AppRadius.roundedMd,
                    borderSide: BorderSide(color: AppColors.border, width: 0.8),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              PrimaryActionButton(
                label: 'Gửi cấu hình sang ESP32',
                icon: Icons.send_rounded,
                onPressed: bleService.isConnected
                    ? () async {
                        final success = await bleService.sendWifiCredentials(
                          _wifiSsidController.text.trim(),
                          _wifiPassController.text.trim(),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(success
                                  ? 'Đã gửi Hotspot sang ESP32 thành công!'
                                  : 'Gửi cấu hình thất bại! Hãy kiểm tra lại kết nối Bluetooth.'),
                              backgroundColor: success ? AppColors.success : AppColors.danger,
                            ),
                          );
                        }
                      }
                    : null,
              ),
              if (!bleService.isConnected) ...[
                const SizedBox(height: 8),
                const Text(
                  'Cần kết nối Bluetooth với ESP32 trước để gửi cấu hình WiFi.',
                  style: TextStyle(color: AppColors.warning, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Guidelines card
        MapCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text("HƯỚNG DẪN KẾT NỐI HOTSPOT:", style: AppTypography.headline),
              SizedBox(height: 8),
              Text(
                "1. Bật Điểm truy cập cá nhân (Personal Hotspot) trong Cài đặt iPhone.",
                style: AppTypography.subheadline,
              ),
              SizedBox(height: 4),
              Text(
                "2. Bật tùy chọn Tối đa hóa khả năng tương thích (Maximize Compatibility) nếu có.",
                style: AppTypography.subheadline,
              ),
              SizedBox(height: 4),
              Text(
                "3. Luồng hình ảnh bản đồ sẽ tự động chuyển sang tốc độ cao (20-30 FPS).",
                style: AppTypography.subheadline,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
