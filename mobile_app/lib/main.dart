import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/home_screen.dart';
import 'services/ble_service.dart';
import 'services/esp_stream_service.dart';
import 'services/navigation_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Esp32NavApp());
}

class Esp32NavApp extends StatelessWidget {
  const Esp32NavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<BleService>(
          create: (_) => BleService(),
        ),
        ChangeNotifierProxyProvider<BleService, NavigationManager>(
          create: (ctx) => NavigationManager(
            bleService: Provider.of<BleService>(ctx, listen: false),
          ),
          update: (ctx, bleService, previousNavManager) =>
              previousNavManager ?? NavigationManager(bleService: bleService),
        ),
        ChangeNotifierProxyProvider<BleService, EspStreamService>(
          create: (ctx) => EspStreamService(
            bleService: Provider.of<BleService>(ctx, listen: false),
          ),
          update: (ctx, bleService, previousStream) =>
              previousStream ?? EspStreamService(bleService: bleService),
        ),
      ],
      child: MaterialApp(
        title: 'ESP32 iOS Navigator',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0D1117),
          primaryColor: const Color(0xFF00F0FF),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF00F0FF),
            secondary: Color(0xFF05FFA1),
            surface: Color(0xFF161B22),
          ),
          fontFamily: 'Roboto',
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
