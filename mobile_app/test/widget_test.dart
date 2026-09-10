import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const Esp32NavApp());
    expect(find.byType(Esp32NavApp), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });
}
