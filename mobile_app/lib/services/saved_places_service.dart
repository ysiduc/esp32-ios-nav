import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/route_model.dart';

/// Dịch vụ lưu trữ và quản lý Địa điểm đã lưu (Yêu thích / Nhà riêng / Công ty)
class SavedPlacesService extends ChangeNotifier {
  static const String _prefKey = 'ysiducnaga_saved_places_v1';

  static final SavedPlacesService _instance = SavedPlacesService._internal();
  factory SavedPlacesService() => _instance;

  SavedPlacesService._internal() {
    _loadFromPrefs();
  }

  final List<MapPlace> _savedPlaces = [];
  bool _isLoaded = false;

  List<MapPlace> get savedPlaces => List.unmodifiable(_savedPlaces);
  bool get isLoaded => _isLoaded;

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawList = prefs.getStringList(_prefKey) ?? [];
      _savedPlaces.clear();
      for (final itemStr in rawList) {
        try {
          final map = jsonDecode(itemStr) as Map<String, dynamic>;
          final lat = (map['lat'] as num?)?.toDouble() ?? 0.0;
          final lng = (map['lng'] as num?)?.toDouble() ?? 0.0;
          if (lat == 0.0 && lng == 0.0) continue;
          _savedPlaces.add(MapPlace(
            name: map['name'] as String? ?? 'Địa điểm đã lưu',
            displayName: map['displayName'] as String? ?? '',
            coordinate: LatLng(lat, lng),
            type: map['type'] as String? ?? 'saved',
            category: map['category'] as String? ?? 'Yêu thích',
            placeId: map['placeId'] as String?,
          ));
        } catch (_) {}
      }
      _isLoaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[SavedPlacesService] Lỗi tải địa điểm đã lưu: $e');
    }
  }

  Future<void> _saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _savedPlaces.map((p) {
        return jsonEncode({
          'name': p.name,
          'displayName': p.displayName,
          'lat': p.coordinate.latitude,
          'lng': p.coordinate.longitude,
          'type': p.type ?? 'saved',
          'category': p.category ?? 'Yêu thích',
          'placeId': p.placeId,
        });
      }).toList();
      await prefs.setStringList(_prefKey, encoded);
    } catch (e) {
      debugPrint('[SavedPlacesService] Lỗi lưu địa điểm: $e');
    }
  }

  bool isSaved(MapPlace place) {
    for (final s in _savedPlaces) {
      if (place.placeId != null &&
          place.placeId!.isNotEmpty &&
          s.placeId == place.placeId) {
        return true;
      }
      if (place.coordinate.latitude != 0 || place.coordinate.longitude != 0) {
        final dist = const Distance().as(
          LengthUnit.Meter,
          s.coordinate,
          place.coordinate,
        );
        if (dist <= 35.0) return true;
      }
      if (s.name.toLowerCase().trim() == place.name.toLowerCase().trim() &&
          s.displayName.toLowerCase().trim() == place.displayName.toLowerCase().trim()) {
        return true;
      }
    }
    return false;
  }

  Future<bool> toggleSaved(MapPlace place, {String? tag}) async {
    if (isSaved(place)) {
      await removePlace(place);
      return false;
    } else {
      await savePlace(place, tag: tag);
      return true;
    }
  }

  Future<void> savePlace(MapPlace place, {String? customName, String? tag}) async {
    await removePlace(place, notify: false);
    final saved = MapPlace(
      name: (customName != null && customName.trim().isNotEmpty) ? customName.trim() : place.name,
      displayName: place.displayName,
      coordinate: place.coordinate,
      type: 'saved',
      category: tag ?? place.category ?? 'Yêu thích',
      distanceMeters: place.distanceMeters,
      placeId: place.placeId,
    );
    _savedPlaces.insert(0, saved);
    notifyListeners();
    await _saveToPrefs();
  }

  Future<void> removePlace(MapPlace place, {bool notify = true}) async {
    _savedPlaces.removeWhere((s) {
      if (place.placeId != null &&
          place.placeId!.isNotEmpty &&
          s.placeId == place.placeId) {
        return true;
      }
      if (place.coordinate.latitude != 0 || place.coordinate.longitude != 0) {
        final dist = const Distance().as(LengthUnit.Meter, s.coordinate, place.coordinate);
        if (dist <= 35.0) return true;
      }
      return s.name.toLowerCase().trim() == place.name.toLowerCase().trim() &&
          s.displayName.toLowerCase().trim() == place.displayName.toLowerCase().trim();
    });
    if (notify) {
      notifyListeners();
    }
    await _saveToPrefs();
  }
}

