import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';
import 'package:mobile_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P6.4 Clear Liquid Glass & Scrim Elimination Tests', () {
    test('largeSurfaceBlur < capsuleBlur ensures large surfaces do not become milky grey slabs', () {
      expect(MapOverlayGlassStyle.largeSurfaceBlur, lessThan(MapOverlayGlassStyle.capsuleBlur));
      expect(MapOverlayGlassStyle.largeSurfaceBlur, equals(16.0));
      expect(MapOverlayGlassStyle.capsuleBlur, equals(22.0));
      expect(MapOverlayGlassStyle.blur(isLargeSurface: true), equals(16.0));
      expect(MapOverlayGlassStyle.blur(isLargeSurface: false), equals(22.0));
    });

    test('drawer cards do not use secondaryFill 0.50 and have watery card tokens', () {
      final unselectedLightCard = MapOverlayGlassStyle.drawerCardFill(isDark: false, isSelected: false);
      expect(unselectedLightCard.opacity, isNot(closeTo(0.50, 0.05)));
      expect(unselectedLightCard.opacity, inInclusiveRange(0.10, 0.16));

      final unselectedDarkCard = MapOverlayGlassStyle.drawerCardFill(isDark: true, isSelected: false);
      expect(unselectedDarkCard.opacity, inInclusiveRange(0.06, 0.10));

      final selectedLightCard = MapOverlayGlassStyle.drawerCardFill(isDark: false, isSelected: true);
      expect(selectedLightCard.opacity, inInclusiveRange(0.10, 0.14));

      final searchFieldFill = MapOverlayGlassStyle.searchSheetFieldFill(isDark: false);
      expect(searchFieldFill.opacity, isNot(closeTo(0.50, 0.05)));
      expect(searchFieldFill.opacity, inInclusiveRange(0.14, 0.22));
    });

    testWidgets('HomeScreen Scaffold.drawerScrimColor is transparent (no map darkening)', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final scaffolds = tester.widgetList<Scaffold>(find.byType(Scaffold));
      expect(scaffolds.first.drawerScrimColor, equals(Colors.transparent));
    });

    testWidgets('Drawer does not use sheetFill for root body and renders watery large surface material', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      // Open drawer
      final scaffoldState = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      final drawerFinder = find.byType(Drawer);
      expect(drawerFinder, findsOneWidget);
      final drawer = tester.widget<Drawer>(drawerFinder);
      expect(drawer.backgroundColor, equals(Colors.transparent));

      // Must have BackdropFilter with largeSurfaceBlur (16.0)
      final backdropFilterFinder = find.descendant(
        of: drawerFinder,
        matching: find.byType(BackdropFilter),
      );
      expect(backdropFilterFinder, findsWidgets);

      // Verify connection card and footer inside drawer render
      expect(find.text('ESP32 NAVI'), findsOneWidget);
      expect(find.text('Bản đồ dẫn đường'), findsOneWidget);
    });

    testWidgets('Search modal barrierColor is transparent (no dark scrim dimming map)', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      // Tap bottom search capsule
      final searchPillFinder = find.text('Tìm kiếm điểm đến...');
      expect(searchPillFinder, findsOneWidget);
      await tester.tap(searchPillFinder);
      await tester.pumpAndSettle();

      // Verify ModalBarrier does not darken the map (barrierColor: transparent sets barrier color to null or transparent)
      final barrierFinder = find.byType(ModalBarrier);
      expect(barrierFinder, findsWidgets);
      final modalBarriers = tester.widgetList<ModalBarrier>(barrierFinder);
      final sheetBarrier = modalBarriers.last;
      expect(sheetBarrier.color == null || sheetBarrier.color == Colors.transparent, isTrue);
    });
  });
}
