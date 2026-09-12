import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/home_screen.dart';
import 'services/ble_service.dart';
import 'services/esp_stream_service.dart';
import 'services/navigation_manager.dart';
import 'services/phone_media_service.dart';
import 'services/phone_call_service.dart';

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
        ChangeNotifierProvider<PhoneMediaService>(
          create: (_) => PhoneMediaService(),
        ),
        // PhoneCallService cần BleService để gửi BLE
        ChangeNotifierProxyProvider<BleService, PhoneCallService>(
          create: (ctx) => PhoneCallService(
            bleService: Provider.of<BleService>(ctx, listen: false),
          ),
          update: (ctx, bleService, prev) =>
              prev ?? PhoneCallService(bleService: bleService),
        ),
        ChangeNotifierProxyProvider2<BleService, PhoneMediaService, NavigationManager>(
          create: (ctx) => NavigationManager(
            bleService: Provider.of<BleService>(ctx, listen: false),
            mediaService: Provider.of<PhoneMediaService>(ctx, listen: false),
          ),
          update: (ctx, bleService, mediaService, previousNavManager) {
            final nav = previousNavManager ??
                NavigationManager(bleService: bleService, mediaService: mediaService);
            nav.attachMediaService(mediaService);
            return nav;
          },
        ),
        ChangeNotifierProxyProvider2<BleService, NavigationManager, EspStreamService>(
          create: (ctx) => EspStreamService(
            bleService: Provider.of<BleService>(ctx, listen: false),
            navManager: Provider.of<NavigationManager>(ctx, listen: false),
          ),
          update: (ctx, bleService, navManager, previousStream) {
            final service = previousStream ??
                EspStreamService(bleService: bleService, navManager: navManager);
            service.updateReferences(bleService, navManager);
            return service;
          },
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
