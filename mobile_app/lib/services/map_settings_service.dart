import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/map_provider.dart';

/// Quản lý cấu hình nhà cung cấp Bản đồ & Dẫn đường (Apple Maps vs Goong API)
class MapSettingsService extends ChangeNotifier {
  static const String _prefProviderKey = 'esp32_nav_selected_map_provider';

  static final MapSettingsService _instance = MapSettingsService._internal();
  factory MapSettingsService() => _instance;
  MapSettingsService._internal() {
    _loadPreference();
  }

  MapProvider _currentProvider = MapProvider.appleMaps;
  bool _isLoaded = false;

  MapProvider get currentProvider => _currentProvider;
  bool get isLoaded => _isLoaded;
  bool get isAppleMaps => _currentProvider == MapProvider.appleMaps;
  bool get isGoong => _currentProvider == MapProvider.goong;

  Future<void> _loadPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString(_prefProviderKey);
      _currentProvider = MapProviderExtension.fromId(savedId);
      _isLoaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[MapSettingsService] Lỗi đọc cài đặt: $e');
    }
  }

  Future<void> setProvider(MapProvider provider) async {
    if (_currentProvider == provider) return;
    _currentProvider = provider;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefProviderKey, provider.id);
      debugPrint('[MapSettingsService] Đã lưu nhà cung cấp bản đồ: ${provider.displayName}');
    } catch (e) {
      debugPrint('[MapSettingsService] Lỗi lưu cài đặt: $e');
    }
  }
}
