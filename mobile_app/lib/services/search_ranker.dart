import 'dart:math';
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import '../models/search_query_intent.dart';

class SearchScoreBreakdown {
  final double titleMatch;
  final double addressMatch;
  final double precisionScore;
  final double providerConfidence;
  final double distanceScore;
  final double finalScore;
  final String debugReason;

  const SearchScoreBreakdown({
    required this.titleMatch,
    required this.addressMatch,
    required this.precisionScore,
    required this.providerConfidence,
    required this.distanceScore,
    required this.finalScore,
    required this.debugReason,
  });

  Map<String, dynamic> toMap() => {
    'titleMatch': titleMatch,
    'addressMatch': addressMatch,
    'precisionScore': precisionScore,
    'providerConfidence': providerConfidence,
    'distanceScore': distanceScore,
    'finalScore': finalScore,
    'debugReason': debugReason,
  };

  @override
  String toString() =>
      'Score(total: ${finalScore.toStringAsFixed(1)}, title: ${titleMatch.toStringAsFixed(1)}, addr: ${addressMatch.toStringAsFixed(1)}, prec: ${precisionScore.toStringAsFixed(1)}, prov: ${providerConfidence.toStringAsFixed(1)}, dist: ${distanceScore.toStringAsFixed(1)}, reason: $debugReason)';
}

class SearchRanker {
  /// Vietnamese diacritics removal table
  static const Map<String, String> _vietnameseMap = {
    'à': 'a', 'á': 'a', 'ả': 'a', 'ã': 'a', 'ạ': 'a',
    'ă': 'a', 'ằ': 'a', 'ắ': 'a', 'ẳ': 'a', 'ẵ': 'a', 'ặ': 'a',
    'â': 'a', 'ầ': 'a', 'ấ': 'a', 'ẩ': 'a', 'ẫ': 'a', 'ậ': 'a',
    'è': 'e', 'é': 'e', 'ẻ': 'e', 'ẽ': 'e', 'ẹ': 'e',
    'ê': 'e', 'ề': 'e', 'ế': 'e', 'ể': 'e', 'ễ': 'e', 'ệ': 'e',
    'ì': 'i', 'í': 'i', 'ỉ': 'i', 'ĩ': 'i', 'ị': 'i',
    'ò': 'o', 'ó': 'o', 'ỏ': 'o', 'õ': 'o', 'ọ': 'o',
    'ô': 'o', 'ồ': 'o', 'ố': 'o', 'ổ': 'o', 'ỗ': 'o', 'ộ': 'o',
    'ơ': 'o', 'ờ': 'o', 'ớ': 'o', 'ở': 'o', 'ỡ': 'o', 'ợ': 'o',
    'ù': 'u', 'ú': 'u', 'ủ': 'u', 'ũ': 'u', 'ụ': 'u',
    'ư': 'u', 'ừ': 'u', 'ứ': 'u', 'ử': 'u', 'ữ': 'u', 'ự': 'u',
    'ỳ': 'y', 'ý': 'y', 'ỷ': 'y', 'ỹ': 'y', 'ỵ': 'y',
    'đ': 'd',
  };

  /// Strip diacritics and convert to ASCII-compatible lowercase
  static String stripDiacritics(String str) {
    var result = str.toLowerCase();
    _vietnameseMap.forEach((key, value) {
      result = result.replaceAll(key, value);
    });
    return result;
  }

