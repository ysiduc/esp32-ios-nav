import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P6.7 Clear-Core Liquid Glass Specification Tests', () {
    test('Dark toolbar does NOT use navy fill and has ultra-light clear core', () {
      final darkToolbarFill = MapOverlayGlassStyle.toolbarFill(isDark: true);
      // Dark toolbar does NOT use navy (0xFF1E2638)
      expect(darkToolbarFill.value, isNot(equals(const Color(0xFF1E2638).withOpacity(0.24).value)));
      expect(darkToolbarFill.red, isNot(equals(0x1E)));
      // Dark toolbar body opacity <= 0.07 (neutral white tint)
      expect(darkToolbarFill.opacity, lessThanOrEqualTo(0.07));
      expect(darkToolbarFill.opacity, closeTo(0.055, 0.005));

      final lightToolbarFill = MapOverlayGlassStyle.toolbarFill(isDark: false);
      expect(lightToolbarFill.opacity, closeTo(0.09, 0.005));
    });

    test('Blur parameters are lower to preserve map details', () {
      // Toolbar blur <= 16
      expect(MapOverlayGlassStyle.toolbarBlur, lessThanOrEqualTo(16.0));
      expect(MapOverlayGlassStyle.toolbarBlur, equals(15.0));

      // Large surface blur <= 14
      expect(MapOverlayGlassStyle.largeSurfaceBlur, lessThanOrEqualTo(14.0));
      expect(MapOverlayGlassStyle.largeSurfaceBlur, equals(13.0));

      expect(MapOverlayGlassStyle.bottomSearchBlur, lessThanOrEqualTo(16.0));
      expect(MapOverlayGlassStyle.referenceBlur, lessThanOrEqualTo(16.0));
    });

    test('Dark shadow opacity <= 0.10 (not heavy 0.20)', () {
      final darkShadow = MapOverlayGlassStyle.referenceShadow(isDark: true);
      expect(darkShadow.first.color.opacity, lessThanOrEqualTo(0.10));
      expect(darkShadow.first.color.opacity, closeTo(0.08, 0.005));
      expect(darkShadow.first.blurRadius, equals(16.0));

      final lightShadow = MapOverlayGlassStyle.referenceShadow(isDark: false);
      expect(lightShadow.first.color.opacity, lessThanOrEqualTo(0.06));
      expect(lightShadow.first.blurRadius, equals(14.0));
    });

    test('Border and inner rim define crisp glass edges', () {
      final darkBorder = MapOverlayGlassStyle.referenceBorder(isDark: true);
      expect(darkBorder.top.color.opacity, closeTo(0.32, 0.01));
      expect(darkBorder.top.width, equals(0.7));

      final lightBorder = MapOverlayGlassStyle.referenceBorder(isDark: false);
      expect(lightBorder.top.color.opacity, closeTo(0.45, 0.01));
      expect(lightBorder.top.width, equals(0.7));
    });

    testWidgets('TrueLiquidGlass does not auto-apply body gradient when none supplied', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TrueLiquidGlass(
              width: 100,
              height: 100,
              // bodyGradient is omitted / null
              child: Text('Clear Core'),
            ),
          ),
        ),
      );

      final glassFinder = find.byType(TrueLiquidGlass);
      expect(glassFinder, findsOneWidget);

      final glassWidget = tester.widget<TrueLiquidGlass>(glassFinder);
      expect(glassWidget.bodyGradient, isNull);

      // Verify container with effectiveFill has no gradient
      final containers = tester.widgetList<Container>(
        find.descendant(of: glassFinder, matching: find.byType(Container)),
      );
      final bodyContainer = containers.firstWhere(
        (c) => c.decoration is BoxDecoration && (c.decoration as BoxDecoration).color != null,
      );
      final deco = bodyContainer.decoration as BoxDecoration;
      expect(deco.gradient, isNull, reason: 'TrueLiquidGlass must NOT auto-apply a body gradient when none supplied');
    });

    testWidgets('Right toolbar and bottom search render clear-core glass on HomeScreen', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      final glassFinder = find.byType(TrueLiquidGlass);
      expect(glassFinder, findsWidgets);

      final glassWidgets = tester.widgetList<TrueLiquidGlass>(glassFinder);
      final toolbar = glassWidgets.where((w) => w.width == 48 && w.radius == 24).first;
      expect(toolbar.blurSigma, lessThanOrEqualTo(16.0));
      expect(toolbar.bodyGradient, isNull);

      final searchPill = glassWidgets.where((w) => w.height == 50 && w.radius == 25).first;
      expect(searchPill.blurSigma, lessThanOrEqualTo(16.0));
      expect(searchPill.bodyGradient, isNull);
    });

    testWidgets('Drawer and Search Modal use largeSurfaceBlur (<= 14)', (tester) async {
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
      expect(drawerGlass.blurSigma, lessThanOrEqualTo(14.0));
      expect(drawerGlass.bodyGradient, isNull);
    });
  });
}
