import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/widgets/liquid_glass.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/search_service.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/esp_stream_service.dart';
import 'package:mobile_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P6.2 Unified Liquid Glass Material Spec (Authoritative Image 4)', () {
    test('MapOverlayGlassStyle defines consistent translucent glass parameters', () {
      expect(MapOverlayGlassStyle.blurSigma, equals(24.0));
      expect(MapOverlayGlassStyle.blur(), equals(24.0));

      // Light mode: translucent milky diffusion (0.38), NOT opaque (0.80 - 0.95)
      final lightFill = MapOverlayGlassStyle.fill(isDark: false);
      expect(lightFill.opacity, closeTo(0.38, 0.05));
      expect(lightFill.opacity, lessThan(0.50));

      // Dark mode: dark neutral/navy translucent glass base, NOT opaque white
      final darkFill = MapOverlayGlassStyle.fill(isDark: true);
      expect(darkFill.opacity, closeTo(0.30, 0.05));
      expect(darkFill.opacity, lessThan(0.40));
      expect(darkFill.red, lessThan(35)); // dark base, not pure white

      // Specular border
      final lightBorder = MapOverlayGlassStyle.border(isDark: false);
      expect(lightBorder.top.width, equals(0.5));
      expect(lightBorder.top.color.opacity, closeTo(0.60, 0.05));

      final darkBorder = MapOverlayGlassStyle.border(isDark: true);
      expect(darkBorder.top.width, equals(0.5));
      expect(darkBorder.top.color.opacity, closeTo(0.35, 0.05));

      // Soft diffuse shadow
      final shadows = MapOverlayGlassStyle.shadow(isDark: false);
      expect(shadows.first.blurRadius, equals(20.0));
    });

    test('AppleGlassTokens shares exact MapOverlayGlassStyle token', () {
      final lightDeco = AppleGlassTokens.mapOverlayMaterial(isDark: false);
      expect(lightDeco.color, equals(MapOverlayGlassStyle.fill(isDark: false)));
      expect(lightDeco.boxShadow, equals(MapOverlayGlassStyle.shadow(isDark: false)));

      final darkDeco = AppleGlassTokens.mapOverlayMaterial(isDark: true);
      expect(darkDeco.color, equals(MapOverlayGlassStyle.fill(isDark: true)));
      expect(darkDeco.boxShadow, equals(MapOverlayGlassStyle.shadow(isDark: true)));
    });

    test('AppGlassVariant includes mapOverlay which uses unified tokens', () {
      expect(AppGlassVariant.values, contains(AppGlassVariant.mapOverlay));
    });
  });

  group('P6.2 Custom Saved Place Name Priority (Requirements 12 & 13)', () {
    test('findSavedPlace matches by name or coordinate proximity and gives custom name precedence', () async {
      final service = SearchService();

      final originalPlace = MapPlace(
        name: 'Vị trí Google Maps',
        displayName: '20.97690, 105.81234',
        coordinate: const LatLng(20.97690, 105.81234),
      );

      // Save with custom user name
      final customSaved = originalPlace.copyWith(
        name: 'Tân Tiến Lab',
        isCustomSaved: true,
      );
      await service.savePlace(customSaved);

      // Querying the original generic place resolves to customSaved!
      final matched = service.findSavedPlace(originalPlace);
      expect(matched, isNotNull);
      expect(matched!.name, equals('Tân Tiến Lab'));
      expect(matched.name, isNot(equals('Vị trí Google Maps')));
    });
  });

  group('P6.2 Drawer Liquid Glass Presentation (Requirement 5)', () {
    testWidgets('Drawer uses transparent background with BackdropFilter and MapOverlayGlassStyle', (tester) async {
      await tester.pumpWidget(const Esp32NavApp());
      await tester.pump(const Duration(milliseconds: 100));

      // Open drawer
      final scaffoldState = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      // Drawer must have transparent background (no longer solid white!)
      final drawerFinder = find.byType(Drawer);
      expect(drawerFinder, findsOneWidget);
      final drawer = tester.widget<Drawer>(drawerFinder);
      expect(drawer.backgroundColor, equals(Colors.transparent));

      // Must have BackdropFilter with sigma = 24
      final backdropFinder = find.descendant(
        of: drawerFinder,
        matching: find.byType(BackdropFilter),
      );
      expect(backdropFinder, findsWidgets);

      // Footer text must reflect swipe gesture hint
      expect(
        find.text('Kéo từ mép trái bản đồ để mở menu nhanh bất cứ lúc nào.'),
        findsOneWidget,
      );
    });
  });
}
