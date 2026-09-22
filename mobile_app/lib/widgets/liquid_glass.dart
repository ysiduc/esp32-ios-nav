import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Design system variants for Liquid Glass components (P5.7 & P5.7.1)
enum AppGlassVariant {
  /// Balanced frosted diffusion with specular edge (default)
  regular,

  /// High transparency, crisp edge, ideal for unobtrusive floating chips
  clear,

  /// High density and contrast for driving navigation overlays where readability is paramount
  prominent,

  /// Crimson/reddish tinted glass for destructive and cancel actions
  danger,
}

/// Resolved runtime rendering backend for Liquid Glass (P5.7.1)
enum AppGlassBackendType {
  /// Native modern iOS Liquid Glass API (if exposed in iOS 26+ SDK)
  nativeModern,

  /// Native iOS UIKit UIVisualEffectView material with specular highlight edge
  nativeBlurFallback,

  /// Pure Flutter BackdropFilter fallback for Android, Linux, desktop, web, or unit tests
  flutterFallback,

  /// Solid high-contrast opaque surface when Reduce Transparency is enabled
  opaqueFallback,
}

/// Global service providing iOS UIAccessibility.isReduceTransparencyEnabled state and native glass capability (P5.7.1 & P5.7.2)
class AppAccessibilityService extends ChangeNotifier {
  static final AppAccessibilityService instance = AppAccessibilityService._internal();

  AppAccessibilityService._internal() {
    _init();
  }

  static const MethodChannel _channel = MethodChannel('com.ysiduc.esp32_nav/accessibility');
  bool _reduceTransparency = false;
  String _nativeGlassCapability = 'native-blur-fallback';

  bool get reduceTransparency => _reduceTransparency;
  String get nativeGlassCapability => _nativeGlassCapability;

  Future<void> _init() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onReduceTransparencyChanged') {
        if (call.arguments is bool) {
          _reduceTransparency = call.arguments as bool;
          notifyListeners();
        }
      }
    });

    try {
      final res = await _channel.invokeMethod<bool>('isReduceTransparencyEnabled');
      if (res != null) {
        _reduceTransparency = res;
        notifyListeners();
      }
    } catch (_) {
      // Non-iOS or test environment fallback
    }

    try {
      final cap = await _channel.invokeMethod<String>('getGlassCapability');
      if (cap != null && cap.isNotEmpty) {
        _nativeGlassCapability = cap;
        notifyListeners();
      }
    } catch (_) {
      // Non-iOS or test environment fallback
    }
  }

  @visibleForTesting
  void setReduceTransparencyForTesting(bool value) {
    _reduceTransparency = value;
    notifyListeners();
  }

  @visibleForTesting
  void setNativeGlassCapabilityForTesting(String value) {
    _nativeGlassCapability = value;
    notifyListeners();
  }
}

/// Helper and telemetry provider for Liquid Glass backend selection (P5.7.1 Part 5 & P5.7.2)
class AppGlassBackend {
  @visibleForTesting
  static AppGlassBackendType? forceBackendForTesting;

  @visibleForTesting
  static TargetPlatform? forcePlatformForTesting;

  /// Resolves the active rendering backend based on platform and accessibility settings
  static AppGlassBackendType resolve({
    required BuildContext context,
    required bool isReduceTransparency,
  }) {
    // 1. Accessibility Fallback: Reduce Transparency ALWAYS forces opaque fallback (P5.7.1 & P5.7.2)
    if (isReduceTransparency) {
      return AppGlassBackendType.opaqueFallback;
    }

    // 2. Synthetic backend override for unit testing specific visual branches
    if (forceBackendForTesting != null) {
      return forceBackendForTesting!;
    }

    // 3. Platform & native capability detection
    final platform = forcePlatformForTesting ?? defaultTargetPlatform;
    if (kIsWeb) {
      return AppGlassBackendType.flutterFallback;
    }
    if (platform == TargetPlatform.iOS) {
      // P5.7.2: Only return nativeModern if native Swift explicitly confirms modern Liquid Glass API.
      // In current production on iOS 18 / Xcode 16 SDK, capability is always "native-blur-fallback".
      if (AppAccessibilityService.instance.nativeGlassCapability == 'native-modern') {
        return AppGlassBackendType.nativeModern;
      }
      return AppGlassBackendType.nativeBlurFallback;
    }
    return AppGlassBackendType.flutterFallback;
  }

