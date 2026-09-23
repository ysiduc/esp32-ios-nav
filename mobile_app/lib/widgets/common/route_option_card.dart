import 'package:flutter/material.dart';
import '../../models/route_model.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_shadows.dart';
import '../../theme/app_typography.dart';

class RouteOptionCard extends StatelessWidget {
  final NavRoute route;
  final bool isSelected;
  final VoidCallback onTap;
  final String? badgeText;

  const RouteOptionCard({
    super.key,
    required this.route,
    required this.isSelected,
    required this.onTap,
    this.badgeText,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isSelected ? AppColors.primary : AppColors.border;
    final borderWidth = isSelected ? 1.8 : 0.8;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.roundedLg,
          border: Border.all(color: borderColor, width: borderWidth),
          boxShadow: isSelected ? AppShadows.floating : AppShadows.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(
                      route.formattedDuration,
                      style: AppTypography.title2.copyWith(
                        color: isSelected ? AppColors.primary : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '(${route.formattedDistance})',
                      style: AppTypography.body.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
                if (badgeText != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: const BoxDecoration(
                      color: AppColors.successLight,
                      borderRadius: AppRadius.roundedPill,
                    ),
                    child: Text(
                      badgeText!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.success,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              route.summary.isNotEmpty ? route.summary : 'Lộ trình tối ưu',
              style: AppTypography.subheadline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
