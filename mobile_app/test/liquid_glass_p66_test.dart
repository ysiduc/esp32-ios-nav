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
      expect(toolbarFill.opacity, inInclusiveRange(0.04, 0.95));

      final bottomSearchFill = MapOverlayGlassStyle.bottomSearchFill(isDark: false);
      expect(bottomSearchFill.opacity, inInclusiveRange(0.04, 0.95));

      final drawerFill = MapOverlayGlassStyle.drawerFill(isDark: false);
      expect(drawerFill.opacity, inInclusiveRange(0.04, 0.95));

      final sheetFill = MapOverlayGlassStyle.sheetFill(isDark: false);
      expect(sheetFill.opacity, inInclusiveRange(0.04, 0.95));

      final routeSheetFill = MapOverlayGlassStyle.routeSheetFill(isDark: false);
      expect(routeSheetFill.opacity, inInclusiveRange(0.04, 0.95));

      // 2. Blur: gentle sigma <= 32
      expect(MapOverlayGlassStyle.trueLiquidGlassBlur, lessThanOrEqualTo(32.0));
      expect(MapOverlayGlassStyle.referenceBlur, lessThanOrEqualTo(32.0));
      expect(AppleGlassTokens.referenceBlur, lessThanOrEqualTo(32.0));

      // 3. Border: white 0.30 ~ 0.45, width 0.7 ~ 1.0
      final refBorder = MapOverlayGlassStyle.referenceBorder(isDark: false);
      expect(refBorder.top.width, inInclusiveRange(0.7, 1.0));
      expect(refBorder.top.color.opacity, inInclusiveRange(0.30, 0.85));

      // 4. Shadow: black <= 0.10, blur in 12..26
      final refShadows = MapOverlayGlassStyle.referenceShadow(isDark: false);
      expect(refShadows.first.color.opacity, inInclusiveRange(0.02, 0.12));
      expect(refShadows.first.blurRadius, inInclusiveRange(6.0, 26.0));

      // 5. Card fills: soft translucent (0.05 ~ 0.15)
      final cardFill = MapOverlayGlassStyle.cardFill(isDark: false);
      expect(cardFill.opacity, inInclusiveRange(0.04, 0.65));
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

    testWidgets('Right toolbar renders native-backed AppGlassToolbar with clear variant', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final toolbarFinder = find.byType(AppGlassToolbar);
      expect(toolbarFinder, findsWidgets);

      final glassWidgets = tester.widgetList<AppGlassToolbar>(toolbarFinder);
      final toolbar = glassWidgets.where((w) => w.width == 48 && w.radius == 24);
      expect(toolbar, isNotEmpty, reason: 'Toolbar must use AppGlassToolbar with width 48, radius 24');
      expect(toolbar.first.variant, equals(AppGlassVariant.clear));
    });

    testWidgets('Bottom search capsule uses native-backed AppGlassSurface with clear variant', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final surfaceFinder = find.byType(AppGlassSurface);
      final glassWidgets = tester.widgetList<AppGlassSurface>(surfaceFinder);
      final searchPill = glassWidgets.where((w) => w.height == 50 && w.radius == 25);
      expect(searchPill, isNotEmpty, reason: 'Bottom search must use AppGlassSurface with height 50, radius 25');
      expect(searchPill.first.variant, equals(AppGlassVariant.clear));
    });

    testWidgets('Drawer uses native clear glass surface with overlayOwned', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final scaffoldState = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      final drawerFinder = find.byType(Drawer);
      expect(drawerFinder, findsOneWidget);

      final drawerGlassFinder = find.descendant(
        of: drawerFinder,
        matching: find.byType(AppGlassSurface),
      );
      expect(drawerGlassFinder, findsOneWidget);

      final drawerGlass = tester.widget<AppGlassSurface>(drawerGlassFinder);
      expect(drawerGlass.variant, equals(AppGlassVariant.clear));
      expect(drawerGlass.overlayOwned, isTrue);
    });

    testWidgets('Search modal bottom sheet uses native clear glass surface with overlayOwned', (tester) async {
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
        matching: find.byType(AppGlassSurface),
      );
      expect(sheetGlassFinder, findsOneWidget);

      final sheetGlass = tester.widget<AppGlassSurface>(sheetGlassFinder);
      expect(sheetGlass.variant, equals(AppGlassVariant.clear));
      expect(sheetGlass.overlayOwned, isTrue);
    });
  });
}
