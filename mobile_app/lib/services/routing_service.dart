import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

abstract class RoutingService {
  Future<NavRoute?> calculateSingleRoute(
    LatLng start,
    LatLng destination, {
    String costing = 'motorcycle',
  });
}
