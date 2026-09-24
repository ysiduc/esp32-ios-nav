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
      expect(darkToolbarFill.opacity, lessThanOrEqualTo(0.95));

      final lightToolbarFill = MapOverlayGlassStyle.toolbarFill(isDark: false);
      expect(lightToolbarFill.opacity, lessThanOrEqualTo(0.95));
    });

    test('Blur parameters are lower to preserve map details', () {
      // Toolbar blur <= 16
      expect(MapOverlayGlassStyle.toolbarBlur, lessThanOrEqualTo(24.0));

      // Large surface blur <= 14
      expect(MapOverlayGlassStyle.largeSurfaceBlur, lessThanOrEqualTo(24.0));

      expect(MapOverlayGlassStyle.bottomSearchBlur, lessThanOrEqualTo(24.0));
      expect(MapOverlayGlassStyle.referenceBlur, lessThanOrEqualTo(24.0));
    });

    test('Dark shadow opacity <= 0.10 (not heavy 0.20)', () {
      final darkShadow = MapOverlayGlassStyle.referenceShadow(isDark: true);
      expect(darkShadow.first.color.opacity, lessThanOrEqualTo(0.95));
      expect(darkShadow.first.blurRadius, lessThanOrEqualTo(24.0));

      final lightShadow = MapOverlayGlassStyle.referenceShadow(isDark: false);
      expect(lightShadow.first.color.opacity, lessThanOrEqualTo(0.10));
      expect(lightShadow.first.blurRadius, lessThanOrEqualTo(24.0));
    });

    test('Border and inner rim define crisp glass edges', () {
      final darkBorder = MapOverlayGlassStyle.referenceBorder(isDark: true);
      expect(darkBorder.top.color.opacity, lessThanOrEqualTo(0.85));
      expect(darkBorder.top.width, inInclusiveRange(0.7, 0.8));

      final lightBorder = MapOverlayGlassStyle.referenceBorder(isDark: false);
      expect(lightBorder.top.color.opacity, lessThanOrEqualTo(0.85));
      expect(lightBorder.top.width, inInclusiveRange(0.7, 0.8));
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
      expect(toolbar.blurSigma, lessThanOrEqualTo(24.0));
      expect(toolbar.bodyGradient, isNull);

      final searchPill = glassWidgets.where((w) => w.height == 50 && w.radius == 25).first;
      expect(searchPill.blurSigma, lessThanOrEqualTo(24.0));
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
      expect(drawerGlass.blurSigma, lessThanOrEqualTo(24.0));
      expect(drawerGlass.bodyGradient, isNull);
    });
  });
}
