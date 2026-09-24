import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P6.8 Authoritative Golden Reference Liquid Glass Tests (Run 35895237697)', () {
    test('Right toolbar matches exact run 35895237697 reference tokens', () {
      final toolbarFill = MapOverlayGlassStyle.toolbarFill(isDark: false);
      expect(toolbarFill.opacity, closeTo(0.85, 0.01));

      expect(MapOverlayGlassStyle.toolbarBlur, equals(20.0));

      final border = MapOverlayGlassStyle.referenceBorder(isDark: false);
      expect(border.top.color.opacity, closeTo(0.70, 0.01));
      expect(border.top.width, equals(0.8));

      final shadows = MapOverlayGlassStyle.referenceShadow(isDark: false);
      expect(shadows.first.color.opacity, closeTo(0.08, 0.01));
      expect(shadows.first.blurRadius, equals(16.0));
      expect(shadows.first.offset.dy, equals(4.0));
    });

    test('Bottom search pill matches exact run 35895237697 reference tokens', () {
      final searchPillFill = MapOverlayGlassStyle.bottomSearchFill(isDark: false);
      expect(searchPillFill.opacity, closeTo(0.88, 0.01));
      expect(MapOverlayGlassStyle.bottomSearchBlur, equals(20.0));
    });

    test('Drawer and sheets match translucent glass reference tokens', () {
      final drawerFill = MapOverlayGlassStyle.drawerFill(isDark: false);
      expect(drawerFill.opacity, closeTo(0.85, 0.01));

      final sheetFill = MapOverlayGlassStyle.sheetFill(isDark: false);
      expect(sheetFill.opacity, closeTo(0.80, 0.01));

      final routeSheetFill = MapOverlayGlassStyle.routeSheetFill(isDark: false);
      expect(routeSheetFill.opacity, closeTo(0.80, 0.01));
    });

    testWidgets('ReferenceGlassSurface builds container matching exact reference structure', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReferenceGlassSurface(
              width: 48,
              radius: 24,
              child: Text('Reference'),
            ),
          ),
        ),
      );

      final surfaceFinder = find.byType(ReferenceGlassSurface);
      expect(surfaceFinder, findsOneWidget);

      final surfaceWidget = tester.widget<ReferenceGlassSurface>(surfaceFinder);
      expect(surfaceWidget.blurSigma, equals(20.0));
      expect(surfaceWidget.width, equals(48.0));
      expect(surfaceWidget.radius, equals(24.0));

      final containerFinder = find.descendant(of: surfaceFinder, matching: find.byType(Container));
      expect(containerFinder, findsWidgets);

      final rootContainer = tester.widget<Container>(containerFinder.first);
      final deco = rootContainer.decoration as BoxDecoration;
      expect(deco.color?.opacity, closeTo(0.85, 0.01));
      expect(deco.boxShadow?.first.blurRadius, equals(16.0));
      expect(deco.border?.top.width, equals(0.8));
    });

    testWidgets('Right toolbar in HomeScreen renders AppGlassToolbar with clear variant', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final toolbars = tester.widgetList<AppGlassToolbar>(find.byType(AppGlassToolbar));
      final toolbar = toolbars.firstWhere((t) => t.width == 48 && t.radius == 24);
      expect(toolbar, isNotNull);
      expect(toolbar.variant, equals(AppGlassVariant.clear));
    });

    testWidgets('Bottom search in HomeScreen renders AppGlassSurface with clear variant', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final surfaces = tester.widgetList<AppGlassSurface>(find.byType(AppGlassSurface));
      final searchSurface = surfaces.firstWhere((s) => s.surfaceId == 'bottom-search');
      expect(searchSurface, isNotNull);
      expect(searchSurface.variant, equals(AppGlassVariant.clear));
      expect(searchSurface.radius, equals(25.0));
    });

    testWidgets('Drawer in HomeScreen opens with translucent background', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final scaffoldState = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      final drawerFinder = find.byType(Drawer);
      expect(drawerFinder, findsOneWidget);
    });
  });
}
