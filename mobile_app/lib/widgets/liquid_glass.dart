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

/// Active navigation/map overlay presentation mode (P5.8)
enum MapOverlayMode {
  none,
  search,
  drawer,
  dialog,
  reportSheet,
  placeDetails,
}

/// Representation of a registered glass surface geometry and style (P5.8.1)
class GlassSurfaceData {
  final String id;
  final Rect rect;
  final double radius;
  final String variant;
  final bool isSelected;
  final int? tint;
  final String? groupId;

  const GlassSurfaceData({
    required this.id,
    required this.rect,
    required this.radius,
    required this.variant,
    this.isSelected = false,
    this.tint,
    this.groupId,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
    'radius': radius,
    'variant': variant,
    'isSelected': isSelected,
    if (tint != null) 'tint': tint,
    if (groupId != null) 'groupId': groupId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GlassSurfaceData &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          rect == other.rect &&
          radius == other.radius &&
          variant == other.variant &&
          isSelected == other.isSelected &&
          tint == other.tint &&
          groupId == other.groupId;

  @override
  int get hashCode => Object.hash(id, rect, radius, variant, isSelected, tint, groupId);
}

/// Controller coordinating overlay states and native glass host surface registry (P5.8 & P5.8.1)
class NativeGlassHostController extends ChangeNotifier {
  static final NativeGlassHostController instance = NativeGlassHostController._internal();
  NativeGlassHostController._internal();

  static const MethodChannel _channel = MethodChannel('com.ysiduc.esp32_nav/glass_host');

  MapOverlayMode _overlayMode = MapOverlayMode.none;
  MapOverlayMode get overlayMode => _overlayMode;
  MapOverlayMode get currentMode => _overlayMode;
  bool get isOverlayActive => _overlayMode != MapOverlayMode.none;

  final Map<String, GlassSurfaceData> _surfaces = {};
  Map<String, GlassSurfaceData> get surfaces => Map.unmodifiable(_surfaces);

  bool _flushScheduled = false;

  @visibleForTesting
  static void Function(List<Map<String, dynamic>>)? onFlushForTesting;

  void setOverlayMode(MapOverlayMode mode) {
    if (_overlayMode == mode) return;
    _overlayMode = mode;
    notifyListeners();

    try {
      _channel.invokeMethod('setOverlayActive', isOverlayActive);
    } catch (_) {
      // Non-iOS or test environment fallback
    }

    if (!isOverlayActive) {
      flushSurfaces();
    }
  }

  void registerSurface(GlassSurfaceData surface) {
    final existing = _surfaces[surface.id];
    if (existing != null && existing == surface) {
      return;
    }
    _surfaces[surface.id] = surface;
    _scheduleFlush();
  }

  void updateSurface(GlassSurfaceData surface) {
    registerSurface(surface);
  }

  void unregisterSurface(String id) {
    if (_surfaces.remove(id) != null) {
      _scheduleFlush();
    }
  }

  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      flushSurfaces();
    });
  }

  void flushSurfaces() {
    final payload = _surfaces.values.map((s) => s.toMap()).toList();
    onFlushForTesting?.call(payload);
    try {
      _channel.invokeMethod('updateSurfaces', payload);
    } catch (_) {
      // Non-iOS or test environment fallback
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _overlayMode = MapOverlayMode.none;
    _surfaces.clear();
    _flushScheduled = false;
    notifyListeners();
  }
}

/// Single Native Glass Host platform view component (P5.8.1)
/// Placed in MapScreen Stack between MapLibre and Flutter controls.
/// Only ONE instance exists in normal map mode.
class NativeGlassHostLayer extends StatelessWidget {
  const NativeGlassHostLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        NativeGlassHostController.instance,
        AppAccessibilityService.instance,
      ]),
      builder: (context, _) {
        final isOverlayActive = NativeGlassHostController.instance.isOverlayActive;
        final isReduceTransparency = AppAccessibilityService.instance.reduceTransparency;
        final backend = AppGlassBackend.resolve(
          context: context,
          isReduceTransparency: isReduceTransparency,
        );

        final isNativeActive = (backend == AppGlassBackendType.uiGlass ||
                backend == AppGlassBackendType.uiGlassContainer ||
                backend == AppGlassBackendType.nativeBlurFallback) &&
            !isOverlayActive;

        if (!isNativeActive) {
          return const SizedBox.shrink();
        }

        return const Positioned.fill(
          child: IgnorePointer(
            ignoring: true,
            child: UiKitView(
              viewType: 'plugins.ysiduc.com/native_glass_host',
              creationParamsCodec: StandardMessageCodec(),
              hitTestBehavior: PlatformViewHitTestBehavior.transparent,
            ),
          ),
        );
      },
    );
  }
}

