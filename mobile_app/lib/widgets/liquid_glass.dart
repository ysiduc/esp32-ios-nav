import 'dart:ui';
import 'package:flutter/material.dart';

/// Single Blur Surface for Bright Liquid Glass (Sections 53-66)
/// Solves nested BackdropFilter performance issues and provides bright, translucent,
/// milky, frosted glass where the map underneath remains clearly visible.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final BoxBorder? border;
  final bool isSelected;
  final Color? selectedBorderColor;
  final List<BoxShadow>? customShadow;

  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 24.0,
    this.blur = 20.0,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.border,
    this.isSelected = false,
    this.selectedBorderColor,
    this.customShadow,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    // Section 55 & 56: Bright Translucent Glass Material
    // Light Mode: top highlight 0.50, body 0.24, bottom 0.12
    // Dark Mode: neutral cool translucent (white 0.14 + subtle slate tint), NOT opaque black!
    final bgGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: const [0.0, 0.45, 1.0],
      colors: isDark
          ? [
              Colors.white.withOpacity(0.18),
              const Color(0xFF1E293B).withOpacity(0.10),
              const Color(0xFF0F172A).withOpacity(0.12),
            ]
          : [
              Colors.white.withOpacity(isSelected ? 0.55 : 0.48),
              Colors.white.withOpacity(isSelected ? 0.32 : 0.24),
              Colors.white.withOpacity(isSelected ? 0.20 : 0.12),
            ],
    );

    // Section 55, 56, 57: Specular Border Highlight
    final defaultBorder = Border.all(
      color: isSelected
          ? (selectedBorderColor ?? const Color(0xFF007AFF))
          : (isDark ? Colors.white.withOpacity(0.28) : Colors.white.withOpacity(0.60)),
      width: isSelected ? 1.5 : 1.0,
    );

    // Section 59: Softer, light-catching shadow
    final shadows = customShadow ?? [
      BoxShadow(
        color: Colors.black.withOpacity(isDark ? 0.14 : 0.08),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
      if (isSelected)
        BoxShadow(
          color: (selectedBorderColor ?? const Color(0xFF007AFF)).withOpacity(0.35),
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

/// Lightweight Glass Action Button (Section 65)
/// Contains ZERO BackdropFilters to prevent nested GPU overhead!
/// Handles press scaling, selected state tint/glow, and high tactile feedback.
class GlassAction extends StatefulWidget {
  final Widget icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final bool isSelected;
  final Color? activeColor;
  final EdgeInsetsGeometry? padding;

  const GlassAction({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.size = 44.0,
    this.isSelected = false,
    this.activeColor,
    this.padding,
  });

  @override
  State<GlassAction> createState() => _GlassActionState();
}

class _GlassActionState extends State<GlassAction> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final scale = (_isPressed && !reduceMotion) ? 0.94 : 1.0;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final selectedBg = widget.isSelected
        ? (widget.activeColor ?? const Color(0xFF007AFF)).withOpacity(0.18)
        : Colors.transparent;

    Widget btn = GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOutCubic,
        child: Container(
          width: widget.size,
          height: widget.size,
          padding: widget.padding ?? EdgeInsets.zero,
          decoration: BoxDecoration(
            color: selectedBg,
            shape: BoxShape.circle,
            boxShadow: widget.isSelected
                ? [
                    BoxShadow(
                      color: (widget.activeColor ?? const Color(0xFF007AFF)).withOpacity(0.30),
                      blurRadius: 8,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Center(
            child: IconTheme(
              data: IconThemeData(
                color: widget.isSelected
                    ? (widget.activeColor ?? const Color(0xFF007AFF))
                    : (isDark ? Colors.white : const Color(0xFF1C1C1E)),
                size: 20,
              ),
              child: widget.icon,
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      btn = Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}

/// Backwards-compatible LiquidGlassContainer delegating to GlassSurface
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
    return GlassSurface(
      radius: radius,
      blur: blur,
      padding: padding,
      margin: margin,
      width: width,
      height: height,
      border: border,
      isSelected: isSelected,
      selectedBorderColor: selectedBorderColor,
      customShadow: customShadow,
      child: child,
    );
  }
}

/// Backwards-compatible LiquidGlassButton with single GlassSurface
class LiquidGlassButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return GlassSurface(
      width: size,
      height: size,
      radius: radius,
      isSelected: isSelected,
      selectedBorderColor: activeGlowColor,
      padding: EdgeInsets.zero,
      child: GlassAction(
        icon: icon,
        onTap: onTap,
        tooltip: tooltip,
        size: size,
        isSelected: isSelected,
        activeColor: activeGlowColor,
        padding: padding,
      ),
    );
  }
}

/// Backwards-compatible LiquidGlassCapsule
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
    return GlassSurface(
      radius: radius,
      padding: padding,
      margin: margin,
      width: width,
      height: height,
      child: child,
    );
  }
}