/// Hiển thị bảng danh sách Địa điểm đã lưu chuẩn phong cách iOS
void showSavedPlacesSheet(
  BuildContext context, {
  required void Function(MapPlace place, {bool autoRoute}) onSelectPlace,
}) {
  final service = SavedPlacesService();
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      return DraggableScrollableSheet(
        initialChildSize: 0.62,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) {
          return AnimatedBuilder(
            animation: service,
            builder: (context, _) {
              final places = service.savedPlaces;
              return Container(
                decoration: const BoxDecoration(
                  color: Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 38,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
                      child: Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF9500).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.bookmark_rounded, color: Color(0xFFFF9500), size: 22),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Địa điểm đã lưu',
                                  style: TextStyle(
                                    color: Color(0xFF1C1C1E),
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  '${places.length} địa điểm yêu thích',
                                  style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(ctx),
                            icon: const Icon(Icons.close_rounded, color: Color(0xFF8E8E93)),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: places.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32.0),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 64,
                                      height: 64,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFF9500).withValues(alpha: 0.12),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.bookmark_border_rounded,
                                        size: 34,
                                        color: Color(0xFFFF9500),
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    const Text(
                                      'Chưa có địa điểm đã lưu',
                                      style: TextStyle(
                                        color: Color(0xFF1C1C1E),
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    const Text(
                                      'Tìm kiếm hoặc chạm vào một điểm trên bản đồ rồi bấm nút "Lưu địa điểm" để truy cập nhanh bất cứ lúc nào.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13, height: 1.4),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : ListView.separated(
                              controller: scrollController,
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                              itemCount: places.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final p = places[index];
                                final cat = (p.category ?? '').toLowerCase();
                                IconData leadingIcon = Icons.bookmark_rounded;
                                Color leadingColor = const Color(0xFFFF9500);
                                if (cat.contains('nhà')) {
                                  leadingIcon = Icons.home_rounded;
                                  leadingColor = const Color(0xFF007AFF);
                                } else if (cat.contains('công ty') || cat.contains('làm')) {
                                  leadingIcon = Icons.business_center_rounded;
                                  leadingColor = const Color(0xFF5856D6);
                                }

                                return Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.04),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                    leading: Container(
                                      width: 42,
                                      height: 42,
                                      decoration: BoxDecoration(
                                        color: leadingColor.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Icon(leadingIcon, color: leadingColor, size: 22),
                                    ),
                                    title: Text(
                                      p.name,
                                      style: const TextStyle(
                                        color: Color(0xFF1C1C1E),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      p.displayName,
                                      style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12.5),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        GestureDetector(
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            onSelectPlace(p, autoRoute: true);
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF007AFF),
                                              borderRadius: BorderRadius.circular(14),
                                            ),
                                            child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.directions_rounded, color: Colors.white, size: 15),
                                                SizedBox(width: 4),
                                                Text(
                                                  'Đi',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12.5,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        IconButton(
                                          tooltip: 'Xóa địa điểm đã lưu',
                                          icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFFF3B30), size: 20),
                                          onPressed: () => service.removePlace(p),
                                        ),
                                      ],
                                    ),
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      onSelectPlace(p, autoRoute: false);
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    },
  );
}

