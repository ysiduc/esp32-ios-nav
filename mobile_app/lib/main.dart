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
        ChangeNotifierProxyProvider<BleService, PhoneCallService>(
          create: (ctx) => PhoneCallService(Provider.of<BleService>(ctx, listen: false)),
          update: (ctx, bleService, previousCallService) =>
              previousCallService ?? PhoneCallService(bleService),
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
        title: 'ysiduc',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.light,
          scaffoldBackgroundColor: const Color(0xFFF2F2F7),
          primaryColor: const Color(0xFF007AFF),
          colorScheme: const ColorScheme.light(
            primary: Color(0xFF007AFF),
            secondary: Color(0xFF5E5CE6),
            surface: Color(0xFFFFFFFF),
          ),
          fontFamily: 'Roboto',
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