  /// Returns a human-readable telemetry string for debug overlay and field verification
  static String currentName(BuildContext context, [bool? isReduceTransparency]) {
    final effectiveReduceTransparency = isReduceTransparency ??
        AppAccessibilityService.instance.reduceTransparency;
    final type = resolve(context: context, isReduceTransparency: effectiveReduceTransparency);
    switch (type) {
      case AppGlassBackendType.nativeModern:
        return 'native-modern';
      case AppGlassBackendType.nativeBlurFallback:
        return 'native-blur-fallback';
      case AppGlassBackendType.flutterFallback:
        return 'flutter';
      case AppGlassBackendType.opaqueFallback:
        return 'opaque-fallback';
    }
  }
}

/// Base adaptive Liquid Glass material container (P5.7 & P5.7.1)
/// Features real native iOS platform view backend (UiKitView) with Flutter content on top,
/// and automatic Flutter BackdropFilter fallback for other platforms.
class AppGlassSurface extends StatelessWidget {
  final Widget child;
  final AppGlassVariant variant;
  final double radius;
  final double? blur;
  final Color? tint;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final BoxBorder? border;
  final List<BoxShadow>? customShadow;
  final bool isSelected;
  final Color? selectedBorderColor;
  final bool? reduceTransparency;

  const AppGlassSurface({
    super.key,
    required this.child,
    this.variant = AppGlassVariant.regular,
    this.radius = 24.0,
    this.blur,
    this.tint,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.border,
    this.customShadow,
    this.isSelected = false,
    this.selectedBorderColor,
    this.reduceTransparency,
  });

  @override
  Widget build(BuildContext context) {
    // If caller explicitly passed an override, respect it directly without subscription
    if (reduceTransparency != null) {
      return _buildSurface(context, reduceTransparency!);
    }

    // Live reactive rebuild when iOS UIAccessibility.isReduceTransparencyEnabled changes (P5.7.2 Part A)
    return ListenableBuilder(
      listenable: AppAccessibilityService.instance,
      builder: (context, _) => _buildSurface(
        context,
        AppAccessibilityService.instance.reduceTransparency,
      ),
    );
  }

  Widget _buildSurface(BuildContext context, bool isReduceTransparency) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final backend = AppGlassBackend.resolve(
      context: context,
      isReduceTransparency: isReduceTransparency,
    );

