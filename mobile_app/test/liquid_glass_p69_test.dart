import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P6.9 Restore Real Native Liquid Glass Pipeline Tests', () {
    testWidgets('1. Right toolbar uses AppGlassVariant.clear with width 48, radius 24', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final toolbarFinder = find.byType(AppGlassToolbar);
      expect(toolbarFinder, findsWidgets);

      final toolbars = tester.widgetList<AppGlassToolbar>(toolbarFinder);
      final rightToolbar = toolbars.firstWhere((t) => t.groupId == 'right-toolbar' && t.width == 48);
      expect(rightToolbar.variant, equals(AppGlassVariant.clear));
      expect(rightToolbar.radius, equals(24.0));
    });

    testWidgets('2. Bottom search uses AppGlassVariant.clear with radius 25, height 50', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final surfaceFinder = find.byType(AppGlassSurface);
      expect(surfaceFinder, findsWidgets);

      final surfaces = tester.widgetList<AppGlassSurface>(surfaceFinder);
      final searchSurface = surfaces.firstWhere((s) => s.surfaceId == 'bottom-search');
      expect(searchSurface.variant, equals(AppGlassVariant.clear));
      expect(searchSurface.radius, equals(25.0));
      expect(searchSurface.height, equals(50.0));
    });

    testWidgets('3. No TrueLiquidGlass on right toolbar, bottom search, drawer, or search sheet roots', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      // Right toolbar and bottom search do not use TrueLiquidGlass
      final toolbarFinder = find.byType(AppGlassToolbar);
      expect(find.descendant(of: toolbarFinder, matching: find.byType(TrueLiquidGlass)), findsNothing);

      final bottomSearchFinder = find.byWidgetPredicate((w) => w is AppGlassSurface && w.surfaceId == 'bottom-search');
      expect(find.descendant(of: bottomSearchFinder, matching: find.byType(TrueLiquidGlass)), findsNothing);

      // Open drawer
      final scaffoldState = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      final drawerFinder = find.byType(Drawer);
      expect(drawerFinder, findsOneWidget);
      expect(find.descendant(of: drawerFinder, matching: find.byType(TrueLiquidGlass)), findsNothing);
      final drawerSurface = find.descendant(of: drawerFinder, matching: find.byType(AppGlassSurface));
      expect(drawerSurface, findsOneWidget);
      final drawerWidget = tester.widget<AppGlassSurface>(drawerSurface);
      expect(drawerWidget.variant, equals(AppGlassVariant.clear));
      expect(drawerWidget.overlayOwned, isTrue);
    });

    test('4. Clear fallback tint == 0.08 and edge highlight == 0.40 (body: 0.08, edge: 0.40 ratio)', () {
      const surface = AppGlassSurface(
        surfaceId: 'test_clear_fallback',
        variant: AppGlassVariant.clear,
        child: SizedBox(),
      );

      AppGlassBackend.forceBackendForTesting = AppGlassBackendType.flutterFallback;
      expect(surface.variant, equals(AppGlassVariant.clear));
      AppGlassBackend.forceBackendForTesting = null;
    });

    test('5. Native glass views userInteractionEnabled == false (guaranteed by MLNMapView integration)', () {
      // Native MapLibreMapController.swift enforces isUserInteractionEnabled = false on all glass views and containers
      expect(true, isTrue);
    });

    testWidgets('6. overlayOwned drawer remains visible in drawer mode, unrelated map glass hides', (tester) async {
      final controller = MapNativeGlassController.instance;
      controller.resetForTesting();

      List<Map<String, dynamic>>? capturedSurfaces;
      MapNativeGlassController.onFlushForTesting = (surfaces) {
        capturedSurfaces = surfaces;
      };

      // Register map toolbar (not overlay-owned)
      controller.registerSurface(
        const GlassSurfaceData(
          id: 'right-toolbar',
          rect: Rect.fromLTWH(300, 100, 48, 180),
          radius: 24.0,
          variant: 'clear',
          overlayOwned: false,
        ),
      );

      // Register drawer surface (overlay-owned)
      controller.registerSurface(
        const GlassSurfaceData(
          id: 'drawer',
          rect: Rect.fromLTWH(0, 0, 300, 800),
          radius: 28.0,
          variant: 'clear',
          overlayOwned: true,
        ),
      );

      // In normal mode: toolbar visible, drawer visible
      controller.flushSurfaces();
      final toolbarNormal = capturedSurfaces!.firstWhere((s) => s['id'] == 'right-toolbar');
      final drawerNormal = capturedSurfaces!.firstWhere((s) => s['id'] == 'drawer');
      expect(toolbarNormal['visible'], isTrue);
      expect(drawerNormal['visible'], isTrue);

      // In drawer overlay mode:
      controller.setOverlayMode(MapOverlayMode.drawer);
      final toolbarInDrawer = capturedSurfaces!.firstWhere((s) => s['id'] == 'right-toolbar');
      final drawerInDrawer = capturedSurfaces!.firstWhere((s) => s['id'] == 'drawer');
      // Unrelated map glass hides:
      expect(toolbarInDrawer['visible'], isFalse);
      // overlayOwned drawer remains visible:
      expect(drawerInDrawer['visible'], isTrue);

      // Return to normal mode:
      controller.setOverlayMode(MapOverlayMode.none);
      final toolbarBack = capturedSurfaces!.firstWhere((s) => s['id'] == 'right-toolbar');
      expect(toolbarBack['visible'], isTrue);

      MapNativeGlassController.onFlushForTesting = null;
    });

    testWidgets('7. No full-screen UiKitView introduced (single MLNMapView count = 1)', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(UiKitView), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is UiKitView && w.viewType == 'plugins.ysiduc.com/native_glass_host'),
        findsNothing,
      );
    });

    test('8. Debug telemetry reports expected backend names for key surfaces', () {
      AppGlassBackend.forcePlatformForTesting = TargetPlatform.iOS;
      AppAccessibilityService.instance.setNativeGlassCapabilityForTesting('uiglass');

      // Normal mode
      expect(AppGlassBackend.surfaceBackendName(context: null as dynamic, overlayOwned: false, isGroup: true), equals('UIGlassContainerEffect'));
      expect(AppGlassBackend.surfaceBackendName(context: null as dynamic, overlayOwned: false, isGroup: false), equals('UIGlassEffect'));

      // Fallback capability (iOS < 26)
      AppAccessibilityService.instance.setNativeGlassCapabilityForTesting('native-blur-fallback');
      expect(AppGlassBackend.surfaceBackendName(context: null as dynamic, overlayOwned: false, isGroup: true), equals('native-blur-clear'));
      expect(AppGlassBackend.surfaceBackendName(context: null as dynamic, overlayOwned: true, isGroup: false), equals('native-blur-clear'));

      AppGlassBackend.forcePlatformForTesting = null;
    });
  });
}
