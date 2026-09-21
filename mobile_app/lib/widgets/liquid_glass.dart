import 'dart:ui';
import 'package:flutter/material.dart';

/// Reusable Liquid Glass Container for iOS-style translucent floating controls (Sections 36-38, 48-49)
class LiquidGlassContainer extends StatelessWidget {
  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final BoxBorder? border;
  final Color? baseColor;
  final bool isSelected;
  final Color? selectedBorderColor;
  final List<BoxShadow>? customShadow;

  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.radius = 24.0,
    this.blur = 20.0,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.border,
    this.baseColor,
    this.isSelected = false,
    this.selectedBorderColor,
    this.customShadow,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    // Section 38: Glass Material Spec
    // Light: 0.22 - 0.14 opacity
    // Dark:  0.28 - 0.18 opacity
    final bgGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? [
              (baseColor ?? Colors.black).withOpacity(0.32),
              (baseColor ?? Colors.black).withOpacity(0.18),
            ]
          : [
              (baseColor ?? Colors.white).withOpacity(isSelected ? 0.35 : 0.24),
              (baseColor ?? Colors.white).withOpacity(isSelected ? 0.25 : 0.14),
            ],
    );

    final defaultBorder = Border.all(
      color: isSelected
          ? (selectedBorderColor ?? const Color(0xFF007AFF))
          : (isDark ? Colors.white.withOpacity(0.20) : Colors.white.withOpacity(0.35)),
      width: isSelected ? 1.5 : 1.0,
    );

    final shadows = customShadow ?? [
      BoxShadow(
        color: Colors.black.withOpacity(isDark ? 0.28 : 0.10),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
      if (isSelected)
        BoxShadow(
          color: (selectedBorderColor ?? const Color(0xFF007AFF)).withOpacity(0.30),
          blurRadius: 12,
          spreadRadius: 1,
        ),
    ];

    Widget content = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        gradient: bgGradient,
        borderRadius: BorderRadius.circular(radius),
        border: border ?? defaultBorder,
        boxShadow: shadows,
      ),
      child: child,
    );

    // Section 47: Reduced motion skips expensive GPU BackdropFilter
    if (reduceMotion || blur <= 0.0) {
      return Container(
        margin: margin,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: content,
        ),
      );
    }

    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: content,
        ),
      ),
    );
  }
}

/// Liquid Glass Button with tactile spring feedback, high touch targets, and selected states (Section 45)
class LiquidGlassButton extends StatefulWidget {
  final Widget icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final double radius;
  final bool isSelected;
  final Color? activeGlowColor;
  final EdgeInsetsGeometry? padding;

  const LiquidGlassButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.size = 46.0,
    this.radius = 23.0,
    this.isSelected = false,
    this.activeGlowColor,
    this.padding,
  });

  @override
  State<LiquidGlassButton> createState() => _LiquidGlassButtonState();
}

class _LiquidGlassButtonState extends State<LiquidGlassButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final scale = (_isPressed && !reduceMotion) ? 0.96 : 1.0;

    Widget btn = GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
        child: LiquidGlassContainer(
          width: widget.size,
          height: widget.size,
          radius: widget.radius,
          padding: widget.padding ?? EdgeInsets.zero,
          isSelected: widget.isSelected,
          selectedBorderColor: widget.activeGlowColor,
          child: Center(child: widget.icon),
        ),
      ),
    );

    if (widget.tooltip != null) {
      btn = Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}

/// Liquid Glass Capsule for grouping horizontal or vertical controls (Sections 39 & 40)
class LiquidGlassCapsule extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;

  const LiquidGlassCapsule({
    super.key,
    required this.child,
    this.radius = 24.0,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    this.margin,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return LiquidGlassContainer(
      radius: radius,
      padding: padding,
      margin: margin,
      width: width,
      height: height,
      child: child,
    );
  }
}