    // 1. Accessibility Fallback: Opaque high-contrast surface if transparency is reduced (P5.7.1 Part 6)
    if (backend == AppGlassBackendType.opaqueFallback) {
      Color solidBg;
      Color solidBorder;

      switch (variant) {
        case AppGlassVariant.prominent:
          solidBg = isDark ? const Color(0xFF0F172A) : Colors.white;
          solidBorder = isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);
          break;
        case AppGlassVariant.danger:
          solidBg = isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFEE2E2);
          solidBorder = isDark ? const Color(0xFFB91C1C) : const Color(0xFFEF4444);
          break;
        case AppGlassVariant.clear:
        case AppGlassVariant.regular:
          solidBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
          solidBorder = isDark ? const Color(0xFF475569) : const Color(0xFFE2E8F0);
          break;
      }

      if (tint != null) {
        solidBg = Color.alphaBlend(tint!, solidBg);
      }

      return Container(
        margin: margin,
        width: width,
        height: height,
        padding: padding,
        decoration: BoxDecoration(
          color: solidBg,
          borderRadius: BorderRadius.circular(radius),
          border: border ?? Border.all(
            color: isSelected ? (selectedBorderColor ?? const Color(0xFF007AFF)) : solidBorder,
            width: isSelected ? 1.5 : 1.0,
          ),
          boxShadow: customShadow ?? [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.3 : 0.1),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: child,
      );
    }

    // Determine default specular border color
    Color defaultBorderColor;
    switch (variant) {
      case AppGlassVariant.prominent:
        defaultBorderColor = isDark
            ? Colors.white.withOpacity(0.24)
            : Colors.white.withOpacity(0.85);
        break;

      case AppGlassVariant.clear:
        defaultBorderColor = isDark
            ? Colors.white.withOpacity(0.20)
            : Colors.white.withOpacity(0.60);
        break;

      case AppGlassVariant.danger:
        defaultBorderColor = isDark
            ? const Color(0xFFF87171).withOpacity(0.40)
            : const Color(0xFFEF4444).withOpacity(0.35);
        break;

      case AppGlassVariant.regular:
        defaultBorderColor = isDark
            ? Colors.white.withOpacity(0.28)
            : Colors.white.withOpacity(0.65);
        break;
    }

    final defaultBorder = Border.all(
      color: isSelected
          ? (selectedBorderColor ?? const Color(0xFF007AFF))
          : defaultBorderColor,
      width: isSelected ? 1.5 : 1.0,
    );

    final shadows = customShadow ?? [
      BoxShadow(
        color: Colors.black.withOpacity(isDark ? 0.20 : 0.08),
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

    // 2. REAL NATIVE LIQUID GLASS BACKEND (iOS UIKit UIVisualEffectView / Liquid Glass) (P5.7.1 Part 2)
    if (backend == AppGlassBackendType.nativeModern ||
        backend == AppGlassBackendType.nativeBlurFallback) {
      return Container(
        margin: margin,
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              // Native iOS platform view as the background material layer
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: true,
                  child: UiKitView(
                    viewType: 'plugins.ysiduc.com/native_glass',
                    creationParams: {
                      'variant': variant.name,
                      'radius': radius,
                      'isSelected': isSelected,
                      if (tint != null) 'tint': tint!.value,
                    },
                    creationParamsCodec: const StandardMessageCodec(),
                    hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                  ),
                ),
              ),
              // Flutter content container layered over native glass
              Container(
                padding: padding,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: border ?? defaultBorder,
                  boxShadow: shadows,
                ),
                child: child,
              ),
            ],
          ),
        ),
      );
    }

    // 3. FLUTTER BACKDROP FILTER FALLBACK (Android / Web / Linux / Tests) (P5.7.1 Part 5)
    final effectiveBlur = blur ?? (
      variant == AppGlassVariant.prominent ? 24.0 :
      variant == AppGlassVariant.clear ? 12.0 :
      variant == AppGlassVariant.danger ? 16.0 : 18.0
    );

    LinearGradient bgGradient;
    switch (variant) {
      case AppGlassVariant.prominent:
        bgGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [
                  const Color(0xFF1E293B).withOpacity(0.92),
                  const Color(0xFF0F172A).withOpacity(0.96),
                ]
              : [
                  Colors.white.withOpacity(0.94),
                  const Color(0xFFF8FAFC).withOpacity(0.90),
                ],
        );
        break;

      case AppGlassVariant.clear:
        bgGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [
                  Colors.white.withOpacity(0.12),
                  const Color(0xFF0F172A).withOpacity(0.08),
                ]
              : [
                  Colors.white.withOpacity(0.45),
                  Colors.white.withOpacity(0.18),
                ],
        );
        break;

      case AppGlassVariant.danger:
        bgGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [
                  const Color(0xFFEF4444).withOpacity(0.26),
                  const Color(0xFF991B1B).withOpacity(0.20),
                ]
              : [
                  const Color(0xFFFEE2E2).withOpacity(0.88),
                  const Color(0xFFFECACA).withOpacity(0.72),
                ],
        );
        break;

      case AppGlassVariant.regular:
        bgGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0.0, 0.5, 1.0],
          colors: isDark
              ? [
                  Colors.white.withOpacity(0.18),
                  const Color(0xFF1E293B).withOpacity(0.12),
                  const Color(0xFF0F172A).withOpacity(0.15),
                ]
              : [
                  Colors.white.withOpacity(isSelected ? 0.60 : 0.50),
                  Colors.white.withOpacity(isSelected ? 0.35 : 0.25),
                  Colors.white.withOpacity(isSelected ? 0.22 : 0.15),
                ],
        );
        break;
    }

    if (tint != null) {
      bgGradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: bgGradient.colors.map((c) => Color.alphaBlend(tint!, c)).toList(),
      );
    }

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

    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: effectiveBlur, sigmaY: effectiveBlur),
          child: content,
        ),
      ),
    );
  }
}

/// Floating Liquid Glass Pill (P5.7 Part D)
class AppGlassPill extends StatelessWidget {
  final Widget child;
  final AppGlassVariant variant;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? tint;
  final VoidCallback? onTap;
  final bool isSelected;
  final Color? selectedBorderColor;

  const AppGlassPill({
    super.key,
    required this.child,
    this.variant = AppGlassVariant.regular,
    this.width,
    this.height,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    this.margin,
    this.tint,
    this.onTap,
    this.isSelected = false,
    this.selectedBorderColor,
  });

