import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Centralized coordinator for iOS background navigation & stream keep-alive (Sections 33 & 34)
class BackgroundNavigationCoordinator {
  static final BackgroundNavigationCoordinator instance = BackgroundNavigationCoordinator._();
  BackgroundNavigationCoordinator._();

  static const _channel = MethodChannel('com.ysiduc.esp32_nav/location');

  bool _isNavigating = false;
  bool _isEspStreamRequired = false;
  bool _isBackground = false;

  bool _isKeepAliveActive = false;
  bool get isKeepAliveActive => _isKeepAliveActive;

  void updateState({
    bool? isNavigating,
    bool? isEspStreamRequired,
    bool? isBackground,
  }) {
    if (isNavigating != null) _isNavigating = isNavigating;
    if (isEspStreamRequired != null) _isEspStreamRequired = isEspStreamRequired;
    if (isBackground != null) _isBackground = isBackground;

    _evaluate();
  }

  void _evaluate() {
    // Keep alive only when app is in background AND (actively navigating OR ESP stream is actively consumed)
    final bool shouldBeActive = _isBackground && (_isNavigating || _isEspStreamRequired);

    if (shouldBeActive && !_isKeepAliveActive) {
      _isKeepAliveActive = true;
      _invokeStart();
    } else if (!shouldBeActive && _isKeepAliveActive) {
      _isKeepAliveActive = false;
      _invokeStop();
    }
  }

  void _invokeStart() {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (Platform.isIOS) {
      try {
        _channel.invokeMethod('startBackgroundNavigation');
        debugPrint('[BackgroundNavigationCoordinator] Started background keep-alive session');
      } catch (e) {
        debugPrint('[BackgroundNavigationCoordinator] Failed to start keep-alive: $e');
      }
    }
  }

  void _invokeStop() {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (Platform.isIOS) {
      try {
        _channel.invokeMethod('stopBackgroundNavigation');
        debugPrint('[BackgroundNavigationCoordinator] Stopped background keep-alive session');
      } catch (e) {
        debugPrint('[BackgroundNavigationCoordinator] Failed to stop keep-alive: $e');
      }
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _isNavigating = false;
    _isEspStreamRequired = false;
    _isBackground = false;
    _isKeepAliveActive = false;
  }
}
