import 'package:flutter/material.dart';
import '../models/map_provider.dart';
import '../services/apple_maps_service.dart';
import '../services/map_settings_service.dart';

/// Modal Sheet cho phép người dùng chọn giữa Goong API và Apple Maps (Native)
void showMapProviderSettingsSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => const _MapProviderSheetContent(),
  );
}

class _MapProviderSheetContent extends StatefulWidget {
  const _MapProviderSheetContent();

  @override
  State<_MapProviderSheetContent> createState() => _MapProviderSheetContentState();
}

class _MapProviderSheetContentState extends State<_MapProviderSheetContent> {
  final MapSettingsService _settings = MapSettingsService();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _settings,
      builder: (context, _) {
        final current = _settings.currentProvider;

        return Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          decoration: const BoxDecoration(
            color: Color(0xFF131B26),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: Color(0xFF00F0FF), width: 1.2),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Title Header
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: const Color(0xFF00F0FF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.alt_route_rounded, color: Color(0xFF00F0FF), size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Nhà cung cấp Bản đồ & Dẫn đường',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Chọn dịch vụ tìm kiếm địa điểm và tính lộ trình',
                          style: TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // Option 1: Apple Maps Native (iOS)
              _buildProviderCard(
                provider: MapProvider.appleMaps,
                title: 'Apple Maps (Native iOS)',
                badge: 'Khuyên dùng • Miễn phí 100%',
                badgeColor: const Color(0xFF05FFA1),
                description:
                    'Sử dụng Apple MapKit gốc (MKLocalSearch & MKDirections) trực tiếp trên iPhone. Miễn phí 100%, không giới hạn lượt dùng, mượt mà và tiết kiệm pin.',
                icon: Icons.map_rounded,
                iconColor: const Color(0xFF00F0FF),
                isSelected: current == MapProvider.appleMaps,
                isSupportedOnDevice: AppleMapsService.isSupported,
                onTap: () {
                  _settings.setProvider(MapProvider.appleMaps);
                  _showToast(context, 'Đã kích hoạt Apple Maps (Native iOS)');
                },
              ),

              const SizedBox(height: 12),

              // Option 2: Goong API
              _buildProviderCard(
                provider: MapProvider.goong,
                title: 'Goong API (Key riêng)',
                badge: 'Tối ưu ngõ hẻm VN',
                badgeColor: const Color(0xFFFF9F1C),
                description:
                    'Tối ưu tuyến đường xe máy, đường tắt và ngõ ngách đặc thù tại Việt Nam. Sử dụng lượt gọi API từ cấu hình Goong Config.',
                icon: Icons.navigation_rounded,
                iconColor: const Color(0xFFFF9F1C),
                isSelected: current == MapProvider.goong,
                isSupportedOnDevice: true,
                onTap: () {
                  _settings.setProvider(MapProvider.goong);
                  _showToast(context, 'Đã chuyển sang Goong API');
                },
              ),

              const SizedBox(height: 16),

              // Reversible note for user peace-of-mind
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B111A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white10),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.swap_horiz_rounded, color: Color(0xFF00F0FF), size: 18),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Bạn có thể chuyển đổi qua lại giữa Apple Maps và Goong bất cứ lúc nào trong Menu.',
                        style: TextStyle(color: Colors.white60, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildProviderCard({
    required MapProvider provider,
    required String title,
    required String badge,
    required Color badgeColor,
    required String description,
    required IconData icon,
    required Color iconColor,
    required bool isSelected,
    required bool isSupportedOnDevice,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: isSupportedOnDevice ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? iconColor.withValues(alpha: 0.12)
              : const Color(0xFF0B111A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? iconColor : Colors.white12,
            width: isSelected ? 1.8 : 1.0,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: badgeColor.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: badgeColor.withValues(alpha: 0.5), width: 0.8),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(color: badgeColor, fontSize: 9, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: const TextStyle(color: Colors.white54, fontSize: 11, height: 1.3),
                  ),
                  if (!isSupportedOnDevice) ...[
                    const SizedBox(height: 4),
                    const Text(
                      '⚠️ Chỉ khả dụng trên hệ điều hành iOS (iPhone/iPad).',
                      style: TextStyle(color: Colors.orangeAccent, fontSize: 10),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              isSelected ? Icons.check_circle_rounded : Icons.radio_button_off_rounded,
              color: isSelected ? iconColor : Colors.white24,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  void _showToast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF00F0FF),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
