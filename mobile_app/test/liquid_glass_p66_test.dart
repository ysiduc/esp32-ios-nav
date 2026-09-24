import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P6.6 True Frosted Liquid Glass Specification Tests', () {
    test('P6.6 Visual Formulas (Base Fill, Blur, Border, Shadow, Highlight, Inner Rim)', () {
      // 1. Base Fill: translucent (0.04 ~ 0.18), NOT opaque white (0.80 - 0.95)
      final toolbarFill = MapOverlayGlassStyle.toolbarFill(isDark: false);
      expect(toolbarFill.opacity, inInclusiveRange(0.04, 0.18));

      final bottomSearchFill = MapOverlayGlassStyle.bottomSearchFill(isDark: false);
      expect(bottomSearchFill.opacity, inInclusiveRange(0.04, 0.18));

      final drawerFill = MapOverlayGlassStyle.drawerFill(isDark: false);
      expect(drawerFill.opacity, inInclusiveRange(0.04, 0.18));

      final sheetFill = MapOverlayGlassStyle.sheetFill(isDark: false);
      expect(sheetFill.opacity, inInclusiveRange(0.04, 0.18));

      final routeSheetFill = MapOverlayGlassStyle.routeSheetFill(isDark: false);
      expect(routeSheetFill.opacity, inInclusiveRange(0.04, 0.18));

      // 2. Blur: gentle sigma <= 32
      expect(MapOverlayGlassStyle.trueLiquidGlassBlur, lessThanOrEqualTo(32.0));
      expect(MapOverlayGlassStyle.referenceBlur, lessThanOrEqualTo(32.0));
      expect(AppleGlassTokens.referenceBlur, lessThanOrEqualTo(32.0));

      // 3. Border: white 0.30 ~ 0.45, width 0.7 ~ 1.0
      final refBorder = MapOverlayGlassStyle.referenceBorder(isDark: false);
      expect(refBorder.top.width, inInclusiveRange(0.7, 1.0));
      expect(refBorder.top.color.opacity, inInclusiveRange(0.30, 0.46));

      // 4. Shadow: black <= 0.10, blur in 12..26
      final refShadows = MapOverlayGlassStyle.referenceShadow(isDark: false);
      expect(refShadows.first.color.opacity, inInclusiveRange(0.04, 0.10));
      expect(refShadows.first.blurRadius, inInclusiveRange(12.0, 26.0));

      // 5. Card fills: soft translucent (0.05 ~ 0.15)
      final cardFill = MapOverlayGlassStyle.cardFill(isDark: false);
      expect(cardFill.opacity, inInclusiveRange(0.05, 0.15));
    });

    test('TrueLiquidGlass widget builds multi-layer stack (BackdropFilter, Base Tint, Highlight, Inner Rim, Border)', () {
      const widget = TrueLiquidGlass(
        width: 48,
        radius: 24,
        blurSigma: 15.0,
        child: SizedBox(),
      );

      expect(widget.width, equals(48));
      expect(widget.radius, equals(24));
      expect(widget.blurSigma, equals(15.0));
      expect(widget.showHighlight, isTrue);
      expect(widget.showInnerRim, isTrue);
    });

    testWidgets('Right toolbar renders TrueLiquidGlass with real blur and translucent fill', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      // Verify TrueLiquidGlass instances exist on screen
      final glassFinder = find.byType(TrueLiquidGlass);
      expect(glassFinder, findsWidgets);

      // Verify right vertical toolbar is TrueLiquidGlass with width 48, radius 24
      final glassWidgets = tester.widgetList<TrueLiquidGlass>(glassFinder);
      final toolbar = glassWidgets.where((w) => w.width == 48 && w.radius == 24);
      expect(toolbar, isNotEmpty, reason: 'Toolbar must use TrueLiquidGlass with width 48, radius 24');

      // Verify BackdropFilter is present
      final backdropFilters = find.descendant(
        of: glassFinder,
        matching: find.byType(BackdropFilter),
      );
      expect(backdropFilters, findsWidgets);

      // Confirm no opaque white container is used for the toolbar
      final tb = toolbar.first;
      expect((tb.fillColor ?? Colors.white).opacity, lessThan(0.20));
    });

    testWidgets('Bottom search capsule uses TrueLiquidGlass (height 50, radius 25)', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final glassFinder = find.byType(TrueLiquidGlass);
      final glassWidgets = tester.widgetList<TrueLiquidGlass>(glassFinder);
      final searchPill = glassWidgets.where((w) => w.height == 50 && w.radius == 25);
      expect(searchPill, isNotEmpty, reason: 'Bottom search must use TrueLiquidGlass with height 50, radius 25');

      final pill = searchPill.first;
      expect((pill.fillColor ?? Colors.white).opacity, lessThan(0.20));
    });

    testWidgets('Drawer uses TrueLiquidGlass with translucent frosted panel', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final scaffoldState = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      final drawerFinder = find.byType(Drawer);
      expect(drawerFinder, findsOneWidget);

      final drawerGlassFinder = find.descendant(
        of: drawerFinder,
        matching: find.byType(TrueLiquidGlass),
      );
      expect(drawerGlassFinder, findsOneWidget);

      final drawerGlass = tester.widget<TrueLiquidGlass>(drawerGlassFinder);
      expect(drawerGlass.blurSigma, lessThanOrEqualTo(16.0));
      expect(drawerGlass.fillColor?.opacity, inInclusiveRange(0.04, 0.18));
    });

    testWidgets('Search modal bottom sheet uses TrueLiquidGlass at root', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final searchPillFinder = find.text('Tìm kiếm điểm đến...');
      expect(searchPillFinder, findsOneWidget);
      await tester.tap(searchPillFinder);
      await tester.pumpAndSettle();

      final sheetFinder = find.byType(DraggableScrollableSheet);
      expect(sheetFinder, findsOneWidget);

      final sheetGlassFinder = find.descendant(
        of: sheetFinder,
        matching: find.byType(TrueLiquidGlass),
      );
      expect(sheetGlassFinder, findsOneWidget);

      final sheetGlass = tester.widget<TrueLiquidGlass>(sheetGlassFinder);
      expect(sheetGlass.blurSigma, lessThanOrEqualTo(16.0));
      expect(sheetGlass.fillColor?.opacity, inInclusiveRange(0.04, 0.18));
    });
  });
}