/// Resolved runtime rendering backend for Liquid Glass (P5.7.1 & P5.8)
enum AppGlassBackendType {
  /// True Apple Liquid Glass API (iOS 26+ UIGlassEffect)
  uiGlass,

  /// Grouped Apple Liquid Glass container (iOS 26+ UIGlassContainerEffect)
  uiGlassContainer,

  /// Native iOS UIKit UIVisualEffectView material with specular highlight edge
  nativeBlurFallback,

  /// Pure Flutter BackdropFilter fallback for Android, Linux, desktop, web, or active overlays
  flutterFallback,

  /// Solid high-contrast opaque surface when Reduce Transparency is enabled
  opaqueAccessibility,

  // Backwards compatibility alias
  nativeModern,
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
      return AppGlassBackendType.opaqueAccessibility;
    }

    // 2. Synthetic backend override for unit testing specific visual branches
    if (forceBackendForTesting != null) {
      return forceBackendForTesting!;
    }

    // 3. Z-Order Composition Guard: When a modal, drawer, or dialog is active,
    // fallback to pure Flutter compositing so no native platform view occludes the overlay! (P5.8)
    if (NativeGlassHostController.instance.isOverlayActive) {
      return AppGlassBackendType.flutterFallback;
    }

    // 4. Platform & native capability detection
    final platform = forcePlatformForTesting ?? defaultTargetPlatform;
    if (kIsWeb) {
      return AppGlassBackendType.flutterFallback;
    }
    if (platform == TargetPlatform.iOS) {
      final cap = AppAccessibilityService.instance.nativeGlassCapability;
      if (cap == 'uiglass' || cap == 'native-modern') {
        return AppGlassBackendType.uiGlass;
      }
      if (cap == 'uiglass-container') {
        return AppGlassBackendType.uiGlassContainer;
      }
      return AppGlassBackendType.nativeBlurFallback;
    }
    return AppGlassBackendType.flutterFallback;
  }

  /// Returns a human-readable telemetry string for debug overlay and field verification (P5.8)
  static String currentName(BuildContext context, [bool? isReduceTransparency]) {
    final effectiveReduceTransparency = isReduceTransparency ??
        AppAccessibilityService.instance.reduceTransparency;
    final type = resolve(context: context, isReduceTransparency: effectiveReduceTransparency);
    switch (type) {
      case AppGlassBackendType.uiGlass:
      case AppGlassBackendType.nativeModern:
        return 'uiglass';
      case AppGlassBackendType.uiGlassContainer:
        return 'uiglass-container';
      case AppGlassBackendType.nativeBlurFallback:
        return 'native-blur-fallback';
      case AppGlassBackendType.flutterFallback:
        return 'flutter-fallback';
      case AppGlassBackendType.opaqueAccessibility:
      case AppGlassBackendType.opaqueFallback:
        return 'opaque-accessibility';
    }
  }
}

/// Base adaptive Liquid Glass material container (P5.7 & P5.7.1)
/// Features real native iOS platform view backend (UiKitView) with Flutter content on top,
/// and automatic Flutter BackdropFilter fallback for other platforms.
class AppGlassSurface extends StatefulWidget {
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
  final String? groupId;
  final String? surfaceId;

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
    this.groupId,
    this.surfaceId,
  });

  @override
  State<AppGlassSurface> createState() => _AppGlassSurfaceState();
}

class _AppGlassSurfaceState extends State<AppGlassSurface> {
  static int _idCounter = 0;
  late final String _id;

  @override
  void initState() {
    super.initState();
    _id = widget.surfaceId ?? 'surf_${++_idCounter}_${identityHashCode(this)}';
    _scheduleLayoutRegistration();
  }

