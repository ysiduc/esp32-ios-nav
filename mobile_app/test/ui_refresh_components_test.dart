import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:latlong2/latlong.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:mobile_app/models/route_model.dart";
import "package:mobile_app/services/search_service.dart";
import "package:mobile_app/theme/app_colors.dart";
import "package:mobile_app/theme/app_radius.dart";
import "package:mobile_app/theme/app_spacing.dart";
import "package:mobile_app/theme/app_typography.dart";
import "package:mobile_app/theme/app_theme.dart";
import "package:mobile_app/widgets/common/map_card.dart";
import "package:mobile_app/widgets/common/map_floating_button.dart";
import "package:mobile_app/widgets/common/map_pill_button.dart";
import "package:mobile_app/widgets/common/status_badge.dart";
import "package:mobile_app/widgets/common/section_header.dart";
import "package:mobile_app/widgets/common/empty_state_card.dart";
import "package:mobile_app/widgets/common/saved_place_dialog.dart";
import "package:mobile_app/widgets/common/saved_place_tile.dart";
import "package:mobile_app/widgets/common/route_option_card.dart";
import "package:mobile_app/screens/map_screen.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("P6.0 Design System Foundations", () {
    test("Design tokens are well-defined and consistent", () {
      expect(AppColors.primary, const Color(0xFF007AFF));
      expect(AppColors.surface, const Color(0xFFFFFFFF));
      expect(AppColors.canvas, const Color(0xFFF2F2F7));
      expect(AppColors.border, const Color(0x14000000));

      expect(AppRadius.lg, 18.0);
      expect(AppRadius.xl, 24.0);
      expect(AppRadius.pill, 999.0);

      expect(AppSpacing.xs, 4.0);
      expect(AppSpacing.sm, 8.0);
      expect(AppSpacing.md, 12.0);
      expect(AppSpacing.lg, 16.0);

      expect(AppTypography.largeTitle.fontWeight, FontWeight.w700);
      expect(AppTypography.headline.fontWeight, FontWeight.w600);
    });

    test("AppTheme creates valid ThemeData", () {
      final theme = AppTheme.lightTheme;
      expect(theme.scaffoldBackgroundColor, AppColors.canvas);
      expect(theme.primaryColor, AppColors.primary);
    });
  });

  group("P6.0 Reusable UI Components", () {
    testWidgets("MapCard renders child and responds to tap", (tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapCard(
              onTap: () => tapped = true,
              child: const Text("Card Content"),
            ),
          ),
        ),
      );

      expect(find.text("Card Content"), findsOneWidget);
      await tester.tap(find.text("Card Content"));
      expect(tapped, isTrue);
    });

    testWidgets("MapFloatingButton triggers callback", (tester) async {
      bool pressed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapFloatingButton(
              icon: Icons.layers_rounded,
              onTap: () => pressed = true,
            ),
          ),
        ),
      );

      await tester.tap(find.byType(MapFloatingButton));
      expect(pressed, isTrue);
    });

    testWidgets("MapPillButton renders label and icon", (tester) async {
      bool pressed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapPillButton(
              label: "Lọc kết quả",
              icon: Icons.filter_list_rounded,
              onTap: () => pressed = true,
            ),
          ),
        ),
      );

      expect(find.text("Lọc kết quả"), findsOneWidget);
      expect(find.byIcon(Icons.filter_list_rounded), findsOneWidget);
      await tester.tap(find.text("Lọc kết quả"));
      expect(pressed, isTrue);
    });

    testWidgets("StatusBadge renders label and handles tap", (tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatusBadge(
              text: "Đang định vị...",
              icon: Icons.my_location_rounded,
              color: AppColors.primary,
              onTap: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.text("Đang định vị..."), findsOneWidget);
      expect(find.byIcon(Icons.my_location_rounded), findsOneWidget);
      await tester.tap(find.text("Đang định vị..."));
      expect(tapped, isTrue);
    });

    testWidgets("SectionHeader displays title and action", (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SectionHeader(
              title: "Địa điểm đã lưu",
              trailing: const Text("Xóa tất cả"),
            ),
          ),
        ),
      );

      expect(find.text("ĐỊA ĐIỂM ĐÃ LƯU"), findsOneWidget);
      expect(find.text("Xóa tất cả"), findsOneWidget);
    });

    testWidgets("EmptyStateCard renders title and description", (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyStateCard(
              icon: Icons.bookmark_border_rounded,
              title: "Chưa có địa điểm",
              description: "Lưu địa điểm để xem tại đây.",
            ),
          ),
        ),
      );

      expect(find.text("Chưa có địa điểm"), findsOneWidget);
      expect(find.text("Lưu địa điểm để xem tại đây."), findsOneWidget);
      expect(find.byIcon(Icons.bookmark_border_rounded), findsOneWidget);
    });

    testWidgets("RouteOptionCard renders duration, distance, tag, and tap", (tester) async {
      bool selected = false;
      final testRoute = NavRoute(
        polylinePoints: const [
          LatLng(21.028, 105.854),
          LatLng(21.030, 105.856),
        ],
        steps: const [],
        totalDurationSeconds: 1080,
        totalDistanceMeters: 5200,
        summary: "Qua Phố Huế",
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RouteOptionCard(
              route: testRoute,
              isSelected: true,
              badgeText: "Nhanh nhất",
              onTap: () => selected = true,
            ),
          ),
        ),
      );

      expect(find.text("18 phút"), findsOneWidget);
      expect(find.text("(5.2 km)"), findsOneWidget);
      expect(find.text("Nhanh nhất"), findsOneWidget);
      expect(find.text("Qua Phố Huế"), findsOneWidget);
      await tester.tap(find.text("18 phút"));
      expect(selected, isTrue);
    });
  });

  group("P6.0 Saved Places UX - Name Input & Editing", () {
    testWidgets("SavedPlaceDialog allows custom name entry and saves", (tester) async {
      String? savedName;
      final testPlace = MapPlace(
        name: "Quán Cà Phê A",
        displayName: "123 Phố Huế, Hai Bà Trưng, Hà Nội",
        coordinate: const LatLng(21.015, 105.850),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SavedPlaceDialog(
              place: testPlace,
              onSave: (custom) => savedName = custom,
            ),
          ),
        ),
      );

      expect(find.text("Lưu địa điểm"), findsOneWidget);
      expect(find.text("Quán Cà Phê A"), findsOneWidget);

      // Enter custom name
      await tester.enterText(find.byType(TextField), "Cà phê quen");
      await tester.pump();

      await tester.tap(find.text("Lưu vào Danh sách"));
      expect(savedName, "Cà phê quen");
    });

    testWidgets("SavedPlaceTile triggers rename, route, and delete callbacks", (tester) async {
      bool renamed = false;
      bool routed = false;
      bool deleted = false;
      bool tapped = false;

      final testPlace = MapPlace(
        name: "Nhà",
        displayName: "Số 1 Đại Cồ Việt, Hà Nội",
        coordinate: const LatLng(21.006, 105.843),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SavedPlaceTile(
              place: testPlace,
              onTap: () => tapped = true,
              onRoute: () => routed = true,
              onRename: () => renamed = true,
              onDelete: () => deleted = true,
            ),
          ),
        ),
      );

      expect(find.text("Nhà"), findsOneWidget);
      expect(find.text("Số 1 Đại Cồ Việt, Hà Nội"), findsOneWidget);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      expect(renamed, isTrue);

      await tester.tap(find.byIcon(Icons.directions_rounded));
      expect(routed, isTrue);

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      expect(deleted, isTrue);

      await tester.tap(find.text("Nhà"));
      expect(tapped, isTrue);
    });

    test("SearchService.updateSavedPlace updates place name and persists", () async {
      SharedPreferences.setMockInitialValues({});
      final service = SearchService();

      final p1 = MapPlace(
        name: "Văn phòng",
        displayName: "Tòa nhà Keangnam, Nam Từ Liêm",
        coordinate: const LatLng(21.017, 105.784),
      );

      await service.savePlace(p1);
      expect(service.savedPlaces.length, 1);
      expect(service.savedPlaces.first.name, "Văn phòng");

      // Rename
      await service.updateSavedPlace(p1, "Công ty Keangnam");
      expect(service.savedPlaces.length, 1);
      expect(service.savedPlaces.first.name, "Công ty Keangnam");
      expect(service.savedPlaces.first.displayName, "Tòa nhà Keangnam, Nam Từ Liêm");
    });
  });

  group("P6.0 Startup Location Prioritization", () {
    test("selectRoutePlanningStart prioritizes physical location over raw and fallback", () {
      const physical = LatLng(21.035, 105.820);
      const raw = LatLng(21.030, 105.825);
      const fallback = LatLng(21.0285, 105.8542);

      final result1 = MapScreen.selectRoutePlanningStart(
        acceptedPhysicalLocation: physical,
        rawLocation: raw,
        fallbackLocation: fallback,
      );
      expect(result1, physical);

      final result2 = MapScreen.selectRoutePlanningStart(
        acceptedPhysicalLocation: null,
        rawLocation: raw,
        fallbackLocation: fallback,
      );
      expect(result2, raw);

      final result3 = MapScreen.selectRoutePlanningStart(
        acceptedPhysicalLocation: null,
        rawLocation: null,
        fallbackLocation: fallback,
      );
      expect(result3, fallback);
    });
  });
}
