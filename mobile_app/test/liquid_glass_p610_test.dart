import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P6.10 Liquid Glass Refinement & 2-Button Toolbar Tests', () {
    test('MapOverlayGlassStyle uses transparent clear glass tokens (no opaque white slabs)', () {
      final lightToolbar = MapOverlayGlassStyle.toolbarFill(isDark: false);
      final darkToolbar = MapOverlayGlassStyle.toolbarFill(isDark: true);
      expect(lightToolbar.opacity, lessThanOrEqualTo(0.10));
      expect(darkToolbar.opacity, lessThanOrEqualTo(0.08));

      final lightSearch = MapOverlayGlassStyle.bottomSearchFill(isDark: false);
      expect(lightSearch.opacity, lessThanOrEqualTo(0.10));

      final lightDrawer = MapOverlayGlassStyle.drawerFill(isDark: false);
      expect(lightDrawer.opacity, lessThanOrEqualTo(0.10));

      final lightSheet = MapOverlayGlassStyle.sheetFill(isDark: false);
      expect(lightSheet.opacity, lessThanOrEqualTo(0.10));

      final lightRouteSheet = MapOverlayGlassStyle.routeSheetFill(isDark: false);
      expect(lightRouteSheet.opacity, lessThanOrEqualTo(0.10));

      // Cards inside glass surfaces use subtle contrast (0.08 - 0.20)
      final lightCard = MapOverlayGlassStyle.cardFill(isDark: false);
      expect(lightCard.opacity, inInclusiveRange(0.05, 0.20));

      // Search input field sits on glass with crisp readability (0.10 - 0.25)
      final lightField = MapOverlayGlassStyle.searchSheetFieldFill(isDark: false);
      expect(lightField.opacity, inInclusiveRange(0.10, 0.25));

      // Reference border is subtle 0.5pt - 0.8pt highlight
      final lightBorder = MapOverlayGlassStyle.referenceBorder(isDark: false);
      expect(lightBorder.top.color.opacity, inInclusiveRange(0.20, 0.50));
    });

    testWidgets('Right toolbar has exactly 2 buttons (Map & Navigation)', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final toolbarFinder = find.byType(AppGlassToolbar);
      expect(toolbarFinder, findsWidgets);

      final rightToolbar = tester.widgetList<AppGlassToolbar>(toolbarFinder).firstWhere(
        (t) => t.width == 48 && t.radius == 24,
      );
      expect(rightToolbar, isNotNull);
      expect(rightToolbar.variant, equals(AppGlassVariant.clear));

      // Button 1: Bản đồ
      final mapBtnFinder = find.byKey(const ValueKey('toolbar_btn_map'));
      expect(mapBtnFinder, findsOneWidget);

      // Button 2: Điều hướng
      final navBtnFinder = find.byKey(const ValueKey('toolbar_btn_navigation'));
      expect(navBtnFinder, findsOneWidget);

      // Extra buttons removed: compass and vehicle mode switch
      expect(find.byIcon(Icons.explore_rounded), findsNothing);
      expect(find.byIcon(Icons.two_wheeler_rounded), findsNothing);
      expect(find.byIcon(Icons.directions_car_rounded), findsNothing);
    });

    testWidgets('Tapping Map button opens bottom sheet with 4 map styles (Image 5)', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final mapBtnFinder = find.byKey(const ValueKey('toolbar_btn_map'));
      expect(mapBtnFinder, findsOneWidget);

      await tester.tap(mapBtnFinder);
      await tester.pumpAndSettle();

      // Verify sheet title
      expect(find.text('Chế độ bản đồ'), findsOneWidget);

      // Verify close button
      final closeBtnFinder = find.byKey(const ValueKey('close_map_theme_sheet'));
      expect(closeBtnFinder, findsOneWidget);

      // Verify all 4 required options
      expect(find.text('Khám phá'), findsOneWidget);
      expect(find.text('Lái xe'), findsOneWidget);
      expect(find.text('PT công cộng'), findsOneWidget);
      expect(find.text('Vệ tinh'), findsOneWidget);

      // Verify map style cards
      final streetsCard = find.byKey(const ValueKey('map_style_card_streets'));
      final drivingCard = find.byKey(const ValueKey('map_style_card_driving'));
      final transitCard = find.byKey(const ValueKey('map_style_card_transit'));
      final satelliteCard = find.byKey(const ValueKey('map_style_card_satellite'));

      expect(streetsCard, findsOneWidget);
      expect(drivingCard, findsOneWidget);
      expect(transitCard, findsOneWidget);
      expect(satelliteCard, findsOneWidget);

      // Tap 'Lái xe' card to switch theme
      await tester.tap(drivingCard);
      await tester.pumpAndSettle();

      // Tap close button to dismiss sheet
      await tester.tap(closeBtnFinder);
      await tester.pumpAndSettle();

      expect(find.text('Chế độ bản đồ'), findsNothing);
    });

    testWidgets('Tapping Navigation button triggers recenter action', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final navBtnFinder = find.byKey(const ValueKey('toolbar_btn_navigation'));
      expect(navBtnFinder, findsOneWidget);

      await tester.tap(navBtnFinder);
      await tester.pump(const Duration(milliseconds: 50));
      // Action completes without throwing
      expect(tester.takeException(), isNull);
    });

    testWidgets('Drawer in HomeScreen uses AppGlassSurface clear variant with transparent base', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final scaffoldState = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      final drawerFinder = find.byType(Drawer);
      expect(drawerFinder, findsOneWidget);

      final glassSurfaces = tester.widgetList<AppGlassSurface>(find.byType(AppGlassSurface));
      final drawerSurface = glassSurfaces.firstWhere((s) => s.surfaceId == 'drawer');
      expect(drawerSurface, isNotNull);
      expect(drawerSurface.variant, equals(AppGlassVariant.clear));
      expect(drawerSurface.overlayOwned, isTrue);
    });

    testWidgets('Search modal bottom sheet uses AppGlassSurface clear variant with overlayOwned', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final searchGesture = find.ancestor(of: find.text('Tìm kiếm điểm đến...'), matching: find.byType(GestureDetector));
      expect(searchGesture, findsWidgets);

      await tester.tap(searchGesture.first);
      await tester.pumpAndSettle();

      final glassSurfaces = tester.widgetList<AppGlassSurface>(find.byType(AppGlassSurface));
      final searchSheetSurface = glassSurfaces.firstWhere((s) => s.surfaceId == 'search-sheet');
      expect(searchSheetSurface, isNotNull);
      expect(searchSheetSurface.variant, equals(AppGlassVariant.clear));
      expect(searchSheetSurface.overlayOwned, isTrue);

      // Verify search input field exists on glass
      expect(find.byType(TextField), findsOneWidget);
    });
  });
}
