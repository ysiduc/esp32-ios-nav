import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_shadows.dart';

class MapFloatingButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color? iconColor;
  final Color? backgroundColor;
  final double size;
  final double iconSize;
  final bool isSelected;
  final Widget? badge;

  const MapFloatingButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.iconColor,
    this.backgroundColor,
    this.size = 46.0,
    this.iconSize = 22.0,
    this.isSelected = false,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isSelected
        ? AppColors.primary
        : (backgroundColor ?? AppColors.surfaceTranslucent);
    final iColor = isSelected
        ? Colors.white
        : (iconColor ?? AppColors.textPrimary);

    Widget btn = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: AppRadius.roundedPill,
        border: Border.all(
          color: isSelected ? AppColors.primary : AppColors.border,
          width: 0.8,
        ),
        boxShadow: AppShadows.floating,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: onTap,
          child: Center(
            child: Icon(icon, color: iColor, size: iconSize),
          ),
        ),
      ),
    );

    if (badge != null) {
      btn = Stack(
        clipBehavior: Clip.none,
        children: [
          btn,
          Positioned(top: -2, right: -2, child: badge!),
        ],
      );
    }

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: btn);
    }

    return btn;
  }
}
