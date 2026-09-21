//
//  SearchRanking.swift
//  Pure, stateless ranking helper for search predictions.
//
//  Ranking formula (higher is better):
//    score = exactNormalizedMainText   × 100
//          + prefixNormalizedMainText  ×  50
//          + tokenCoverage             ×  10   (per query token present in description)
//
//  Tie-break (ascending priority):
//    1. score DESC
//    2. original index ASC (stable)
//    3. prediction id ASC  (deterministic final tie-break)
//
//  Vietnamese normalization:
//    1. Diacritic folding via fixed Locale(identifier: "vi_VN") (deterministic)
//    2. Lowercase
//    3. Đ / đ → d
//    4. Punctuation / symbols → spaces
//    5. Collapse whitespace and trim
//

import Foundation

public enum SearchRanking {

    // MARK: - Public API

    /// Rank a list of predictions for  and return them sorted best-first.
    public static func rank(_ predictions: [SearchPrediction], query: String) -> [SearchPrediction] {
        guard !predictions.isEmpty else { return [] }
        let normalizedQuery = normalize(query)
        let queryTokens     = tokens(normalizedQuery)

        let scored: [(prediction: SearchPrediction, score: Double, index: Int)] = predictions.enumerated().map { idx, p in
            (p, score(for: p, normalizedQuery: normalizedQuery, queryTokens: queryTokens), idx)
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.index != rhs.index { return lhs.index < rhs.index }
            return lhs.prediction.id < rhs.prediction.id
        }.map(\.prediction)
    }

    // MARK: - Normalization

    /// Normalize a Vietnamese string: remove diacritics, lowercase, transliterate Đ/đ to d,
    /// convert basic punctuation to spaces, collapse whitespace, and trim.
    ///
    /// Independent of host device locale (uses fixed vi_VN locale for diacritic folding).
    ///
    /// Examples:
    ///   - "Đường Trần Hưng Đạo" → "duong tran hung dao"
    ///   - "Ba Đình"            → "ba dinh"
    ///   - "91-Trung Kính"       → "91 trung kinh"
    ///   - "Hồ Hoàn Kiếm, Hà Nội" → "ho hoan kiem ha noi"
    public static func normalize(_ text: String) -> String {
        let viLocale = Locale(identifier: "vi_VN")
        // 1. Fold diacritics and case with fixed vi_VN locale
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: viLocale)
            .lowercased()
            // 2. Explicit transliteration for Vietnamese Đ/đ (not folded by diacriticInsensitive in Foundation)
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "d")

        // 3. Convert basic punctuation and symbols to spaces
        var cleaned = ""
        cleaned.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            } else {
                cleaned.append(" ")
            }
        }

        // 4. Collapse runs of whitespace and trim
        let collapsed = cleaned.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    // MARK: - Private

    private static func tokens(_ normalized: String) -> [String] {
        normalized.components(separatedBy: " ").filter { !$0.isEmpty }
    }

    private static func score(
        for prediction: SearchPrediction,
        normalizedQuery: String,
        queryTokens: [String]
    ) -> Double {
        let normalizedMain = normalize(prediction.title)
        let normalizedDesc = normalize(prediction.description)

        var s: Double = 0

        // Exact title match
        if normalizedMain == normalizedQuery {
            s += 100
        } else if normalizedMain.hasPrefix(normalizedQuery) {
            // Prefix match
            s += 50
        }

        // Token coverage: count how many query tokens appear in full description
        let matchedTokens = queryTokens.filter { normalizedDesc.contains($0) }
        s += Double(matchedTokens.count) * 10

        return s
    }
}
