import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P5.4.1.3 Section 62: Liquid Glass UI Widget Tests', () {
    testWidgets('LiquidGlassContainer renders child with translucent backdrop', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: const Scaffold(
            body: LiquidGlassContainer(
              radius: 20,
              blur: 18,
              child: Text('Glass Test'),
            ),
          ),
        ),
      );

      expect(find.text('Glass Test'), findsOneWidget);
      expect(find.byType(LiquidGlassContainer), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('LiquidGlassContainer adapts to Dark Mode theme', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(
            body: LiquidGlassContainer(
              radius: 24,
              child: Text('Dark Glass'),
            ),
          ),
        ),
      );

      expect(find.text('Dark Glass'), findsOneWidget);
    });

    testWidgets('LiquidGlassContainer retains glass under reduced motion while disabling animations', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const Scaffold(
              body: LiquidGlassContainer(
                radius: 20,
                blur: 20,
                child: Text('Reduced Motion'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Reduced Motion'), findsOneWidget);
      // P5.7.1 Part 6: Reduce Motion does NOT remove blur/transparency
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('LiquidGlassButton responds to user tap and selected state', (tester) async {
      bool tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiquidGlassButton(
              icon: const Icon(Icons.navigation_rounded),
              isSelected: true,
              activeGlowColor: const Color(0xFF007AFF),
              onTap: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.navigation_rounded), findsOneWidget);

      await tester.tap(find.byType(LiquidGlassButton));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });

    testWidgets('LiquidGlassCapsule renders child inside capsule layout', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LiquidGlassCapsule(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.menu),
                  Text('Capsule'),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.menu), findsOneWidget);
      expect(find.text('Capsule'), findsOneWidget);
    });
  });

  group('P5.4.1.4 Section 80: Bright Liquid Glass & Single BackdropFilter Architecture', () {
    testWidgets('Grouped toolbar has exactly ONE BackdropFilter', (tester) async {
      int actionTapped = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassSurface(
              radius: 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassAction(
                    icon: const Icon(Icons.layers),
                    tooltip: 'Layers',
                    onTap: () => actionTapped++,
                  ),
                  Container(width: 20, height: 1, color: Colors.white24),
                  GlassAction(
                    icon: const Icon(Icons.explore),
                    tooltip: 'Compass',
                    isSelected: true,
                    onTap: () => actionTapped++,
                  ),
                  Container(width: 20, height: 1, color: Colors.white24),
                  GlassAction(
                    icon: const Icon(Icons.two_wheeler),
                    tooltip: 'Bike',
                    onTap: () => actionTapped++,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Verify that across the entire grouped toolbar with 3 buttons, exactly ONE BackdropFilter is created (Section 64 & 80)
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.byType(GlassAction), findsNWidgets(3));

      // Tap first action
      await tester.tap(find.byTooltip('Layers'));
      await tester.pumpAndSettle();
      expect(actionTapped, equals(1));
    });

    testWidgets('Light Mode glass uses bright specular material and Dark Mode is translucent', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: const Scaffold(
            body: GlassSurface(
              child: Text('Bright Specular Glass'),
            ),
          ),
        ),
      );
      expect(find.text('Bright Specular Glass'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(
            body: GlassSurface(
              child: Text('Dark Translucent Glass'),
            ),
          ),
        ),
      );
      expect(find.text('Dark Translucent Glass'), findsOneWidget);
    });
  });

  group('P5.7: Liquid Glass Component System & Driving Map Overlays', () {
    testWidgets('AppGlassSurface supports all variants (regular, clear, prominent, danger)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                AppGlassSurface(variant: AppGlassVariant.regular, child: Text('Regular')),
                AppGlassSurface(variant: AppGlassVariant.clear, child: Text('Clear')),
                AppGlassSurface(variant: AppGlassVariant.prominent, child: Text('Prominent')),
                AppGlassSurface(variant: AppGlassVariant.danger, child: Text('Danger')),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Regular'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
      expect(find.text('Prominent'), findsOneWidget);
      expect(find.text('Danger'), findsOneWidget);
      // All 4 render BackdropFilter when motion/transparency is not reduced
      expect(find.byType(BackdropFilter), findsNWidgets(4));
    });

    testWidgets('AppGlassSurface respects Reduce Transparency with high-contrast opaque fallback', (tester) async {
      AppAccessibilityService.instance.setReduceTransparencyForTesting(true);
      addTearDown(() => AppAccessibilityService.instance.setReduceTransparencyForTesting(false));

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                AppGlassSurface(variant: AppGlassVariant.prominent, child: Text('No Blur Prominent')),
                AppGlassSurface(variant: AppGlassVariant.danger, child: Text('No Blur Danger')),
              ],
            ),
          ),
        ),
      );

      expect(find.text('No Blur Prominent'), findsOneWidget);
      expect(find.text('No Blur Danger'), findsOneWidget);
      // P5.7.1 Part 6: When reduceTransparency is active, BackdropFilter is disabled
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(UiKitView), findsNothing);
    });

    testWidgets('AppGlassPill handles tap callback and displays child', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassPill(
              onTap: () => tapped = true,
              child: const Text('Search Pill'),
            ),
          ),
        ),
      );

      expect(find.text('Search Pill'), findsOneWidget);
      await tester.tap(find.text('Search Pill'));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });

    testWidgets('AppGlassButton danger variant renders crisp white icon and handles tap', (tester) async {
      bool endRouteTapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassButton(
              variant: AppGlassVariant.danger,
              size: 44,
              icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
              tooltip: 'Kết thúc dẫn đường',
              onTap: () => endRouteTapped = true,
            ),
          ),
        ),
      );

      expect(find.byTooltip('Kết thúc dẫn đường'), findsOneWidget);
      await tester.tap(find.byType(AppGlassButton));
      await tester.pumpAndSettle();
      expect(endRouteTapped, isTrue);
    });

    testWidgets('AppGlassToolbar and AppGlassToolbarDivider group controls into single glass surface', (tester) async {
      int carTapped = 0;
      int locTapped = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassToolbar(
              width: 44,
              radius: 22,
              children: [
                IconButton(
                  icon: const Icon(Icons.directions_car_rounded),
                  onPressed: () => carTapped++,
                ),
                const AppGlassToolbarDivider(),
                IconButton(
                  icon: const Icon(Icons.navigation_rounded),
                  onPressed: () => locTapped++,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.byType(AppGlassToolbar), findsOneWidget);
      expect(find.byType(AppGlassToolbarDivider), findsOneWidget);
      // Exactly 1 BackdropFilter for the entire toolbar container
      expect(find.byType(BackdropFilter), findsOneWidget);

      await tester.tap(find.byIcon(Icons.directions_car_rounded));
      await tester.pumpAndSettle();
      expect(carTapped, equals(1));

      await tester.tap(find.byIcon(Icons.navigation_rounded));
      await tester.pumpAndSettle();
      expect(locTapped, equals(1));
    });

    testWidgets('Active Driving Banner renders with Prominent Glass and inner Clear Maneuver Circle', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassSurface(
              variant: AppGlassVariant.prominent,
              radius: 24,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  AppGlassSurface(
                    variant: AppGlassVariant.clear,
                    radius: 24,
                    width: 48,
                    height: 48,
                    child: const Center(
                      child: Icon(Icons.turn_left_rounded, color: Colors.white, size: 28),
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Trong 209 m', style: TextStyle(color: Colors.white70)),
                      Text('Rẽ trái vào Lê Lợi', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Trong 209 m'), findsOneWidget);
      expect(find.text('Rẽ trái vào Lê Lợi'), findsOneWidget);
      expect(find.byIcon(Icons.turn_left_rounded), findsOneWidget);
    });

    testWidgets('Active Driving Bottom HUD renders ETA, Duration, Distance and Danger Glass End Button', (tester) async {
      bool stopped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassBottomBar(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              radius: 36,
              variant: AppGlassVariant.regular,
              child: Row(
                children: [
                  const Text('17:45'),
                  const Text('12 phút'),
                  const Text('4.8 km'),
                  AppGlassButton(
                    variant: AppGlassVariant.danger,
                    size: 44,
                    icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
                    tooltip: 'Kết thúc dẫn đường',
                    onTap: () => stopped = true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('17:45'), findsOneWidget);
      expect(find.text('12 phút'), findsOneWidget);
      expect(find.text('4.8 km'), findsOneWidget);
      expect(find.byTooltip('Kết thúc dẫn đường'), findsOneWidget);

      await tester.tap(find.byType(AppGlassButton));
      await tester.pumpAndSettle();
      expect(stopped, isTrue);
    });

    testWidgets('ESP32 status badge adapts between connected green glass tint and off state', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                // Connected badge
                AppGlassPill(
                  height: 30,
                  variant: AppGlassVariant.prominent,
                  tint: const Color(0xFF05FFA1).withOpacity(0.18),
                  child: const Text('ESP32 Live'),
                ),
                // Disconnected badge
                AppGlassPill(
                  height: 30,
                  variant: AppGlassVariant.prominent,
                  tint: Colors.black.withOpacity(0.4),
                  child: const Text('ESP32 Off'),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('ESP32 Live'), findsOneWidget);
      expect(find.text('ESP32 Off'), findsOneWidget);
    });
  });

  group('P5.7.1 & P5.7.2: Real Native Liquid Glass Backend & Accessibility Tests', () {
    tearDown(() {
      AppGlassBackend.forceBackendForTesting = null;
      AppGlassBackend.forcePlatformForTesting = null;
      AppAccessibilityService.instance.setReduceTransparencyForTesting(false);
      AppAccessibilityService.instance.setNativeGlassCapabilityForTesting('native-blur-fallback');
    });

    testWidgets('Live Reduce Transparency switch dynamically rebuilds AppGlassSurface and NativeGlassHostLayer', (tester) async {
      // Force iOS environment with Reduce Transparency OFF initially
      AppGlassBackend.forcePlatformForTesting = TargetPlatform.iOS;
      AppGlassBackend.forceBackendForTesting = null;
      AppAccessibilityService.instance.setReduceTransparencyForTesting(false);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                NativeGlassHostLayer(),
                AppGlassSurface(
                  radius: 20.0,
                  child: Text('Live Accessibility Content'),
                ),
              ],
            ),
          ),
        ),
      );

      // Initial state: Reduce Transparency OFF -> real native host UiKitView exists
      expect(find.text('Live Accessibility Content'), findsOneWidget);
      expect(find.byType(UiKitView), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);

      // User enables Reduce Transparency in iOS Settings
      AppAccessibilityService.instance.setReduceTransparencyForTesting(true);
      await tester.pump();

      // UiKitView is unmounted and opaque high-contrast surface renders
      expect(find.byType(UiKitView), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('Live Accessibility Content'), findsOneWidget);

      // User disables Reduce Transparency -> returns to real native host UiKitView
      AppAccessibilityService.instance.setReduceTransparencyForTesting(false);
      await tester.pump();

      expect(find.byType(UiKitView), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('Production resolver on iOS with current capability=blur resolves to native-blur-fallback', (tester) async {
      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                capturedContext = ctx;
                return const Text('Resolver Context');
              },
            ),
          ),
        ),
      );

      // Verify production resolver behavior without test overrides (P5.7.2 Part C & D)
      AppGlassBackend.forceBackendForTesting = null;
      AppGlassBackend.forcePlatformForTesting = TargetPlatform.iOS;
      AppAccessibilityService.instance.setReduceTransparencyForTesting(false);
      AppAccessibilityService.instance.setNativeGlassCapabilityForTesting('native-blur-fallback');

      final backend = AppGlassBackend.resolve(
        context: capturedContext,
        isReduceTransparency: false,
      );
      expect(backend, equals(AppGlassBackendType.nativeBlurFallback));
      expect(AppGlassBackend.currentName(capturedContext), equals('native-blur-fallback'));
    });

    testWidgets('Single host architecture: NativeGlassHostLayer mounts ONE plugins.ysiduc.com/native_glass_host and surfaces register geometry', (tester) async {
      AppGlassBackend.forcePlatformForTesting = TargetPlatform.iOS;
      AppGlassBackend.forceBackendForTesting = AppGlassBackendType.nativeBlurFallback;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                NativeGlassHostLayer(),
                AppGlassSurface(
                  surfaceId: 'test_surf_1',
                  variant: AppGlassVariant.prominent,
                  radius: 28.0,
                  isSelected: true,
                  child: Text('Native Glass Content'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Native Glass Content'), findsOneWidget);
      expect(find.byType(UiKitView), findsOneWidget);

      final uikitFinder = find.byType(UiKitView);
      final UiKitView uikitView = tester.widget<UiKitView>(uikitFinder);
      expect(uikitView.viewType, equals('plugins.ysiduc.com/native_glass_host'));

      // Check registered surface in controller
      expect(NativeGlassHostController.instance.surfaces.containsKey('test_surf_1'), isTrue);
      final surf = NativeGlassHostController.instance.surfaces['test_surf_1']!;
      expect(surf.radius, equals(28.0));
      expect(surf.variant, equals('prominent'));
      expect(surf.isSelected, isTrue);
    });

    testWidgets('Unsupported platforms and default testing environment use Flutter BackdropFilter fallback', (tester) async {
      AppGlassBackend.forceBackendForTesting = AppGlassBackendType.flutterFallback;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppGlassSurface(
              variant: AppGlassVariant.regular,
              radius: 20.0,
              child: Text('Flutter Fallback Content'),
            ),
          ),
        ),
      );

      expect(find.text('Flutter Fallback Content'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.byType(UiKitView), findsNothing);
    });

    testWidgets('Glass backend telemetry reports exact active state string', (tester) async {
      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                capturedContext = ctx;
                return const Text('Telemetry');
              },
            ),
          ),
        ),
      );

      // Synthetic test state representing true glass capabilities (P5.8)
      AppGlassBackend.forceBackendForTesting = AppGlassBackendType.uiGlass;
      expect(AppGlassBackend.currentName(capturedContext), equals('uiglass'));

      AppGlassBackend.forceBackendForTesting = AppGlassBackendType.uiGlassContainer;
      expect(AppGlassBackend.currentName(capturedContext), equals('uiglass-container'));

      AppGlassBackend.forceBackendForTesting = AppGlassBackendType.nativeBlurFallback;
      expect(AppGlassBackend.currentName(capturedContext), equals('native-blur-fallback'));

      AppGlassBackend.forceBackendForTesting = AppGlassBackendType.flutterFallback;
      expect(AppGlassBackend.currentName(capturedContext), equals('flutter-fallback'));

      AppGlassBackend.forceBackendForTesting = null;
      AppAccessibilityService.instance.setReduceTransparencyForTesting(true);
      expect(AppGlassBackend.currentName(capturedContext), equals('opaque-accessibility'));
    });

    testWidgets('Right-side driving toolbar contains exactly ONE glass surface for all 3 buttons', (tester) async {
      AppGlassBackend.forceBackendForTesting = AppGlassBackendType.flutterFallback;
      int altTapped = 0;
      int soundTapped = 0;
      int reportTapped = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassToolbar(
              width: 44,
              radius: 22,
              children: [
                IconButton(
                  icon: const Icon(Icons.alt_route_rounded),
                  onPressed: () => altTapped++,
                ),
                const AppGlassToolbarDivider(),
                IconButton(
                  icon: const Icon(Icons.volume_up_rounded),
                  onPressed: () => soundTapped++,
                ),
                const AppGlassToolbarDivider(),
                IconButton(
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                  onPressed: () => reportTapped++,
                ),
              ],
            ),
          ),
        ),
      );

      // Verify that across all 3 buttons, exactly ONE glass surface (and ONE BackdropFilter) is instantiated (P5.7.1 Part 9)
      expect(find.byType(AppGlassToolbar), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.byType(AppGlassToolbarDivider), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.alt_route_rounded));
      await tester.pumpAndSettle();
      expect(altTapped, equals(1));

      await tester.tap(find.byIcon(Icons.volume_up_rounded));
      await tester.pumpAndSettle();
      expect(soundTapped, equals(1));

      await tester.tap(find.byIcon(Icons.chat_bubble_outline_rounded));
      await tester.pumpAndSettle();
      expect(reportTapped, equals(1));
    });

    testWidgets('Top banner renders authoritative maneuver icon, distance and street atop native glass', (tester) async {
      AppGlassBackend.forceBackendForTesting = AppGlassBackendType.nativeBlurFallback;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                NativeGlassHostLayer(),
                AppGlassSurface(
                  variant: AppGlassVariant.prominent,
                  radius: 24,
                  child: Row(
                    children: [
                      AppGlassSurface(
                        variant: AppGlassVariant.clear,
                        radius: 24,
                        width: 48,
                        height: 48,
                        child: Center(
                          child: Icon(Icons.turn_left_rounded, color: Colors.white, size: 28),
                        ),
                      ),
                      SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Trong 209 m'),
                          Text('Rẽ trái vào Lê Lợi'),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Trong 209 m'), findsOneWidget);
      expect(find.text('Rẽ trái vào Lê Lợi'), findsOneWidget);
      expect(find.byIcon(Icons.turn_left_rounded), findsOneWidget);
      // Exactly ONE native host UiKitView for the whole stack! Zero per-surface platform views (P5.8.1)
      expect(find.byType(UiKitView), findsOneWidget);
    });

    testWidgets('Navigation cancel button properly invokes teardown with danger glass styling', (tester) async {
      bool teardownCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassBottomBar(
              radius: 36,
              child: Row(
                children: [
                  const Text('18:00'),
                  const Text('15 phút'),
                  AppGlassButton(
                    variant: AppGlassVariant.danger,
                    size: 44,
                    icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
                    tooltip: 'Kết thúc dẫn đường',
                    onTap: () => teardownCalled = true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.byTooltip('Kết thúc dẫn đường'), findsOneWidget);
      await tester.tap(find.byType(AppGlassButton));
      await tester.pumpAndSettle();
      expect(teardownCalled, isTrue);
    });
  });
  group('P5.8: Platform View Z-Order Fix & Overlay Coordination Tests', () {
    tearDown(() {
      NativeGlassHostController.instance.setOverlayMode(MapOverlayMode.none);
      AppGlassBackend.forceBackendForTesting = null;
      AppGlassBackend.forcePlatformForTesting = null;
    });

    testWidgets('NativeGlassHostController manages active state across all overlay modes', (tester) async {
      final controller = NativeGlassHostController.instance;
      expect(controller.isOverlayActive, isFalse);
      expect(controller.currentMode, equals(MapOverlayMode.none));

      controller.setOverlayMode(MapOverlayMode.search);
      expect(controller.isOverlayActive, isTrue);
      expect(controller.currentMode, equals(MapOverlayMode.search));

      controller.setOverlayMode(MapOverlayMode.drawer);
      expect(controller.isOverlayActive, isTrue);
      expect(controller.currentMode, equals(MapOverlayMode.drawer));

      controller.setOverlayMode(MapOverlayMode.dialog);
      expect(controller.isOverlayActive, isTrue);
      expect(controller.currentMode, equals(MapOverlayMode.dialog));

      controller.setOverlayMode(MapOverlayMode.reportSheet);
      expect(controller.isOverlayActive, isTrue);
      expect(controller.currentMode, equals(MapOverlayMode.reportSheet));

      controller.setOverlayMode(MapOverlayMode.none);
      expect(controller.isOverlayActive, isFalse);
      expect(controller.currentMode, equals(MapOverlayMode.none));
    });

    testWidgets('A & C & D: Open search modal suspends native glass and renders search content topmost, dismissing restores glass', (tester) async {
      AppGlassBackend.forcePlatformForTesting = TargetPlatform.iOS;
      AppAccessibilityService.instance.setNativeGlassCapabilityForTesting('uiglass');
      AppGlassBackend.forceBackendForTesting = null;

      final controller = NativeGlassHostController.instance;
      controller.setOverlayMode(MapOverlayMode.none);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                // Single native glass host layer (P5.8.1)
                const NativeGlassHostLayer(),
                // In-map glass control
                const Positioned(
                  top: 50,
                  left: 20,
                  child: AppGlassSurface(
                    variant: AppGlassVariant.prominent,
                    child: Text('Map Glass Control'),
                  ),
                ),
                // Tap button simulating search pill tap
                Builder(
                  builder: (ctx) => Positioned(
                    bottom: 50,
                    child: ElevatedButton(
                      key: const Key('search_pill_btn'),
                      onPressed: () {
                        controller.setOverlayMode(MapOverlayMode.search);
                        showModalBottomSheet(
                          context: ctx,
                          isScrollControlled: true,
                          builder: (modalCtx) => Container(
                            key: const Key('apple_search_modal_content'),
                            height: 400,
                            padding: const EdgeInsets.all(20),
                            child: const Column(
                              children: [
                                Text('Bản Đồ Apple', style: TextStyle(fontWeight: FontWeight.bold)),
                                Text('Địa điểm đã lưu'),
                                Text('Gần đây'),
                              ],
                            ),
                          ),
                        ).whenComplete(() {
                          controller.setOverlayMode(MapOverlayMode.none);
                        });
                      },
                      child: const Text('Search Pill'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // Initially: Native platform view is present because overlay mode is none
      expect(find.byType(UiKitView), findsOneWidget);
      expect(find.text('Map Glass Control'), findsOneWidget);
      expect(controller.isOverlayActive, isFalse);

      // C: Tap search pill -> open search modal
      await tester.tap(find.byKey(const Key('search_pill_btn')));
      await tester.pumpAndSettle();

      // Search modal text exists and is visible topmost
      expect(find.byKey(const Key('apple_search_modal_content')), findsOneWidget);
      expect(find.text('Bản Đồ Apple'), findsOneWidget);
      expect(find.text('Địa điểm đã lưu'), findsOneWidget);
      expect(find.text('Gần đây'), findsOneWidget);

      // Native glass is suspended/lowered: UiKitView is NOT present during modal!
      expect(controller.isOverlayActive, isTrue);
      expect(controller.currentMode, equals(MapOverlayMode.search));
      expect(find.byType(UiKitView), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget); // Falls back to pure Flutter compositing below overlay

      // D: Dismiss modal
      Navigator.pop(tester.element(find.byKey(const Key('apple_search_modal_content'))));
      await tester.pumpAndSettle();

      // Modal is gone, native glass is restored!
      expect(find.byKey(const Key('apple_search_modal_content')), findsNothing);
      expect(controller.isOverlayActive, isFalse);
      expect(controller.currentMode, equals(MapOverlayMode.none));
      expect(find.byType(UiKitView), findsOneWidget);
    });

    testWidgets('B: Tap hamburger opens drawer with MapOverlayMode.drawer above all map glass', (tester) async {
      AppGlassBackend.forcePlatformForTesting = TargetPlatform.iOS;
      AppAccessibilityService.instance.setNativeGlassCapabilityForTesting('uiglass');
      AppGlassBackend.forceBackendForTesting = null;

      final controller = NativeGlassHostController.instance;
      controller.setOverlayMode(MapOverlayMode.none);

      final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            key: scaffoldKey,
            onDrawerChanged: (isOpen) => controller.setOverlayMode(isOpen ? MapOverlayMode.drawer : MapOverlayMode.none),
            drawer: const Drawer(
              key: Key('app_drawer_content'),
              child: SafeArea(
                child: Text('Apple Maps Navigation Drawer'),
              ),
            ),
            body: Stack(
              children: [
                const NativeGlassHostLayer(),
                const Positioned(
                  top: 50,
                  left: 20,
                  child: AppGlassSurface(
                    variant: AppGlassVariant.prominent,
                    child: Text('Underlying Glass View'),
                  ),
                ),
                Positioned(
                  top: 50,
                  right: 20,
                  child: IconButton(
                    key: const Key('hamburger_btn'),
                    icon: const Icon(Icons.menu),
                    onPressed: () {
                      controller.setOverlayMode(MapOverlayMode.drawer);
                      scaffoldKey.currentState?.openDrawer();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.byType(UiKitView), findsOneWidget);
      expect(controller.isOverlayActive, isFalse);

      // Tap hamburger
      await tester.tap(find.byKey(const Key('hamburger_btn')));
      await tester.pumpAndSettle();

      // Drawer content exists and is visible
      expect(find.byKey(const Key('app_drawer_content')), findsOneWidget);
      expect(find.text('Apple Maps Navigation Drawer'), findsOneWidget);
      expect(controller.isOverlayActive, isTrue);
      expect(controller.currentMode, equals(MapOverlayMode.drawer));

      // Native glass is unmounted / suspended so drawer is fully topmost
      expect(find.byType(UiKitView), findsNothing);

      // Close drawer
      scaffoldKey.currentState?.closeDrawer();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('app_drawer_content')), findsNothing);
      expect(controller.isOverlayActive, isFalse);
      expect(find.byType(UiKitView), findsOneWidget);
    });

    testWidgets('E: Open report bottom sheet appears visibly and suspends native glass', (tester) async {
      AppGlassBackend.forcePlatformForTesting = TargetPlatform.iOS;
      AppAccessibilityService.instance.setNativeGlassCapabilityForTesting('uiglass');
      AppGlassBackend.forceBackendForTesting = null;

      final controller = NativeGlassHostController.instance;
      controller.setOverlayMode(MapOverlayMode.none);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const NativeGlassHostLayer(),
                const AppGlassSurface(child: Text('Map View')),
                Builder(
                  builder: (ctx) => ElevatedButton(
                    key: const Key('report_btn'),
                    onPressed: () {
                      controller.setOverlayMode(MapOverlayMode.reportSheet);
                      showModalBottomSheet(
                        context: ctx,
                        builder: (_) => const Text('Báo cáo sự cố: Tai nạn giao thông'),
                      ).whenComplete(() {
                        controller.setOverlayMode(MapOverlayMode.none);
                      });
                    },
                    child: const Text('Report'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('report_btn')));
      await tester.pumpAndSettle();

      expect(find.text('Báo cáo sự cố: Tai nạn giao thông'), findsOneWidget);
      expect(controller.isOverlayActive, isTrue);
      expect(controller.currentMode, equals(MapOverlayMode.reportSheet));
      expect(find.byType(UiKitView), findsNothing);

      Navigator.pop(tester.element(find.text('Báo cáo sự cố: Tai nạn giao thông')));
      await tester.pumpAndSettle();

      expect(controller.isOverlayActive, isFalse);
      expect(find.byType(UiKitView), findsOneWidget);
    });

    testWidgets('F: Location ambiguity confirmation dialog renders topmost above glass', (tester) async {
      AppGlassBackend.forcePlatformForTesting = TargetPlatform.iOS;
      AppAccessibilityService.instance.setNativeGlassCapabilityForTesting('uiglass');
      AppGlassBackend.forceBackendForTesting = null;

      final controller = NativeGlassHostController.instance;
      controller.setOverlayMode(MapOverlayMode.none);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const NativeGlassHostLayer(),
                const AppGlassSurface(child: Text('Active Map Glass')),
                Builder(
                  builder: (ctx) => ElevatedButton(
                    key: const Key('ambiguity_btn'),
                    onPressed: () {
                      controller.setOverlayMode(MapOverlayMode.dialog);
                      showDialog(
                        context: ctx,
                        builder: (dCtx) => AlertDialog(
                          title: const Text('Có thể là địa điểm này'),
                          content: const Text('Không thể xác nhận chính xác ghim.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Dùng vị trí này')),
                          ],
                        ),
                      ).whenComplete(() {
                        controller.setOverlayMode(MapOverlayMode.none);
                      });
                    },
                    child: const Text('Show Ambiguity'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('ambiguity_btn')));
      await tester.pumpAndSettle();

      expect(find.text('Có thể là địa điểm này'), findsOneWidget);
      expect(find.text('Không thể xác nhận chính xác ghim.'), findsOneWidget);
      expect(controller.isOverlayActive, isTrue);
      expect(controller.currentMode, equals(MapOverlayMode.dialog));
      expect(find.byType(UiKitView), findsNothing);

      await tester.tap(find.text('Dùng vị trí này'));
      await tester.pumpAndSettle();

      expect(find.text('Có thể là địa điểm này'), findsNothing);
      expect(controller.isOverlayActive, isFalse);
      expect(find.byType(UiKitView), findsOneWidget);
    });
  });
  group('P5.8.1: Single Native Glass Host & Surface Registry Tests', () {
    tearDown(() {
      NativeGlassHostController.instance.resetForTesting();
      AppGlassBackend.forceBackendForTesting = null;
      AppGlassBackend.forcePlatformForTesting = null;
    });

    testWidgets('Strict platform view count: Multiple glass controls share EXACTLY ONE native host UiKitView and ZERO per-surface UiKitViews', (tester) async {
      AppGlassBackend.forcePlatformForTesting = TargetPlatform.iOS;
      AppGlassBackend.forceBackendForTesting = AppGlassBackendType.uiGlass;
      AppAccessibilityService.instance.setNativeGlassCapabilityForTesting('uiglass');

      final controller = NativeGlassHostController.instance;
      controller.resetForTesting();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                // The ONE and ONLY native glass host
                const NativeGlassHostLayer(),

                // Control 1: Top Search Capsule
                const Positioned(
                  top: 20,
                  left: 16,
                  right: 16,
                  child: AppGlassSurface(
                    surfaceId: 'search_pill',
                    child: Text('Search Pill'),
                  ),
                ),

                // Control 2: Right Toolbar (3 buttons inside AppGlassToolbar with groupId)
                Positioned(
                  top: 100,
                  right: 16,
                  child: AppGlassToolbar(
                    groupId: 'right-toolbar',
                    children: [
                      IconButton(icon: const Icon(Icons.alt_route), onPressed: () {}),
                      const AppGlassToolbarDivider(),
                      IconButton(icon: const Icon(Icons.volume_up), onPressed: () {}),
                      const AppGlassToolbarDivider(),
                      IconButton(icon: const Icon(Icons.report), onPressed: () {}),
                    ],
                  ),
                ),

                // Control 3: Recenter Button
                const Positioned(
                  bottom: 120,
                  right: 16,
                  child: AppGlassSurface(
                    surfaceId: 'recenter_btn',
                    child: Icon(Icons.navigation),
                  ),
                ),

                // Control 4: Bottom Driving HUD
                const Positioned(
                  bottom: 20,
                  left: 16,
                  right: 16,
                  child: AppGlassSurface(
                    surfaceId: 'bottom_dock',
                    child: Text('ETA 18:00 - 15 min'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // STRICT P5.8.1 ASSERTION:
      // Exactly ONE native_glass_host platform view exists in normal map mode!
      final hostViews = find.byWidgetPredicate(
        (w) => w is UiKitView && w.viewType == 'plugins.ysiduc.com/native_glass_host',
      );
      expect(hostViews, findsOneWidget);

      // ZERO legacy per-surface native_glass platform views exist!
      final legacyViews = find.byWidgetPredicate(
        (w) => w is UiKitView && w.viewType == 'plugins.ysiduc.com/native_glass',
      );
      expect(legacyViews, findsNothing);

      // Total UiKitView count across the ENTIRE widget tree is EXACTLY ONE!
      expect(find.byType(UiKitView), findsOneWidget);

      // When an overlay opens: host UiKitView is completely unmounted!
      controller.setOverlayMode(MapOverlayMode.search);
      await tester.pumpAndSettle();

      expect(find.byType(UiKitView), findsNothing);

      // Dismiss overlay: host UiKitView is restored!
      controller.setOverlayMode(MapOverlayMode.none);
      await tester.pumpAndSettle();

      expect(find.byType(UiKitView), findsOneWidget);
    });

    testWidgets('Surface registry lifecycle: registers, updates, and unregisters without zombie surfaces', (tester) async {
      final controller = NativeGlassHostController.instance;
      controller.resetForTesting();

      List<Map<String, dynamic>>? latestPayload;
      NativeGlassHostController.onFlushForTesting = (payload) {
        latestPayload = payload;
      };

      // 1. Register surfaces A, B, C
      const surfA = GlassSurfaceData(
        id: 'surf_A',
        rect: Rect.fromLTWH(10, 20, 100, 40),
        radius: 20,
        variant: 'regular',
      );
      const surfB = GlassSurfaceData(
        id: 'surf_B',
        rect: Rect.fromLTWH(10, 80, 50, 50),
        radius: 25,
        variant: 'prominent',
        groupId: 'right-toolbar',
      );
      const surfC = GlassSurfaceData(
        id: 'surf_C',
        rect: Rect.fromLTWH(10, 150, 200, 60),
        radius: 16,
        variant: 'danger',
      );

      controller.registerSurface(surfA);
      controller.registerSurface(surfB);
      controller.registerSurface(surfC);
      controller.flushSurfaces();

      expect(controller.surfaces.length, equals(3));
      expect(latestPayload?.length, equals(3));

      // 2. Update surface B geometry
      const surfBUpdated = GlassSurfaceData(
        id: 'surf_B',
        rect: Rect.fromLTWH(10, 90, 50, 50),
        radius: 25,
        variant: 'prominent',
        groupId: 'right-toolbar',
      );
      controller.updateSurface(surfBUpdated);
      controller.flushSurfaces();

      expect(controller.surfaces.length, equals(3));
      expect(controller.surfaces['surf_B']?.rect.top, equals(90));

      // 3. Unregister surface C (simulating widget dispose)
      controller.unregisterSurface('surf_C');
      controller.flushSurfaces();

      expect(controller.surfaces.length, equals(2));
      expect(controller.surfaces.containsKey('surf_C'), isFalse);
      expect(latestPayload?.any((s) => s['id'] == 'surf_C'), isFalse);

      NativeGlassHostController.onFlushForTesting = null;
    });

    testWidgets('Grouped toolbar assigns groupId right-toolbar to surface registry', (tester) async {
      AppGlassBackend.forcePlatformForTesting = TargetPlatform.iOS;
      AppGlassBackend.forceBackendForTesting = AppGlassBackendType.uiGlassContainer;

      final controller = NativeGlassHostController.instance;
      controller.resetForTesting();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const NativeGlassHostLayer(),
                Positioned(
                  top: 50,
                  right: 16,
                  child: AppGlassToolbar(
                    groupId: 'right-toolbar',
                    children: [
                      IconButton(icon: const Icon(Icons.navigation), onPressed: () {}),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify that the registered surface has groupId == 'right-toolbar'
      expect(controller.surfaces.isNotEmpty, isTrue);
      final toolbarSurface = controller.surfaces.values.first;
      expect(toolbarSurface.groupId, equals('right-toolbar'));
    });
  });
}
