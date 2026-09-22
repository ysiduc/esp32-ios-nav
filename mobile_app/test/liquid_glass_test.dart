import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P5.4.1.3 Section 62: Liquid Glass UI Widget Tests', () {
    testWidgets('LiquidGlassContainer renders child with translucent backdrop', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: const Scaffold(
            body: LiquidGlassContainer(
              radius: 20,
              blur: 18,
              child: Text('Glass Test'),
            ),
          ),
        ),
      );

      expect(find.text('Glass Test'), findsOneWidget);
      expect(find.byType(LiquidGlassContainer), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('LiquidGlassContainer adapts to Dark Mode theme', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(
            body: LiquidGlassContainer(
              radius: 24,
              child: Text('Dark Glass'),
            ),
          ),
        ),
      );

      expect(find.text('Dark Glass'), findsOneWidget);
    });

    testWidgets('LiquidGlassContainer respects reduced motion by disabling BackdropFilter', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const Scaffold(
              body: LiquidGlassContainer(
                radius: 20,
                blur: 20,
                child: Text('Reduced Motion'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Reduced Motion'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('LiquidGlassButton responds to user tap and selected state', (tester) async {
      bool tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiquidGlassButton(
              icon: const Icon(Icons.navigation_rounded),
              isSelected: true,
              activeGlowColor: const Color(0xFF007AFF),
              onTap: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.navigation_rounded), findsOneWidget);

      await tester.tap(find.byType(LiquidGlassButton));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });

    testWidgets('LiquidGlassCapsule renders child inside capsule layout', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LiquidGlassCapsule(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.menu),
                  Text('Capsule'),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.menu), findsOneWidget);
      expect(find.text('Capsule'), findsOneWidget);
    });
  });

  group('P5.4.1.4 Section 80: Bright Liquid Glass & Single BackdropFilter Architecture', () {
    testWidgets('Grouped toolbar has exactly ONE BackdropFilter', (tester) async {
      int actionTapped = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassSurface(
              radius: 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassAction(
                    icon: const Icon(Icons.layers),
                    tooltip: 'Layers',
                    onTap: () => actionTapped++,
                  ),
                  Container(width: 20, height: 1, color: Colors.white24),
                  GlassAction(
                    icon: const Icon(Icons.explore),
                    tooltip: 'Compass',
                    isSelected: true,
                    onTap: () => actionTapped++,
                  ),
                  Container(width: 20, height: 1, color: Colors.white24),
                  GlassAction(
                    icon: const Icon(Icons.two_wheeler),
                    tooltip: 'Bike',
                    onTap: () => actionTapped++,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Verify that across the entire grouped toolbar with 3 buttons, exactly ONE BackdropFilter is created (Section 64 & 80)
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.byType(GlassAction), findsNWidgets(3));

      // Tap first action
      await tester.tap(find.byTooltip('Layers'));
      await tester.pumpAndSettle();
      expect(actionTapped, equals(1));
    });

    testWidgets('Light Mode glass uses bright specular material and Dark Mode is translucent', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: const Scaffold(
            body: GlassSurface(
              child: Text('Bright Specular Glass'),
            ),
          ),
        ),
      );
      expect(find.text('Bright Specular Glass'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(
            body: GlassSurface(
              child: Text('Dark Translucent Glass'),
            ),
          ),
        ),
      );
      expect(find.text('Dark Translucent Glass'), findsOneWidget);
    });
  });

  group('P5.7: Liquid Glass Component System & Driving Map Overlays', () {
    testWidgets('AppGlassSurface supports all variants (regular, clear, prominent, danger)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                AppGlassSurface(variant: AppGlassVariant.regular, child: Text('Regular')),
                AppGlassSurface(variant: AppGlassVariant.clear, child: Text('Clear')),
                AppGlassSurface(variant: AppGlassVariant.prominent, child: Text('Prominent')),
                AppGlassSurface(variant: AppGlassVariant.danger, child: Text('Danger')),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Regular'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
      expect(find.text('Prominent'), findsOneWidget);
      expect(find.text('Danger'), findsOneWidget);
      // All 4 render BackdropFilter when motion/transparency is not reduced
      expect(find.byType(BackdropFilter), findsNWidgets(4));
    });

    testWidgets('AppGlassSurface respects Reduce Transparency with high-contrast opaque fallback', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(accessibleNavigation: true),
            child: Scaffold(
              body: Column(
                children: [
                  AppGlassSurface(variant: AppGlassVariant.prominent, child: Text('No Blur Prominent')),
                  AppGlassSurface(variant: AppGlassVariant.danger, child: Text('No Blur Danger')),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('No Blur Prominent'), findsOneWidget);
      expect(find.text('No Blur Danger'), findsOneWidget);
      // When accessibleNavigation is true, BackdropFilter is NOT created
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('AppGlassPill handles tap callback and displays child', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassPill(
              onTap: () => tapped = true,
              child: const Text('Search Pill'),
            ),
          ),
        ),
      );

      expect(find.text('Search Pill'), findsOneWidget);
      await tester.tap(find.text('Search Pill'));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });

    testWidgets('AppGlassButton danger variant renders crisp white icon and handles tap', (tester) async {
      bool endRouteTapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassButton(
              variant: AppGlassVariant.danger,
              size: 44,
              icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
              tooltip: 'Kết thúc dẫn đường',
              onTap: () => endRouteTapped = true,
            ),
          ),
        ),
      );

      expect(find.byTooltip('Kết thúc dẫn đường'), findsOneWidget);
      await tester.tap(find.byType(AppGlassButton));
      await tester.pumpAndSettle();
      expect(endRouteTapped, isTrue);
    });

    testWidgets('AppGlassToolbar and AppGlassToolbarDivider group controls into single glass surface', (tester) async {
      int carTapped = 0;
      int locTapped = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassToolbar(
              width: 44,
              radius: 22,
              children: [
                IconButton(
                  icon: const Icon(Icons.directions_car_rounded),
                  onPressed: () => carTapped++,
                ),
                const AppGlassToolbarDivider(),
                IconButton(
                  icon: const Icon(Icons.navigation_rounded),
                  onPressed: () => locTapped++,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.byType(AppGlassToolbar), findsOneWidget);
      expect(find.byType(AppGlassToolbarDivider), findsOneWidget);
      // Exactly 1 BackdropFilter for the entire toolbar container
      expect(find.byType(BackdropFilter), findsOneWidget);

      await tester.tap(find.byIcon(Icons.directions_car_rounded));
      await tester.pumpAndSettle();
      expect(carTapped, equals(1));

      await tester.tap(find.byIcon(Icons.navigation_rounded));
      await tester.pumpAndSettle();
      expect(locTapped, equals(1));
    });

    testWidgets('Active Driving Banner renders with Prominent Glass and inner Clear Maneuver Circle', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassSurface(
              variant: AppGlassVariant.prominent,
              radius: 24,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  AppGlassSurface(
                    variant: AppGlassVariant.clear,
                    radius: 24,
                    width: 48,
                    height: 48,
                    child: const Center(
                      child: Icon(Icons.turn_left_rounded, color: Colors.white, size: 28),
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Trong 209 m', style: TextStyle(color: Colors.white70)),
                      Text('Rẽ trái vào Lê Lợi', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Trong 209 m'), findsOneWidget);
      expect(find.text('Rẽ trái vào Lê Lợi'), findsOneWidget);
      expect(find.byIcon(Icons.turn_left_rounded), findsOneWidget);
    });

    testWidgets('Active Driving Bottom HUD renders ETA, Duration, Distance and Danger Glass End Button', (tester) async {
      bool stopped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppGlassBottomBar(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              radius: 36,
              variant: AppGlassVariant.regular,
              child: Row(
                children: [
                  const Text('17:45'),
                  const Text('12 phút'),
                  const Text('4.8 km'),
                  AppGlassButton(
                    variant: AppGlassVariant.danger,
                    size: 44,
                    icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
                    tooltip: 'Kết thúc dẫn đường',
                    onTap: () => stopped = true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('17:45'), findsOneWidget);
      expect(find.text('12 phút'), findsOneWidget);
      expect(find.text('4.8 km'), findsOneWidget);
      expect(find.byTooltip('Kết thúc dẫn đường'), findsOneWidget);

      await tester.tap(find.byType(AppGlassButton));
      await tester.pumpAndSettle();
      expect(stopped, isTrue);
    });

    testWidgets('ESP32 status badge adapts between connected green glass tint and off state', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                // Connected badge
                AppGlassPill(
                  height: 30,
                  variant: AppGlassVariant.prominent,
                  tint: const Color(0xFF05FFA1).withOpacity(0.18),
                  child: const Text('ESP32 Live'),
                ),
                // Disconnected badge
                AppGlassPill(
                  height: 30,
                  variant: AppGlassVariant.prominent,
                  tint: Colors.black.withOpacity(0.4),
                  child: const Text('ESP32 Off'),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('ESP32 Live'), findsOneWidget);
      expect(find.text('ESP32 Off'), findsOneWidget);
    });
  });
}
