import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_shadows.dart';
import '../../theme/app_typography.dart';

class MapPillButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool isSelected;
  final Color? activeColor;
  final EdgeInsetsGeometry? padding;

  const MapPillButton({
    super.key,
    required this.label,
    this.icon,
    required this.onTap,
    this.isSelected = false,
    this.activeColor,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final color = activeColor ?? AppColors.primary;
    final bg = isSelected ? color : AppColors.surface;
    final fg = isSelected ? Colors.white : AppColors.textPrimary;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: AppRadius.roundedPill,
          border: Border.all(
            color: isSelected ? color : AppColors.border,
            width: 0.8,
          ),
          boxShadow: isSelected ? AppShadows.button : AppShadows.card,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: AppTypography.pillLabel.copyWith(color: fg),
            ),
          ],
        ),
      ),
    );
  }
}
