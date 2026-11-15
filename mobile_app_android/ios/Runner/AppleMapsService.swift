import Foundation
import MapKit
import CoreLocation
import Flutter

/// Dịch vụ Apple Maps Native (MKLocalSearch và MKDirections) cho iOS
class AppleMapsService: NSObject, MKLocalSearchCompleterDelegate {
  static let shared = AppleMapsService()

  private var channel: FlutterMethodChannel?
  private var completer: MKLocalSearchCompleter?
  private var completerResultCallback: (([[String: Any]]) -> Void)?

  override init() {
    super.init()
    completer = MKLocalSearchCompleter()
    completer?.delegate = self
    if #available(iOS 13.0, *) {
      completer?.resultTypes = [.address, .pointOfInterest]
    }
  }

  func setup(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.ysiduc.esp32_nav/apple_maps",
      binaryMessenger: binaryMessenger
    )

    channel?.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }

      switch call.method {
      case "searchPlaces":
        guard let args = call.arguments as? [String: Any],
              let query = args["query"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing query", details: nil))
          return
        }
        let lat = args["lat"] as? Double
        let lng = args["lng"] as? Double
        self.searchPlaces(query: query, lat: lat, lng: lng, result: result)

      case "searchAutocomplete":
        guard let args = call.arguments as? [String: Any],
              let query = args["query"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing query", details: nil))
          return
        }
        let lat = args["lat"] as? Double
        let lng = args["lng"] as? Double
        self.searchAutocomplete(query: query, lat: lat, lng: lng, result: result)

      case "getRoute":
        guard let args = call.arguments as? [String: Any],
              let startLat = args["startLat"] as? Double,
              let startLng = args["startLng"] as? Double,
              let endLat = args["endLat"] as? Double,
              let endLng = args["endLng"] as? Double else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing coordinates", details: nil))
          return
        }
        let mode = args["mode"] as? String
        self.getRoute(
          startLat: startLat,
          startLng: startLng,
          endLat: endLat,
          endLng: endLng,
          mode: mode,
          result: result
        )

      case "reverseGeocodeStreet":
        guard let args = call.arguments as? [String: Any],
              let lat = args["lat"] as? Double,
              let lng = args["lng"] as? Double else {
          result(nil)
          return
        }
        self.reverseGeocodeStreet(lat: lat, lng: lng, result: result)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - 1. Tìm kiếm địa điểm bằng MKLocalSearch
  private func searchPlaces(
    query: String,
    lat: Double?,
    lng: Double?,
    result: @escaping FlutterResult
  ) {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    if #available(iOS 13.0, *) {
      request.resultTypes = [.address, .pointOfInterest]
    }

    if let lat = lat, let lng = lng, lat != 0, lng != 0 {
      let center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
      request.region = MKCoordinateRegion(
        center: center,
        latitudinalMeters: 25000,
        longitudinalMeters: 25000
      )
    }

    let search = MKLocalSearch(request: request)
    search.start { response, error in
      if let error = error {
        result(FlutterError(code: "SEARCH_ERROR", message: error.localizedDescription, details: nil))
        return
      }

      guard let response = response else {
        result([])
        return
      }

      var items: [[String: Any]] = []
      for mapItem in response.mapItems {
        let placemark = mapItem.placemark
        var subtitleParts: [String] = []

        if let subThoroughfare = placemark.subThoroughfare { subtitleParts.append(subThoroughfare) }
        if let thoroughfare = placemark.thoroughfare { subtitleParts.append(thoroughfare) }
        if let subLocality = placemark.subLocality { subtitleParts.append(subLocality) }
        if let locality = placemark.locality { subtitleParts.append(locality) }
        if let adminArea = placemark.administrativeArea { subtitleParts.append(adminArea) }

        let subtitle = subtitleParts.joined(separator: ", ")
        let name = mapItem.name ?? placemark.title ?? "Địa điểm"
        let displayName = subtitle.isEmpty ? (placemark.title ?? name) : "\(name), \(subtitle)"

        var category = ""
        if #available(iOS 13.0, *), let poiCategory = mapItem.pointOfInterestCategory {
          category = poiCategory.rawValue
        }

        let dict: [String: Any] = [
          "name": name,
          "displayName": displayName,
          "subtitle": subtitle.isEmpty ? (placemark.title ?? "") : subtitle,
          "lat": placemark.coordinate.latitude,
          "lng": placemark.coordinate.longitude,
          "phoneNumber": mapItem.phoneNumber ?? "",
          "category": category
        ]
        items.append(dict)
      }

      result(items)
    }
  }

  // MARK: - 2. Gợi ý từ khóa bằng MKLocalSearchCompleter
  private func searchAutocomplete(
    query: String,
    lat: Double?,
    lng: Double?,
    result: @escaping FlutterResult
  ) {
    if let lat = lat, let lng = lng, lat != 0, lng != 0 {
      let center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
      completer?.region = MKCoordinateRegion(
        center: center,
        latitudinalMeters: 50000,
        longitudinalMeters: 50000
      )
    }

    completerResultCallback = { suggestions in
      result(suggestions)
    }
    completer?.queryFragment = query
  }

  func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
    let suggestions = completer.results.map { res -> [String: Any] in
      return [
        "title": res.title,
        "subtitle": res.subtitle
      ]
    }
    completerResultCallback?(suggestions)
    completerResultCallback = nil
  }

  func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
    completerResultCallback?([])
    completerResultCallback = nil
  }

  // MARK: - 3. Tính toán lộ trình bằng MKDirections
  private func getRoute(
    startLat: Double,
    startLng: Double,
    endLat: Double,
    endLng: Double,
    mode: String?,
    result: @escaping FlutterResult
  ) {
    let sourceCoord = CLLocationCoordinate2D(latitude: startLat, longitude: startLng)
    let destCoord = CLLocationCoordinate2D(latitude: endLat, longitude: endLng)

    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(coordinate: sourceCoord))
    request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destCoord))
    request.transportType = (mode == "walking" || mode == "foot") ? .walking : .automobile
    request.requestsAlternateRoutes = true

    let directions = MKDirections(request: request)
    directions.calculate { response, error in
      if let error = error {
        result(FlutterError(code: "DIRECTIONS_ERROR", message: error.localizedDescription, details: nil))
        return
      }

      guard let response = response, !response.routes.isEmpty else {
        result(FlutterError(code: "NO_ROUTES", message: "Không tìm thấy lộ trình", details: nil))
        return
      }

      var routesData: [[String: Any]] = []

      for (index, route) in response.routes.enumerated() {
        // Tọa độ polyline
        let pointCount = route.polyline.pointCount
        var coords: [[Double]] = []
        var polylinePoints = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        route.polyline.getCoordinates(&polylinePoints, range: NSRange(location: 0, length: pointCount))

        for p in polylinePoints {
          coords.append([p.latitude, p.longitude])
        }

        // Encoded polyline string
        let encodedPolyline = PolylineEncoder.encode(polylinePoints)

        // Các bước điều hướng (Steps)
        // Lưu ý: Trong MapKit, mỗi MKRoute.Step dẫn tới điểm rẽ ở CUỐI polyline của step đó.
        // Step 0 thường là bước khởi hành 0m không có chỉ dẫn -> bỏ qua để tránh nhảy bước sớm.
        var stepsData: [[String: Any]] = []
        for step in route.steps {
          let cleanInstr = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
          if cleanInstr.isEmpty && step.distance < 5.0 {
            continue
          }

          let stepPtCount = step.polyline.pointCount
          var stepCoord = step.polyline.coordinate
          if stepPtCount > 0 {
            var stepPts = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: stepPtCount)
            step.polyline.getCoordinates(&stepPts, range: NSRange(location: 0, length: stepPtCount))
            // Điểm thực hiện thao tác rẽ nằm ở CUỐI đoạn đường của step
            if let lastPt = stepPts.last {
              stepCoord = lastPt
            }
          }

          let stepDict: [String: Any] = [
            "stepIndex": stepsData.count,
            "instruction": cleanInstr.isEmpty ? "Tiếp tục đi theo \(route.name)" : cleanInstr,
            "distance": step.distance,
            "notice": step.notice ?? "",
            "lat": stepCoord.latitude,
            "lng": stepCoord.longitude
          ]
          stepsData.append(stepDict)
        }

        let routeDict: [String: Any] = [
          "routeIndex": index,
          "name": route.name,
          "distance": route.distance, // mét
          "expectedTravelTime": route.expectedTravelTime, // giây
          "advisoryNotices": route.advisoryNotices,
          "coordinates": coords,
          "polyline": encodedPolyline,
          "steps": stepsData
        ]
        routesData.append(routeDict)
      }

      result([
        "routes": routesData
      ])
    }
  }

  // MARK: - 4. Định vị ngược tên con đường hiện tại bằng CLGeocoder
  private func reverseGeocodeStreet(lat: Double, lng: Double, result: @escaping FlutterResult) {
    let geocoder = CLGeocoder()
    let loc = CLLocation(latitude: lat, longitude: lng)
    geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "vi_VN")) { placemarks, _ in
      guard let p = placemarks?.first else {
        result(nil)
        return
      }
      let street = (p.thoroughfare?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
      if !street.isEmpty {
        result(street)
        return
      }
      let sub = (p.subLocality?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
      result(sub.isEmpty ? nil : sub)
    }
  }
}

// MARK: - Bộ mã hóa Google Encoded Polyline
struct PolylineEncoder {
  static func encode(_ coordinates: [CLLocationCoordinate2D]) -> String {
    var encoded = ""
    var prevLat: Int = 0
    var prevLng: Int = 0

    for coord in coordinates {
      let lat = Int(round(coord.latitude * 1e5))
      let lng = Int(round(coord.longitude * 1e5))

      let deltaLat = lat - prevLat
      let deltaLng = lng - prevLng

      prevLat = lat
      prevLng = lng

      encodeValue(deltaLat, into: &encoded)
      encodeValue(deltaLng, into: &encoded)
    }
    return encoded
  }

  private static func encodeValue(_ val: Int, into str: inout String) {
    var v = (val < 0) ? ~(val << 1) : (val << 1)
    while v >= 0x20 {
      if let scalar = UnicodeScalar((0x20 | (v & 0x1f)) + 63) {
        str.append(Character(scalar))
      }
      v >>= 5
    }
    if let scalar = UnicodeScalar(v + 63) {
      str.append(Character(scalar))
    }
  }
}

