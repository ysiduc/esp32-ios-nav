//
//  SearchRanking.swift
//  Pure, stateless ranking helper for Goong autocomplete results.
//
//  Ranking formula (higher is better):
//    score = exactNormalizedMainText   × 100
//          + prefixNormalizedMainText  ×  50
//          + tokenCoverage             ×  10   (per query token present in description)
//          + (providerScore ?? 0)      ×   0.1
//
//  Tie-break (ascending priority):
//    1. score DESC
//    2. providerScore DESC (Goong's own ranking signal)
//    3. providerIndex ASC  (original response position — stable)
//    4. placeID ASC        (deterministic final tie-break)
//
//  Vietnamese normalization:
//    String.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
//    followed by whitespace collapse.
//

import Foundation

public enum SearchRanking {

    // MARK: - Public API

    /// Rank a list of raw Goong predictions for `query` and return them sorted best-first.
    public static func rank(_ predictions: [GoongRawPrediction], query: String) -> [GoongRawPrediction] {
        guard !predictions.isEmpty else { return [] }
        let normalizedQuery = normalize(query)
        let queryTokens     = tokens(normalizedQuery)

        let scored: [(prediction: GoongRawPrediction, score: Double)] = predictions.map { p in
            (p, score(for: p, normalizedQuery: normalizedQuery, queryTokens: queryTokens))
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            // Tie-break 1: Goong's own provider score DESC
            let lScore = lhs.prediction.providerScore ?? 0
            let rScore = rhs.prediction.providerScore ?? 0
            if lScore != rScore { return lScore > rScore }
            // Tie-break 2: Original response position ASC
            if lhs.prediction.providerIndex != rhs.prediction.providerIndex {
                return lhs.prediction.providerIndex < rhs.prediction.providerIndex
            }
            // Tie-break 3: placeID lexicographic ASC (fully deterministic)
            return lhs.prediction.placeID < rhs.prediction.placeID
        }.map(\.prediction)
    }

    // MARK: - Normalization

    /// Normalize a Vietnamese string: remove diacritics, lowercase, collapse whitespace.
    ///
    /// Example: "Đường Trần Hưng Đạo" → "duong tran hung dao"
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        // Collapse runs of whitespace to a single space
        let collapsed = folded.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    // MARK: - Private

    private static func tokens(_ normalized: String) -> [String] {
        normalized.components(separatedBy: " ").filter { !$0.isEmpty }
    }

    private static func score(
        for prediction: GoongRawPrediction,
        normalizedQuery: String,
        queryTokens: [String]
    ) -> Double {
        let normalizedMain = normalize(prediction.mainText)
        let normalizedDesc = normalize(prediction.description)

        var s: Double = 0

        // Exact mainText match
        if normalizedMain == normalizedQuery {
            s += 100
        } else if normalizedMain.hasPrefix(normalizedQuery) {
            // Prefix match
            s += 50
        }

        // Token coverage: count how many query tokens appear in full description
        let matchedTokens = queryTokens.filter { normalizedDesc.contains($0) }
        s += Double(matchedTokens.count) * 10

        // Goong provider score signal
        s += (prediction.providerScore ?? 0) * 0.1

        return s
    }
}
