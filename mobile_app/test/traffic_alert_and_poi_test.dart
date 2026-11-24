import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/services/navigation_alert_engine.dart';
import 'package:mobile_app/services/overpass_traffic_service.dart';

void main() {
  group('NHIỆM VỤ 1: OverpassTrafficService (BBox, Speed Limit Fallback & Parser)', () {
    test('computeExpandedBBox expands polyline bounding box by 500m on each side', () {
      final polyline = [
        const LatLng(21.0000, 105.8000),
        const LatLng(21.0100, 105.8200),
      ];
      final bbox = OverpassTrafficService.computeExpandedBBox(polyline, marginMeters: 500.0);
      const dist = Distance();

      // North & South edges must expand by ~500m (~490..510m)
      final northMargin = dist.as(LengthUnit.Meter, const LatLng(21.0100, 105.8100), LatLng(bbox.north, 105.8100));
      final southMargin = dist.as(LengthUnit.Meter, const LatLng(21.0000, 105.8100), LatLng(bbox.south, 105.8100));
      final eastMargin = dist.as(LengthUnit.Meter, const LatLng(21.0050, 105.8200), LatLng(21.0050, bbox.east));
      final westMargin = dist.as(LengthUnit.Meter, const LatLng(21.0050, 105.8000), LatLng(21.0050, bbox.west));

      expect(northMargin, closeTo(500.0, 15.0));
      expect(southMargin, closeTo(500.0, 15.0));
      expect(eastMargin, closeTo(500.0, 15.0));
      expect(westMargin, closeTo(500.0, 15.0));
    });

    test('resolveSpeedLimitKmh prefers explicit maxspeed and falls back by highway class', () {
      expect(
        OverpassTrafficService.resolveSpeedLimitKmh(maxspeedTag: '60', highwayTag: 'residential'),
        (speedLimitKmh: 60, hasExplicitMaxspeed: true),
      );
      expect(
        OverpassTrafficService.resolveSpeedLimitKmh(maxspeedTag: '80 km/h', highwayTag: 'primary'),
        (speedLimitKmh: 80, hasExplicitMaxspeed: true),
      );
      expect(
        OverpassTrafficService.resolveSpeedLimitKmh(highwayTag: 'motorway'),
        (speedLimitKmh: 100, hasExplicitMaxspeed: false),
      );
      expect(
        OverpassTrafficService.resolveSpeedLimitKmh(highwayTag: 'trunk'),
        (speedLimitKmh: 80, hasExplicitMaxspeed: false),
      );
      expect(
        OverpassTrafficService.resolveSpeedLimitKmh(highwayTag: 'primary'),
        (speedLimitKmh: 60, hasExplicitMaxspeed: false),
      );
      expect(
        OverpassTrafficService.resolveSpeedLimitKmh(highwayTag: 'secondary'),
        (speedLimitKmh: 60, hasExplicitMaxspeed: false),
      );
      expect(
        OverpassTrafficService.resolveSpeedLimitKmh(highwayTag: 'tertiary'),
        (speedLimitKmh: 50, hasExplicitMaxspeed: false),
      );
      expect(
        OverpassTrafficService.resolveSpeedLimitKmh(highwayTag: 'residential'),
        (speedLimitKmh: 50, hasExplicitMaxspeed: false),
      );
    });

    test('parseOverpassTrafficResponse extracts ways, cameras, signs, stop and railway crossings', () {
      final mockPayload = <String, dynamic>{
        'elements': [
          {
            'type': 'way',
            'id': 1001,
            'tags': {'highway': 'trunk', 'name': 'Vành Đai 3'},
            'geometry': [
              {'lat': 21.0000, 'lon': 105.8000},
              {'lat': 21.0050, 'lon': 105.8000},
            ],
          },
          {
            'type': 'way',
            'id': 1002,
            'tags': {'highway': 'primary', 'maxspeed': '70', 'name': 'Quốc Lộ 6'},
            'geometry': [
              {'lat': 21.0100, 'lon': 105.8100},
              {'lat': 21.0150, 'lon': 105.8100},
            ],
          },
          {
            'type': 'node',
            'id': 2001,
            'lat': 21.0020,
            'lon': 105.8000,
            'tags': {'highway': 'speed_camera', 'maxspeed': '80'},
          },
          {
            'type': 'node',
            'id': 2002,
            'lat': 21.0030,
            'lon': 105.8000,
            'tags': {'railway': 'level_crossing'},
          },
          {
            'type': 'node',
            'id': 2003,
            'lat': 21.0040,
            'lon': 105.8000,
            'tags': {'highway': 'stop'},
          },
          {
            'type': 'node',
            'id': 2004,
            'lat': 21.0045,
            'lon': 105.8000,
            'tags': {'traffic_sign': 'VN:P.127', 'maxspeed': '60'},
          },
        ],
      };

      final parsed = OverpassTrafficService.parseOverpassTrafficResponse(mockPayload);
      expect(parsed.segments, hasLength(2));
      expect(parsed.segments[0].speedLimitKmh, 80); // trunk fallback
      expect(parsed.segments[0].hasExplicitMaxspeed, isFalse);
      expect(parsed.segments[1].speedLimitKmh, 70); // explicit maxspeed
      expect(parsed.segments[1].hasExplicitMaxspeed, isTrue);

      expect(parsed.hazards, hasLength(4));
      expect(parsed.hazards[0].type, TrafficHazardType.speedCamera);
      expect(parsed.hazards[0].speedLimitKmh, 80);
      expect(parsed.hazards[1].type, TrafficHazardType.railwayCrossing);
      expect(parsed.hazards[2].type, TrafficHazardType.stopSign);
      expect(parsed.hazards[3].type, TrafficHazardType.trafficSign);
      expect(parsed.hazards[3].speedLimitKmh, 60);
    });
  });

  group('NHIỆM VỤ 2: Vietnam Camera JSON & 50m Deduplication', () {
    test('assets/data/cameras_vn.json is valid JSON and parses all cameras cleanly', () {
      final raw = File('assets/data/cameras_vn.json').readAsStringSync();
      final cams = OverpassTrafficService.parseVietnamCameraJson(raw);
      expect(cams.length, greaterThanOrEqualTo(20));
      expect(cams.every((c) => c.type == TrafficHazardType.speedCamera), isTrue);
      expect(cams.every((c) => (c.speedLimitKmh ?? 0) >= 50), isTrue);
    });

    test('mergeAndDeduplicateHazards removes duplicate cameras within 50m and keeps richer metadata', () {
      final localCam = TrafficHazardNode(
        id: 'cam_hn_01',
        coordinate: const LatLng(21.02850, 105.85420),
        type: TrafficHazardType.speedCamera,
        speedLimitKmh: 50,
        description: 'Camera phạt nguội khu vực Hồ Hoàn Kiếm',
        source: 'local_vn',
      );
      // Duplicate OSM node 22m away without speed limit
      final osmDuplicate = TrafficHazardNode(
        id: 'osm_999',
        coordinate: const LatLng(21.02870, 105.85420),
        type: TrafficHazardType.speedCamera,
        speedLimitKmh: null,
        description: 'Camera giám sát tốc độ',
        source: 'osm',
      );
      // Distinct OSM node 180m away (must be kept)
      final osmDistinct = TrafficHazardNode(
        id: 'osm_1000',
        coordinate: const LatLng(21.03010, 105.85420),
        type: TrafficHazardType.speedCamera,
        speedLimitKmh: 60,
        description: 'Camera OSM mới',
        source: 'osm',
      );

      final merged = OverpassTrafficService.mergeAndDeduplicateHazards(
        [
          [osmDuplicate, osmDistinct],
          [localCam],
        ],
        dedupeRadiusMeters: 50.0,
      );

      expect(merged, hasLength(2));
      expect(merged.first.id, 'cam_hn_01');
      expect(merged.first.speedLimitKmh, 50);
      expect(merged.last.id, 'osm_1000');
    });
  });

  group('NHIỆM VỤ 4: NavigationAlertEngine (Forward Cone, OverSpeed, Single TTS, ESP32 HUD)', () {
    test('evaluateForwardCone only triggers when target is < 300m ahead and bearing diff <= 30 deg', () {
      const origin = LatLng(21.0000, 105.8000);
      // 200m straight North (bearing 0°)
      const ahead200m = LatLng(21.0018, 105.8000);
      // 200m South (behind vehicle when heading North)
      const behind200m = LatLng(20.9982, 105.8000);
      // 200m East-Northeast (~60° off North -> outside 30° cone)
      const side200m = LatLng(21.0009, 105.8017);
      // 380m straight North (outside 300m range)
      const farNorth = LatLng(21.00345, 105.8000);

      expect(
        NavigationAlertEngine.evaluateForwardCone(
          vehiclePos: origin,
          vehicleHeadingDeg: 0.0,
          targetPos: ahead200m,
        ).inCone,
        isTrue,
      );
      expect(
        NavigationAlertEngine.evaluateForwardCone(
          vehiclePos: origin,
          vehicleHeadingDeg: 0.0,
          targetPos: behind200m,
        ).inCone,
        isFalse,
      );
      expect(
        NavigationAlertEngine.evaluateForwardCone(
          vehiclePos: origin,
          vehicleHeadingDeg: 0.0,
          targetPos: side200m,
        ).inCone,
        isFalse,
      );
      expect(
        NavigationAlertEngine.evaluateForwardCone(
          vehiclePos: origin,
          vehicleHeadingDeg: 0.0,
          targetPos: farNorth,
        ).inCone,
        isFalse,
      );
    });

    test('triggers single Vietnamese TTS alert per camera, detects overspeed >= 3 km/h, and updates ESP32 HUD payload', () {
      final spoken = <String>[];
      final engine = NavigationAlertEngine(
        fallbackSpeaker: spoken.add,
        enableTts: false,
      );

      final road = SpeedRoadSegment(
        wayId: 1,
        speedLimitKmh: 60,
        hasExplicitMaxspeed: true,
        highwayType: 'primary',
        roadName: 'Quang Trung',
        points: const [
          LatLng(21.0000, 105.8000),
          LatLng(21.0050, 105.8000),
        ],
      );
      final cam = TrafficHazardNode(
        id: 'cam_test_01',
        coordinate: const LatLng(21.0018, 105.8000), // ~200m North
        type: TrafficHazardType.speedCamera,
        speedLimitKmh: 60,
        description: 'Camera phạt nguội Quang Trung',
        source: 'local_vn',
      );

      engine.setTrafficDataForTest(RouteTrafficData(
        roadSegments: [road],
        hazards: [cam],
        fetchedAt: DateTime.now(),
      ));

      // Tick 1: 62.5 km/h (< 60 + 3) -> NOT overspeed yet, camera ~200m ahead -> announces once
      engine.updatePosition(
        location: const LatLng(21.0000, 105.8000),
        speedKmh: 62.5,
        headingDeg: 0.0,
      );
      expect(engine.currentSpeedLimitKmh, 60);
      expect(engine.isOverSpeed, isFalse);
      expect(engine.hasUpcomingCamera, isTrue);
      expect(spoken, hasLength(1));
      expect(spoken.first, contains('Phía trước 200 mét có camera giám sát'));
      expect(spoken.first, contains('60 ki-lô-mét trên giờ'));

      // Tick 2: move 30m closer at 63.0 km/h (== 60 + 3) -> isOverSpeed = true, camera NOT spoken twice
      engine.updatePosition(
        location: const LatLng(21.00027, 105.8000),
        speedKmh: 63.0,
        headingDeg: 0.0,
      );
      expect(engine.isOverSpeed, isTrue);
      // Camera alert was already spoken once; overspeed alert may speak once now
      expect(spoken.where((s) => s.contains('camera giám sát')).length, 1);

      final hud = engine.toEspHudPayload();
      expect(hud['speedLimit'], 60);
      expect(hud['isOverSpeed'], isTrue);
      expect(hud['hazardType'], 'speed_camera');
      expect(hud['hazardDistM'] as int, inInclusiveRange(160, 180));

      engine.dispose();
    });
  });
}
