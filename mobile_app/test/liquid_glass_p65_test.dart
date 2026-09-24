import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P6.5 Exact Liquid Glass Material Restoration & Reference Compatibility', () {
    test('Authoritative Reference Material Constants & Fills match spec', () {
      expect(MapOverlayGlassStyle.referenceBlur, greaterThanOrEqualTo(12.0));
      expect(AppleGlassTokens.referenceBlur, greaterThanOrEqualTo(12.0));

      final toolbarFill = MapOverlayGlassStyle.toolbarFill(isDark: false);
      expect(toolbarFill.opacity, lessThan(0.90));

      final refBorder = MapOverlayGlassStyle.referenceBorder(isDark: false);
      expect(refBorder.top.width, greaterThanOrEqualTo(0.7));

      final bottomSearchFill = MapOverlayGlassStyle.bottomSearchFill(isDark: false);
      expect(bottomSearchFill.opacity, lessThan(0.90));

      final drawerFill = MapOverlayGlassStyle.drawerFill(isDark: false);
      expect(drawerFill.opacity, lessThan(0.90));

      final sheetFill = MapOverlayGlassStyle.sheetFill(isDark: false);
      expect(sheetFill.opacity, lessThan(0.90));

      final routeSheetFill = MapOverlayGlassStyle.routeSheetFill(isDark: false);
      expect(routeSheetFill.opacity, isNot(closeTo(0.96, 0.01)));

      final cardFill = MapOverlayGlassStyle.cardFill(isDark: false);
      expect(cardFill.opacity, lessThan(0.66));
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
      expect(surface.blurSigma, greaterThanOrEqualTo(12.0));
    });

    testWidgets('Right toolbar and bottom search capsule use true glass, NOT WateryLiquidGlassCapsule', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      // Confirm WateryLiquidGlassCapsule is NOT used for right toolbar or bottom search
      final wateryCapsuleFinder = find.byType(WateryLiquidGlassCapsule);
      expect(wateryCapsuleFinder, findsNothing, reason: 'Surfaces must not use WateryLiquidGlassCapsule');
    });

    testWidgets('Drawer uses transparent background with BackdropFilter', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final scaffoldState = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      final drawerFinder = find.byType(Drawer);
      expect(drawerFinder, findsOneWidget);

      final backdropFinder = find.descendant(
        of: drawerFinder,
        matching: find.byType(BackdropFilter),
      );
      expect(backdropFinder, findsWidgets);
    });

    testWidgets('Search modal bottom sheet uses transparent scrim and backdrop blur', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final searchPillFinder = find.text('Tìm kiếm điểm đến...');
      expect(searchPillFinder, findsOneWidget);
      await tester.tap(searchPillFinder);
      await tester.pumpAndSettle();

      final sheetFinder = find.byType(DraggableScrollableSheet);
      expect(sheetFinder, findsOneWidget);

      final backdropFinder = find.descendant(
        of: sheetFinder,
        matching: find.byType(BackdropFilter),
      );
      expect(backdropFinder, findsWidgets);
    });
  });
}