  @override
  Widget build(BuildContext context) {
    Widget pill = AppGlassSurface(
      variant: variant,
      radius: 999.0,
      width: width,
      height: height,
      padding: padding,
      margin: margin,
      tint: tint,
      isSelected: isSelected,
      selectedBorderColor: selectedBorderColor,
      child: child,
    );

    if (onTap != null) {
      pill = GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: pill,
      );
    }

    return pill;
  }
}

/// Interactive Liquid Glass Button with tactile spring compression (P5.7 Part D & P5.7.1)
class AppGlassButton extends StatefulWidget {
  final Widget icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final AppGlassVariant variant;
  final bool isSelected;
  final Color? activeColor;
  final Color? tint;
  final EdgeInsetsGeometry? padding;
  final double? radius;

  const AppGlassButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.size = 46.0,
    this.variant = AppGlassVariant.regular,
    this.isSelected = false,
    this.activeColor,
    this.tint,
    this.padding,
    this.radius,
  });

  @override
  State<AppGlassButton> createState() => _AppGlassButtonState();
}

class _AppGlassButtonState extends State<AppGlassButton> with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic, reverseCurve: Curves.easeOutBack),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) {
    _animController.forward();
  }

  void _handleTapUp(TapUpDetails _) {
    _animController.reverse();
  }

  void _handleTapCancel() {
    _animController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final r = widget.radius ?? (widget.size / 2);
    // Reduce Motion only disables scale animation, does NOT disable glass (P5.7.1 Part 6)
    final isReduceMotion = MediaQuery.disableAnimationsOf(context);

    Widget btn = GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) => Transform.scale(
          scale: isReduceMotion ? 1.0 : _scaleAnimation.value,
          child: child,
        ),
        child: AppGlassSurface(
          variant: widget.variant,
          radius: r,
          width: widget.size,
          height: widget.size,
          isSelected: widget.isSelected,
          selectedBorderColor: widget.activeColor,
          tint: widget.tint,
          padding: widget.padding ?? EdgeInsets.zero,
          child: Center(
            child: IconTheme(
              data: IconThemeData(
                color: widget.isSelected
                    ? (widget.activeColor ?? const Color(0xFF007AFF))
                    : (widget.variant == AppGlassVariant.danger
                        ? Colors.white
                        : (isDark ? Colors.white : const Color(0xFF1C1C1E))),
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

/// Unified Liquid Glass Toolbar grouping multiple controls with a single glass backdrop (P5.7 Part D & P5.7.1 Part 7)
class AppGlassToolbar extends StatelessWidget {
  final List<Widget> children;
  final Axis axis;
  final AppGlassVariant variant;
  final double radius;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? tint;

  const AppGlassToolbar({
    super.key,
    required this.children,
    this.axis = Axis.vertical,
    this.variant = AppGlassVariant.regular,
    this.radius = 24.0,
    this.width,
    this.height,
    this.padding = const EdgeInsets.all(4.0),
    this.margin,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      variant: variant,
      radius: radius,
      width: width,
      height: height,
      padding: padding,
      margin: margin,
      tint: tint,
      child: Flex(
        direction: axis,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// Translucent subtle divider for AppGlassToolbar (P5.7 Part D)
class AppGlassToolbarDivider extends StatelessWidget {
  final Axis axis;
  const AppGlassToolbarDivider({super.key, this.axis = Axis.vertical});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: axis == Axis.vertical ? 28.0 : 0.8,
      height: axis == Axis.vertical ? 0.8 : 28.0,
      color: isDark ? Colors.white.withOpacity(0.15) : Colors.black.withOpacity(0.08),
    );
  }
}

/// Floating Liquid Glass Bottom Dock (P5.7 Part D)
class AppGlassBottomBar extends StatelessWidget {
  final Widget child;
  final AppGlassVariant variant;
  final double radius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  const AppGlassBottomBar({
    super.key,
    required this.child,
    this.variant = AppGlassVariant.regular,
    this.radius = 28.0,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      variant: variant,
      radius: radius,
      padding: padding,
      margin: margin,
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Backwards compatibility layer for legacy components
// ─────────────────────────────────────────────────────────────────────────────

typedef NativeAdaptiveGlassSurface = AppGlassSurface;
typedef GlassSurface = AppGlassSurface;
typedef LiquidGlassContainer = AppGlassSurface;
typedef LiquidGlassCapsule = AppGlassPill;

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
    return AppGlassButton(
      icon: icon,
      onTap: onTap,
      tooltip: tooltip,
      size: size,
      radius: radius,
      isSelected: isSelected,
      activeColor: activeGlowColor,
      padding: padding,
    );
  }
}