  /// Robust token normalization (Section 12)
  /// Normalizes administrative and street prefixes while preserving meaningful names
  static String normalize(String text) {
    var s = stripDiacritics(text);

        // Normalize common abbreviations
    s = s.replaceAll(RegExp(r'\b(?:bv|b\.v\.)\b'), 'benh vien');
    s = s.replaceAll(RegExp(r'\b(?:dh|đh|d\.h\.|đ\.h\.)\b'), 'dai hoc');
    s = s.replaceAll(RegExp(r'\b(?:bx|b\.x\.)\b'), 'ben xe');
    s = s.replaceAll(RegExp(r'\b(?:tttm)\b'), 'trung tam thuong mai');

    // Normalize common street prefixes
    s = s.replaceAll(RegExp(r'\b(?:phố|pho|đường|duong|đ\.|d\.)\b'), 'duong');
    // Normalize administrative prefixes
    s = s.replaceAll(RegExp(r'\b(?:quận|quan|q\.)\b'), 'quan');
    s = s.replaceAll(RegExp(r'\b(?:huyện|huyen|h\.)\b'), 'huyen');
    s = s.replaceAll(RegExp(r'\b(?:thành phố|thanh pho|tp\.|tp)\b'), 'tp');
    s = s.replaceAll(RegExp(r'\b(?:phường|phuong|p\.)\b'), 'phuong');
    s = s.replaceAll(RegExp(r'\b(?:xã|xa)\b'), 'xa');
    s = s.replaceAll(RegExp(r'\b(?:ngõ|ngo)\b'), 'ngo');
    s = s.replaceAll(RegExp(r'\b(?:ngách|ngach)\b'), 'ngach');
    s = s.replaceAll(RegExp(r'\b(?:hẻm|hem)\b'), 'hem');
    s = s.replaceAll(RegExp(r'\b(?:số|so)\b'), 'so');

    // Remove punctuation
    s = s.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    // Collapse whitespace
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  /// Compute Levenshtein edit distance between two strings
  static int levenshtein(String s1, String s2) {
    if (s1 == s2) return 0;
    if (s1.isEmpty) return s2.length;
    if (s2.isEmpty) return s1.length;

    List<int> v0 = List<int>.generate(s2.length + 1, (i) => i);
    List<int> v1 = List<int>.filled(s2.length + 1, 0);

    for (int i = 0; i < s1.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < s2.length; j++) {
        int cost = (s1[i] == s2[j]) ? 0 : 1;
        v1[j + 1] = min(v1[j] + 1, min(v0[j + 1] + 1, v0[j] + cost));
      }
      for (int j = 0; j <= s2.length; j++) {
        v0[j] = v1[j];
      }
    }
    return v1[s2.length];
  }

  /// Bounded fuzzy match between two tokens (Section 13)
  /// - Only fuzzies words of length >= 4
  /// - Distance <= 1 (or <= 2 for words >= 7 chars)
  /// - Or prefix match if length >= 4
  static bool fuzzyTokenMatch(String queryToken, String candidateToken) {
    if (queryToken == candidateToken) return true;

    // Allow 1-character typo if tokens are >= 3 characters (e.g. maii vs mai, traii vs trai, khoaa vs khoa)
    if (queryToken.length >= 3 && candidateToken.length >= 3) {
      if (levenshtein(queryToken, candidateToken) <= 1) return true;
    }

    if (queryToken.length < 4 || candidateToken.length < 4) {
      return false;
    }

    // Prefix match
    if (queryToken.length >= 4 && candidateToken.startsWith(queryToken)) return true;
    if (candidateToken.length >= 4 && queryToken.startsWith(candidateToken)) return true;

    final maxDist = (queryToken.length >= 7 || candidateToken.length >= 7) ? 2 : 1;
    return levenshtein(queryToken, candidateToken) <= maxDist;
  }

  /// Score how well candidate text matches query text using token overlap & bounded fuzzy matching
  static double computeTextMatchScore(String query, String text) {
    final normQuery = normalize(query);
    final normText = normalize(text);
    if (normQuery.isEmpty || normText.isEmpty) return 0.0;

    // Exact string match
    if (normText == normQuery) return 100.0;

    // Prefix match
    if (normText.startsWith(normQuery)) return 90.0;

    // Substring match
    if (normText.contains(normQuery)) return 80.0;

    final queryTokens = normQuery.split(' ').where((t) => t.isNotEmpty).toList();
    final textTokens = normText.split(' ').where((t) => t.isNotEmpty).toList();
    if (queryTokens.isEmpty || textTokens.isEmpty) return 0.0;

    int matchedTokens = 0;
    for (final qTok in queryTokens) {
      bool found = false;
      for (final tTok in textTokens) {
        if (fuzzyTokenMatch(qTok, tTok)) {
          found = true;
          break;
        }
      }
      if (found) matchedTokens++;
    }

    final ratio = matchedTokens / queryTokens.length;
    // Score up to 75 points for token overlap
    return ratio * 75.0;
  }

