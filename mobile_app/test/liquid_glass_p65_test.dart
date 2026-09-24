import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P6.5 Exact Liquid Glass Material Restoration (Run 35895237697 / Commit 52cee9d)', () {
    test('Authoritative Reference Material Constants & Fills match golden spec', () {
      // 1. Reference blur == 20.0
      expect(MapOverlayGlassStyle.referenceBlur, equals(20.0));
      expect(AppleGlassTokens.referenceBlur, equals(20.0));

      // 2. Reference toolbar fill opacity == 0.85
      final toolbarFill = MapOverlayGlassStyle.toolbarFill(isDark: false);
      expect(toolbarFill.opacity, closeTo(0.85, 0.005));
      expect(AppleGlassTokens.referenceFillToolbar.opacity, closeTo(0.85, 0.005));

      // 3. Border opacity == 0.70 and width == 0.8
      final refBorder = MapOverlayGlassStyle.referenceBorder(isDark: false);
      expect(refBorder.top.width, equals(0.8));
      expect(refBorder.top.color.opacity, closeTo(0.70, 0.005));
      expect(AppleGlassTokens.referenceBorderWidth, equals(0.8));
      expect(AppleGlassTokens.referenceBorder.opacity, closeTo(0.70, 0.005));

      // 4. Bottom search fill opacity == 0.88
      final bottomSearchFill = MapOverlayGlassStyle.bottomSearchFill(isDark: false);
      expect(bottomSearchFill.opacity, closeTo(0.88, 0.005));
      expect(AppleGlassTokens.referenceFillSearchPill.opacity, closeTo(0.88, 0.005));

      // 5. Drawer fill opacity == 0.78
      final drawerFill = MapOverlayGlassStyle.drawerFill(isDark: false);
      expect(drawerFill.opacity, closeTo(0.78, 0.005));
      expect(AppleGlassTokens.referenceFillDrawer.opacity, closeTo(0.78, 0.005));

      // 6. Search sheet fill opacity == 0.80
      final sheetFill = MapOverlayGlassStyle.sheetFill(isDark: false);
      expect(sheetFill.opacity, closeTo(0.80, 0.005));
      expect(AppleGlassTokens.referenceFillSheet.opacity, closeTo(0.80, 0.005));

      // 7. Route sheet no longer uses white 0.96 (uses reference routeSheetFill == 0.80)
      final routeSheetFill = MapOverlayGlassStyle.routeSheetFill(isDark: false);
      expect(routeSheetFill.opacity, closeTo(0.80, 0.005));
      expect(routeSheetFill.opacity, isNot(closeTo(0.96, 0.01)));
      expect(AppleGlassTokens.referenceFillRouteSheet.opacity, closeTo(0.80, 0.005));

      // 8. Drawer cards use secondary reference (0.55 - 0.65)
      final cardFill = MapOverlayGlassStyle.cardFill(isDark: false);
      expect(cardFill.opacity, inInclusiveRange(0.55, 0.65));
      final drawerCardBorder = MapOverlayGlassStyle.drawerCardBorder(isDark: false);
      expect(drawerCardBorder.top.width, equals(0.8));
      expect(drawerCardBorder.top.color.opacity, closeTo(0.55, 0.01));
    });

    test('ReferenceGlassSurface builds container with exact golden material parameters', () {
      const surface = ReferenceGlassSurface(
        width: 48,
        radius: 24,
        isDark: false,
        child: SizedBox(),
      );

      expect(surface.width, equals(48));
      expect(surface.radius, equals(24));
      expect(surface.blurSigma, equals(20.0));
      expect(surface.fillColor, isNull); // Falls back to effectiveFill 0.85
    });

    testWidgets('Right toolbar and bottom search capsule use ReferenceGlassSurface, NOT WateryLiquidGlassCapsule', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      // Verify ReferenceGlassSurface instances exist on screen
      final refGlassFinder = find.byType(ReferenceGlassSurface);
      expect(refGlassFinder, findsWidgets);

      // Verify right-side vertical toolbar uses ReferenceGlassSurface (width: 48, radius: 24)
      final surfaces = tester.widgetList<ReferenceGlassSurface>(refGlassFinder);
      final toolbarSurfaces = surfaces.where((s) => s.width == 48 && s.radius == 24);
      expect(toolbarSurfaces, isNotEmpty, reason: 'Right toolbar must use ReferenceGlassSurface with width 48, radius 24');

      // Verify bottom search pill uses ReferenceGlassSurface (height: 50, radius: 25)
      final searchPillSurfaces = surfaces.where((s) => s.height == 50 && s.radius == 25);
      expect(searchPillSurfaces, isNotEmpty, reason: 'Bottom search capsule must use ReferenceGlassSurface with height 50, radius 25');

      // Confirm WateryLiquidGlassCapsule is NOT used for right toolbar or bottom search
      final wateryCapsuleFinder = find.byType(WateryLiquidGlassCapsule);
      expect(wateryCapsuleFinder, findsNothing, reason: 'Surfaces must not use WateryLiquidGlassCapsule');
    });

    testWidgets('Drawer uses ReferenceGlassSurface with blur 20 and reference tokens', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final scaffoldState = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      final drawerFinder = find.byType(Drawer);
      expect(drawerFinder, findsOneWidget);

      final drawerGlassFinder = find.descendant(
        of: drawerFinder,
        matching: find.byType(ReferenceGlassSurface),
      );
      expect(drawerGlassFinder, findsOneWidget);

      final drawerGlass = tester.widget<ReferenceGlassSurface>(drawerGlassFinder);
      expect(drawerGlass.blurSigma, equals(20.0));
      expect(drawerGlass.fillColor?.opacity, closeTo(0.78, 0.01));
    });

    testWidgets('Search modal bottom sheet uses ReferenceGlassSurface at root', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final searchPillFinder = find.text('Tìm kiếm điểm đến...');
      expect(searchPillFinder, findsOneWidget);
      await tester.tap(searchPillFinder);
      await tester.pumpAndSettle();

      // Find DraggableScrollableSheet
      final sheetFinder = find.byType(DraggableScrollableSheet);
      expect(sheetFinder, findsOneWidget);

      // Verify ReferenceGlassSurface is used for the search modal root sheet
      final sheetGlassFinder = find.descendant(
        of: sheetFinder,
        matching: find.byType(ReferenceGlassSurface),
      );
      expect(sheetGlassFinder, findsOneWidget);

      final sheetGlass = tester.widget<ReferenceGlassSurface>(sheetGlassFinder);
      expect(sheetGlass.blurSigma, equals(20.0));
      expect(sheetGlass.fillColor?.opacity, closeTo(0.80, 0.01));
    });
  });
}
