import 'dart:async';
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import 'google_maps_parser.dart';

enum GoogleLinkResolutionStatus {
  idle,
  resolving,
  success,
  failed,
  cancelled,
  timedOut,
}

class GoogleLinkResolutionState {
  final GoogleLinkResolutionStatus status;
  final String? statusText;
  final MapPlace? resolvedPlace;
  final GoogleMapsResolvedLink? resolvedLink;
  final String? errorMessage;
  final int generation;
  final bool requiresConfirmation;
  final String? debugDiagnostics;

  const GoogleLinkResolutionState({
    this.status = GoogleLinkResolutionStatus.idle,
    this.statusText,
    this.resolvedPlace,
    this.resolvedLink,
    this.errorMessage,
    this.generation = 0,
    this.requiresConfirmation = false,
    this.debugDiagnostics,
  });

  bool get isLoading => status == GoogleLinkResolutionStatus.resolving;
}

class GoogleLinkResolutionController {
  final GoogleMapsParser parser;
  final Duration timeoutBudget;

  GoogleLinkResolutionState _state = const GoogleLinkResolutionState();
  GoogleLinkResolutionState get state => _state;

  void Function(GoogleLinkResolutionState state)? onStateChanged;

  GoogleLinkResolutionController({
    required this.parser,
    this.timeoutBudget = const Duration(seconds: 5),
    this.onStateChanged,
  });

  void cancel() {
    final nextGen = _state.generation + 1;
    _updateState(GoogleLinkResolutionState(
      status: GoogleLinkResolutionStatus.cancelled,
      generation: nextGen,
    ));
  }

  Future<MapPlace?> resolve(String rawUrl, {LatLng? userLocation}) async {
    final clean = rawUrl.trim();
    if (clean.isEmpty) return null;

    final gen = _state.generation + 1;
    _updateState(GoogleLinkResolutionState(
      status: GoogleLinkResolutionStatus.resolving,
      statusText: 'Đang mở liên kết Google Maps…',
      generation: gen,
    ));

    try {
      final resolvedLink = await parser
          .parseResolvedLink(clean, userLocation: userLocation)
          .timeout(timeoutBudget);

      if (_state.generation != gen) {
        // Cancelled or superseded by newer generation
        return null;
      }

      final place = parser.buildMapPlaceFromResolved(resolvedLink);

      if (place != null) {
        _updateState(GoogleLinkResolutionState(
          status: GoogleLinkResolutionStatus.success,
          resolvedPlace: place,
          resolvedLink: resolvedLink,
          requiresConfirmation: resolvedLink.requiresConfirmation,
          debugDiagnostics: resolvedLink.debugDiagnostics,
          generation: gen,
        ));
        return place;
      } else {
        _updateState(GoogleLinkResolutionState(
          status: GoogleLinkResolutionStatus.failed,
          resolvedLink: resolvedLink,
          errorMessage: 'Không đọc được vị trí từ liên kết Google Maps',
          generation: gen,
        ));
        return null;
      }
    } on TimeoutException {
      if (_state.generation == gen) {
        _updateState(GoogleLinkResolutionState(
          status: GoogleLinkResolutionStatus.timedOut,
          errorMessage: 'Hết thời gian mở liên kết Google Maps',
          generation: gen,
        ));
      }
      return null;
    } catch (e) {
      if (_state.generation == gen) {
        _updateState(GoogleLinkResolutionState(
          status: GoogleLinkResolutionStatus.failed,
          errorMessage: 'Không đọc được vị trí từ liên kết Google Maps',
          generation: gen,
        ));
      }
      return null;
    } finally {
      // Invariant: No execution path can leave isLoading == true
      if (_state.generation == gen && _state.isLoading) {
        _updateState(GoogleLinkResolutionState(
          status: GoogleLinkResolutionStatus.failed,
          errorMessage: 'Không đọc được vị trí từ liên kết Google Maps',
          generation: gen,
        ));
      }
    }
  }

  void _updateState(GoogleLinkResolutionState newState) {
    _state = newState;
    onStateChanged?.call(newState);
  }
}