  /// Pure ranking function (Section 44 & 45)
  static SearchScoreBreakdown rank({
    required SearchQueryIntent intent,
    required String candidateTitle,
    required String candidateAddress,
    required PlacePrecision precision,
    required String source,
    double? distanceMeters,
  }) {
    double titleScore = 0.0;
    double addressScore = 0.0;
    double precisionScore = 0.0;
    double providerScore = 0.0;
    double distScore = 0.0;
    final reasons = <String>[];

    // normQuery used via intent.rawQuery in computeTextMatchScore
    final normTitle = normalize(candidateTitle);
    final normAddr = normalize(candidateAddress);

    // 1. Text / Identity Matching (Section 14: Text relevance FIRST)
    titleScore = computeTextMatchScore(intent.rawQuery, candidateTitle);
    addressScore = computeTextMatchScore(intent.rawQuery, candidateAddress);

    if (titleScore >= 95.0) {
      reasons.add('exact_title');
    } else if (titleScore >= 75.0) {
      reasons.add('high_title_match');
    }

    // 2. House Address Intent & Evidence Check (Section 11)
    if (intent.type == SearchQueryIntentType.houseAddress && intent.houseNumber != null) {
      final targetNum = normalize(intent.houseNumber!);
      final candidateContainsNum = normTitle.contains(targetNum) || normAddr.contains(targetNum);

      bool streetMatches = false;
      if (intent.streetName != null) {
        final targetStreet = normalize(intent.streetName!);
        streetMatches = normTitle.contains(targetStreet) || normAddr.contains(targetStreet);
      }

      if (candidateContainsNum && streetMatches) {
        // High confidence exact house evidence
        titleScore += 50.0;
        precisionScore += 30.0;
        reasons.add('exact_house_evidence');
      } else if (candidateContainsNum) {
        titleScore += 20.0;
        reasons.add('house_number_match');
      } else if (streetMatches) {
        // Only street matched! DO NOT invent house. Demote relative to exact house
        precisionScore += 10.0;
        reasons.add('street_match_no_house');
      } else {
        // Weak or unrelated candidate
        titleScore = max(0.0, titleScore - 20.0);
        reasons.add('no_house_or_street');
      }
    }

    // 3. Precision Bonus
    switch (precision) {
      case PlacePrecision.exactAddress:
        precisionScore += 25.0;
        break;
      case PlacePrecision.poi:
      case PlacePrecision.building:
        precisionScore += 20.0;
        break;
      case PlacePrecision.street:
        precisionScore += 10.0;
        break;
      case PlacePrecision.neighborhood:
      case PlacePrecision.district:
        precisionScore += 5.0;
        break;
      case PlacePrecision.city:
        precisionScore += 3.0;
        break;
      case PlacePrecision.coordinate:
        precisionScore += (intent.type == SearchQueryIntentType.coordinate) ? 50.0 : 10.0;
        break;
      case PlacePrecision.approximate:
        precisionScore += 0.0;
        break;
    }

    // 4. Provider Confidence
    switch (source.toLowerCase()) {
      case 'apple_mapkit':
      case 'mapkit':
        providerScore = 30.0;
        break;
      case 'google_link_exact':
        providerScore = 35.0;
        break;
      case 'maptiler':
        providerScore = 20.0;
        break;
      case 'photon':
        providerScore = 15.0;
        break;
      case 'local':
        // Offline fallback landmark (Section 16: offline fallback only, never outrank live high-confidence)
        providerScore = 10.0;
        break;
      case 'nominatim':
        providerScore = 8.0;
        break;
      default:
        providerScore = 5.0;
    }

    // 5. Distance Score (Sections 14 & 15: Moderate tie-breaker, max 15 pts, decaying smoothly over 150km)
    // Must NOT dominate text relevance. Cross-city exact search (e.g. Sân bay Cát Bi) stays on top.
    if (distanceMeters != null && distanceMeters >= 0) {
      final km = distanceMeters / 1000.0;
      if (km < 2.0) {
        distScore = 15.0;
      } else if (km < 10.0) {
        distScore = 12.0;
      } else if (km < 30.0) {
        distScore = 8.0;
      } else if (km < 100.0) {
        distScore = 4.0;
      } else {
        distScore = 1.0;
      }
    }

    final finalScore = titleScore * 1.0 +
        addressScore * 0.4 +
        precisionScore +
        providerScore +
        distScore;

    return SearchScoreBreakdown(
      titleMatch: titleScore,
      addressMatch: addressScore,
      precisionScore: precisionScore,
      providerConfidence: providerScore,
      distanceScore: distScore,
      finalScore: finalScore,
      debugReason: reasons.join(','),
    );
  }

  /// Deduplicate candidates within 30m with matching normalized titles (Section 17)
  static List<MapPlace> deduplicate(List<MapPlace> places, {double maxDistanceMeters = 30.0}) {
    if (places.length <= 1) return places;

    const distCalc = Distance();
    final result = <MapPlace>[];

    for (final candidate in places) {
      bool isDup = false;
      for (int i = 0; i < result.length; i++) {
        final existing = result[i];
        final d = distCalc.as(LengthUnit.Meter, candidate.coordinate, existing.coordinate);
        if (d <= maxDistanceMeters) {
          final normCand = normalize(candidate.name);
          final normExist = normalize(existing.name);
          if (normCand == normExist ||
              normCand.contains(normExist) ||
              normExist.contains(normCand)) {
            isDup = true;
            // Keep the one with higher precision or better provider
            if (candidate.precision.index < existing.precision.index) {
              result[i] = candidate;
            }
            break;
          }
        }
      }
      if (!isDup) {
        result.add(candidate);
      }
    }
    return result;
  }
}