  @override
  void didUpdateWidget(covariant AppGlassSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.radius != widget.radius ||
        oldWidget.variant != widget.variant ||
        oldWidget.isSelected != widget.isSelected ||
        oldWidget.tint != widget.tint ||
        oldWidget.groupId != widget.groupId ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _scheduleLayoutRegistration();
    }
  }

  @override
  void dispose() {
    NativeGlassHostController.instance.unregisterSurface(_id);
    super.dispose();
  }

  void _scheduleLayoutRegistration() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize) {
        final offset = renderBox.localToGlobal(Offset.zero);
        final rect = offset & renderBox.size;
        NativeGlassHostController.instance.registerSurface(
          GlassSurfaceData(
            id: _id,
            rect: rect,
            radius: widget.radius,
            variant: widget.variant.name,
            isSelected: widget.isSelected,
            tint: widget.tint?.value,
            groupId: widget.groupId,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.reduceTransparency != null) {
      return _buildSurface(context, widget.reduceTransparency!);
    }

    return ListenableBuilder(
      listenable: Listenable.merge([
        AppAccessibilityService.instance,
        NativeGlassHostController.instance,
      ]),
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

    // 1. Accessibility Fallback: Opaque high-contrast surface if transparency is reduced
    if (backend == AppGlassBackendType.opaqueAccessibility ||
        backend == AppGlassBackendType.opaqueFallback) {
      Color solidBg;
      Color solidBorder;

      switch (widget.variant) {
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

      if (widget.tint != null) {
        solidBg = Color.alphaBlend(widget.tint!, solidBg);
      }

      return Container(
        margin: widget.margin,
        width: widget.width,
        height: widget.height,
        padding: widget.padding,
        decoration: BoxDecoration(
          color: solidBg,
          borderRadius: BorderRadius.circular(widget.radius),
          border: widget.border ?? Border.all(
            color: widget.isSelected ? (widget.selectedBorderColor ?? const Color(0xFF007AFF)) : solidBorder,
            width: widget.isSelected ? 1.5 : 1.0,
          ),
          boxShadow: widget.customShadow ?? [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.3 : 0.1),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: widget.child,
      );
    }

    // Determine default specular border color
    Color defaultBorderColor;
    switch (widget.variant) {
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
      color: widget.isSelected
          ? (widget.selectedBorderColor ?? const Color(0xFF007AFF))
          : defaultBorderColor,
      width: widget.isSelected ? 1.5 : 1.0,
    );

    final shadows = widget.customShadow ?? [
      BoxShadow(
        color: Colors.black.withOpacity(isDark ? 0.20 : 0.08),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
      if (widget.isSelected)
        BoxShadow(
          color: (widget.selectedBorderColor ?? const Color(0xFF007AFF)).withOpacity(0.35),
          blurRadius: 12,
          spreadRadius: 1,
        ),
    ];

    // 2. REAL NATIVE LIQUID GLASS BACKEND (P5.8.1 Single Host Architecture)
    // The native glass material is rendered on the single NativeGlassHostLayer behind Flutter UI.
    // AppGlassSurface registers its layout rect with NativeGlassHostController and renders
    // foreground Flutter content with crisp borders and shadows, WITHOUT instantiating any UiKitView!
    if (backend == AppGlassBackendType.uiGlass ||
        backend == AppGlassBackendType.uiGlassContainer ||
        backend == AppGlassBackendType.nativeModern ||
        backend == AppGlassBackendType.nativeBlurFallback) {
      _scheduleLayoutRegistration();
      return Container(
        margin: widget.margin,
        width: widget.width,
        height: widget.height,
        padding: widget.padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: widget.border ?? defaultBorder,
          boxShadow: shadows,
        ),
        child: widget.child,
      );
    }

    // 3. FLUTTER BACKDROP FILTER FALLBACK (Android / Web / Linux / Tests / Active Overlays)
    final effectiveBlur = widget.blur ?? (
      widget.variant == AppGlassVariant.prominent ? 24.0 :
      widget.variant == AppGlassVariant.clear ? 12.0 :
      widget.variant == AppGlassVariant.danger ? 16.0 : 18.0
    );

    Color fillColor;
    switch (widget.variant) {
      case AppGlassVariant.prominent:
        fillColor = isDark
            ? const Color(0xFF1E293B).withOpacity(0.65)
            : Colors.white.withOpacity(0.85);
        break;

      case AppGlassVariant.clear:
        fillColor = isDark
            ? Colors.black.withOpacity(0.25)
            : Colors.white.withOpacity(0.30);
        break;

      case AppGlassVariant.danger:
        fillColor = isDark
            ? const Color(0xFFEF4444).withOpacity(0.35)
            : const Color(0xFFEF4444).withOpacity(0.20);
        break;

      case AppGlassVariant.regular:
        fillColor = isDark
            ? const Color(0xFF0F172A).withOpacity(0.55)
            : Colors.white.withOpacity(0.65);
        break;
    }

    if (widget.tint != null) {
      fillColor = Color.alphaBlend(widget.tint!, fillColor);
    }

    return Container(
      margin: widget.margin,
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: shadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: effectiveBlur, sigmaY: effectiveBlur),
          child: Container(
            padding: widget.padding,
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(widget.radius),
              border: widget.border ?? defaultBorder,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

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
  final String? groupId;

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
    this.groupId,
  });

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      groupId: groupId ?? 'right-toolbar',
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
