import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service that automatically detects and listens to the actual currently playing song
/// and artist from the host iPhone (Spotify, Apple Music, YouTube Music, Zing MP3, etc.)
class PhoneMediaService extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('com.ysiduc.esp32_nav/media');

  String _songTitle = '';
  String _songArtist = '';
  bool _isPlaying = false;
  Timer? _pollTimer;

  String get songTitle => _songTitle;
  String get songArtist => _songArtist;
  bool get isPlaying => _isPlaying;
  bool get hasMedia => _songTitle.trim().isNotEmpty;

  // Callback to inform NavigationManager when real song changes
  void Function(String title, String artist, bool isPlaying)? onMediaChanged;

  PhoneMediaService() {
    _init();
  }

  void _init() {
    if (!kIsWeb && Platform.isIOS) {
      _channel.setMethodCallHandler(_handleNativeCall);
      // Poll every 2 seconds so song changes are immediately synced to ESP32
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        pollNowPlaying();
      });
      pollNowPlaying();
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onNowPlayingChanged') {
      final data = Map<String, dynamic>.from(call.arguments as Map);
      _updateMedia(
        (data['title'] as String?) ?? '',
        (data['artist'] as String?) ?? '',
        (data['isPlaying'] as bool?) ?? false,
      );
    }
  }

  Future<void> pollNowPlaying() async {
    if (kIsWeb || !Platform.isIOS) return;
    try {
      final result = await _channel.invokeMethod<dynamic>('getNowPlaying');
      if (result != null && result is Map) {
        final data = Map<String, dynamic>.from(result);
        _updateMedia(
          (data['title'] as String?) ?? '',
          (data['artist'] as String?) ?? '',
          (data['isPlaying'] as bool?) ?? false,
        );
      }
    } catch (_) {
      // Platform channel not available or simulator
    }
  }

  void _updateMedia(String title, String artist, bool isPlaying) {
    final cleanTitle = title.trim();
    final cleanArtist = artist.trim();

    if (_songTitle != cleanTitle || _songArtist != cleanArtist || _isPlaying != isPlaying) {
      _songTitle = cleanTitle;
      _songArtist = cleanArtist;
      _isPlaying = isPlaying;
      notifyListeners();
      onMediaChanged?.call(_songTitle, _songArtist, _isPlaying);
    }
  }

  /// Allow manual test injection from UI or simulation
  void setMockSong(String title, String artist) {
    _updateMedia(title, artist, true);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}
