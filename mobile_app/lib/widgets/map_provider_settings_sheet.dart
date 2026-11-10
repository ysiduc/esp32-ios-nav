import 'package:flutter/material.dart';
import '../models/map_provider.dart';
import '../services/apple_maps_service.dart';
import '../services/map_settings_service.dart';

/// Modal Sheet chuẩn phong cách iOS cho phép chọn chế độ kết hợp Goong Search + Apple Maps Routing
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
            color: Color(0xFFF2F2F7),
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag Handle
              Center(
                child: Container(
                  width: 38,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),

              // Title Header
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF007AFF).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.alt_route_rounded, color: Color(0xFF007AFF), size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Dịch vụ Bản đồ & Dẫn đường',
                          style: TextStyle(
                            color: Color(0xFF1C1C1E),
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Tuỳ chỉnh bộ máy tìm kiếm và tính toán lộ trình',
                          style: TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              // Option 1: Hybrid Goong Search + Apple Maps Routing (iOS)
              _buildProviderCard(
                provider: MapProvider.appleMaps,
                title: 'Goong Tìm kiếm + Apple Maps Lộ trình',
                badge: 'Khuyên dùng • Siêu mượt',
                badgeColor: const Color(0xFF34C759),
                description:
                    'Tìm địa chỉ, số nhà, ngõ hẻm bằng Goong Map chuẩn Việt Nam; Tính toán lộ trình, ETA và dẫn đường Realtime 30 FPS bằng Apple Maps (MKDirections) gốc trên iPhone.',
                icon: Icons.map_rounded,
                iconColor: const Color(0xFF007AFF),
                isSelected: current == MapProvider.appleMaps,
                isSupportedOnDevice: AppleMapsService.isSupported,
                onTap: () {
                  _settings.setProvider(MapProvider.appleMaps);
                  _showToast(context, 'Đã kích hoạt: Tìm kiếm Goong + Lộ trình Apple Maps');
                },
              ),

              const SizedBox(height: 12),

              // Option 2: Goong API Full
              _buildProviderCard(
                provider: MapProvider.goong,
                title: 'Goong API Toàn bộ (Tìm kiếm + Lộ trình)',
                badge: 'Dùng Quota Key riêng',
                badgeColor: const Color(0xFFFF9500),
                description:
                    'Sử dụng Goong API cho cả tìm kiếm và tính lộ trình xe máy. Tiêu tốn lượt gọi Direction API từ Goong Config.',
                icon: Icons.navigation_rounded,
                iconColor: const Color(0xFFFF9500),
                isSelected: current == MapProvider.goong,
                isSupportedOnDevice: true,
                onTap: () {
                  _settings.setProvider(MapProvider.goong);
                  _showToast(context, 'Đã chuyển sang Goong API toàn bộ');
                },
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
      borderRadius: BorderRadius.circular(18),
      onTap: isSupportedOnDevice ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected ? iconColor : Colors.black.withValues(alpha: 0.06),
            width: isSelected ? 2.0 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: iconColor, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: const TextStyle(
                            color: Color(0xFF1C1C1E),
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(color: badgeColor, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12, height: 1.35),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              isSelected ? Icons.check_circle_rounded : Icons.radio_button_off_rounded,
              color: isSelected ? iconColor : const Color(0xFFC7C7CC),
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  void _showToast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFF007AFF),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
