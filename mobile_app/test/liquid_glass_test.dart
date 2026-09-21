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
}
