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
      // Under reduced motion, BackdropFilter must be bypassed to eliminate GPU blur load
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
}
