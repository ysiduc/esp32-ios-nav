import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P6.8 Ultra-Clear Liquid Glass Specification Tests', () {
    test('P6.8 Ultra-Clear Fills (Controls dark <= 0.03, Large surfaces dark <= 0.025)', () {
      // 1. Controls: Toolbar
      final darkToolbar = MapOverlayGlassStyle.toolbarFill(isDark: true);
      expect(darkToolbar.opacity, lessThanOrEqualTo(0.03));
      expect(darkToolbar.opacity, closeTo(0.022, 0.003));

      final lightToolbar = MapOverlayGlassStyle.toolbarFill(isDark: false);
      expect(lightToolbar.opacity, closeTo(0.055, 0.005));

      // 2. Controls: Bottom Search Pill
      final darkSearchPill = MapOverlayGlassStyle.bottomSearchFill(isDark: true);
      expect(darkSearchPill.opacity, lessThanOrEqualTo(0.03));
      expect(darkSearchPill.opacity, closeTo(0.022, 0.003));

      final lightSearchPill = MapOverlayGlassStyle.bottomSearchFill(isDark: false);
      expect(lightSearchPill.opacity, closeTo(0.055, 0.005));

      // 3. Large Surfaces: Drawer, Search Sheet, Route Sheet (dark <= 0.025)
      final darkDrawer = MapOverlayGlassStyle.drawerFill(isDark: true);
      expect(darkDrawer.opacity, lessThanOrEqualTo(0.025));
      expect(darkDrawer.opacity, closeTo(0.018, 0.003));

      final lightDrawer = MapOverlayGlassStyle.drawerFill(isDark: false);
      expect(lightDrawer.opacity, closeTo(0.045, 0.005));

      final darkSheet = MapOverlayGlassStyle.sheetFill(isDark: true);
      expect(darkSheet.opacity, lessThanOrEqualTo(0.025));
      expect(darkSheet.opacity, closeTo(0.018, 0.003));

      final lightSheet = MapOverlayGlassStyle.sheetFill(isDark: false);
      expect(lightSheet.opacity, closeTo(0.045, 0.005));

      final darkRoute = MapOverlayGlassStyle.routeSheetFill(isDark: true);
      expect(darkRoute.opacity, lessThanOrEqualTo(0.025));
      expect(darkRoute.opacity, closeTo(0.018, 0.003));

      final lightRoute = MapOverlayGlassStyle.routeSheetFill(isDark: false);
      expect(lightRoute.opacity, closeTo(0.045, 0.005));

      // 4. Cards: selected blue tint <= 0.10 in dark, <= 0.08 in light
      final darkSelectedCard = MapOverlayGlassStyle.cardFill(isDark: true, isSelected: true);
      expect(darkSelectedCard.opacity, lessThanOrEqualTo(0.11));
      final lightSelectedCard = MapOverlayGlassStyle.cardFill(isDark: false, isSelected: true);
      expect(lightSelectedCard.opacity, lessThanOrEqualTo(0.08));

      // 5. Search input field fill (0.06 dark / 0.09 light)
      final darkSearchField = MapOverlayGlassStyle.searchSheetFieldFill(isDark: true);
      expect(darkSearchField.opacity, closeTo(0.06, 0.005));
      final lightSearchField = MapOverlayGlassStyle.searchSheetFieldFill(isDark: false);
      expect(lightSearchField.opacity, closeTo(0.09, 0.005));
    });

    test('P6.8 Lower Blur (toolbar <= 10.0, large surfaces <= 8.0, never > 12.0)', () {
      expect(MapOverlayGlassStyle.toolbarBlur, equals(10.0));
      expect(MapOverlayGlassStyle.toolbarBlur, lessThanOrEqualTo(12.0));

      expect(MapOverlayGlassStyle.bottomSearchBlur, equals(10.0));
      expect(MapOverlayGlassStyle.bottomSearchBlur, lessThanOrEqualTo(12.0));

      expect(MapOverlayGlassStyle.largeSurfaceBlur, equals(8.0));
      expect(MapOverlayGlassStyle.largeSurfaceBlur, lessThanOrEqualTo(12.0));

      expect(MapOverlayGlassStyle.drawerBlur, equals(8.0));
      expect(MapOverlayGlassStyle.sheetBlur, equals(8.0));
      expect(MapOverlayGlassStyle.routeSheetBlur, equals(8.0));
      expect(MapOverlayGlassStyle.referenceBlur, equals(10.0));
    });

    test('P6.8 Ultra-Soft Shadow (black 0.04/0.03, blur 8, y=2)', () {
      final darkShadow = MapOverlayGlassStyle.referenceShadow(isDark: true);
      expect(darkShadow.first.color.opacity, closeTo(0.04, 0.005));
      expect(darkShadow.first.blurRadius, equals(8.0));
      expect(darkShadow.first.offset.dy, equals(2.0));

      final lightShadow = MapOverlayGlassStyle.referenceShadow(isDark: false);
      expect(lightShadow.first.color.opacity, closeTo(0.03, 0.005));
      expect(lightShadow.first.blurRadius, equals(8.0));
      expect(lightShadow.first.offset.dy, equals(2.0));
    });

    test('P6.8 Outer Border & Inner Rim (dark 0.20, light 0.30, width 0.7)', () {
      final darkBorder = MapOverlayGlassStyle.referenceBorder(isDark: true);
      expect(darkBorder.top.color.opacity, closeTo(0.20, 0.01));
      expect(darkBorder.top.width, equals(0.7));

      final lightBorder = MapOverlayGlassStyle.referenceBorder(isDark: false);
      expect(lightBorder.top.color.opacity, closeTo(0.30, 0.01));
      expect(lightBorder.top.width, equals(0.7));
    });

    testWidgets('TrueLiquidGlass builds ultra-clear stack with no default body gradient', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TrueLiquidGlass(
              width: 100,
              height: 100,
              child: Text('Ultra Clear Core'),
            ),
          ),
        ),
      );

      final glassFinder = find.byType(TrueLiquidGlass);
      expect(glassFinder, findsOneWidget);

      final glassWidget = tester.widget<TrueLiquidGlass>(glassFinder);
      expect(glassWidget.blurSigma, equals(10.0));
      expect(glassWidget.bodyGradient, isNull);

      // Verify no body gradient in inner container
      final containers = tester.widgetList<Container>(
        find.descendant(of: glassFinder, matching: find.byType(Container)),
      );
      final bodyContainer = containers.firstWhere(
        (c) => c.decoration is BoxDecoration && (c.decoration as BoxDecoration).color != null,
      );
      final deco = bodyContainer.decoration as BoxDecoration;
      expect(deco.gradient, isNull);
    });

    testWidgets('Right toolbar and bottom search capsule render with blur 10.0 and ultra-clear fill', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final glassFinder = find.byType(TrueLiquidGlass);
      expect(glassFinder, findsWidgets);

      final glassWidgets = tester.widgetList<TrueLiquidGlass>(glassFinder);
      final toolbar = glassWidgets.where((w) => w.width == 48 && w.radius == 24).first;
      expect(toolbar.blurSigma, equals(10.0));
      expect((toolbar.fillColor ?? Colors.white).opacity, lessThanOrEqualTo(0.06));

      final searchPill = glassWidgets.where((w) => w.height == 50 && w.radius == 25).first;
      expect(searchPill.blurSigma, equals(10.0));
      expect((searchPill.fillColor ?? Colors.white).opacity, lessThanOrEqualTo(0.06));
    });

    testWidgets('Drawer and search modal use blur 8.0 and ultra-clear large surface fill', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      // Open drawer
      final scaffoldState = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      final drawerFinder = find.byType(Drawer);
      expect(drawerFinder, findsOneWidget);

      final drawerGlass = tester.widget<TrueLiquidGlass>(
        find.descendant(of: drawerFinder, matching: find.byType(TrueLiquidGlass)),
      );
      expect(drawerGlass.blurSigma, equals(8.0));
      expect(drawerGlass.fillColor?.opacity, lessThanOrEqualTo(0.05));
    });
  });
}
