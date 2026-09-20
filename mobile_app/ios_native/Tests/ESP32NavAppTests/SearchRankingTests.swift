//
//  SearchRankingTests.swift
//  Unit tests for SearchRanking — Vietnamese normalization, exact/prefix ranking,
//  provider tie-breaking, deduplication, determinism.
//

import XCTest
@testable import ESP32NavApp

final class SearchRankingTests: XCTestCase {

    // MARK: - Normalization

    func testNormalize_RemovesDiacritics() {
        XCTAssertEqual(SearchRanking.normalize("Đường Trần Hưng Đạo"),
                       "duong tran hung dao")
    }

    func testNormalize_LowercasesInput() {
        XCTAssertEqual(SearchRanking.normalize("HANOI"), "hanoi")
    }

    func testNormalize_CollapsesWhitespace() {
        XCTAssertEqual(SearchRanking.normalize("  Ba   Đình "), "ba dinh")
    }

    func testNormalize_MixedVietnamese() {
        XCTAssertEqual(SearchRanking.normalize("Hà Nội"), "ha noi")
    }

    // MARK: - Exact match gets highest score

    func testExactMainTextMatch_RanksFirst() {
        let predictions = [
            makePred(placeID: "b", mainText: "Hanoi Opera House",    providerIndex: 0),
            makePred(placeID: "a", mainText: "Ha Noi",              providerIndex: 1),
        ]
        let ranked = SearchRanking.rank(predictions, query: "Ha Noi")
        XCTAssertEqual(ranked.first?.placeID, "a",
                       "Exact normalized mainText match must rank first")
    }

    // MARK: - Prefix match

    func testPrefixMainTextMatch_RanksAboveTokenMatch() {
        let predictions = [
            makePred(placeID: "token", mainText: "Pho Hanoi noodle shop", description: "Ha Noi", providerIndex: 0),
            makePred(placeID: "prefix", mainText: "Ha Noi Hostel",        description: "",         providerIndex: 1),
        ]
        let ranked = SearchRanking.rank(predictions, query: "Ha Noi")
        // "Ha Noi Hostel" starts with "Ha Noi" → prefix match (+50)
        // "Pho Hanoi noodle shop" contains "Ha Noi" in description only (+10)
        XCTAssertEqual(ranked.first?.placeID, "prefix")
    }

    // MARK: - Token coverage

    func testTokenCoverage_MultiTokenQuery() {
        let predictions = [
            makePred(placeID: "single", mainText: "Ho", description: "Ho", providerIndex: 0),
            makePred(placeID: "double", mainText: "Ho Chi", description: "Ho Chi Minh City", providerIndex: 1),
        ]
        let ranked = SearchRanking.rank(predictions, query: "Ho Chi Minh")
        // "double" matches 3 tokens ("ho", "chi", "minh") → +30 score
        // "single" matches 1 token → +10 score
        XCTAssertEqual(ranked.first?.placeID, "double")
    }

    // MARK: - Provider score tie-break

    func testProviderScore_TieBreak() {
        let predictions = [
            makePred(placeID: "low",  mainText: "Same Place", providerScore: 1.0, providerIndex: 0),
            makePred(placeID: "high", mainText: "Same Place", providerScore: 5.0, providerIndex: 1),
        ]
        let ranked = SearchRanking.rank(predictions, query: "Same Place")
        // Both are exact matches (score + 100 each). Tie-break: providerScore DESC
        XCTAssertEqual(ranked.first?.placeID, "high",
                       "Higher providerScore should win tie-break")
    }

    // MARK: - Provider index tie-break (stable)

    func testProviderIndex_DeterministicTieBreak() {
        let predictions = [
            makePred(placeID: "z-id", mainText: "Place", providerScore: nil, providerIndex: 5),
            makePred(placeID: "a-id", mainText: "Place", providerScore: nil, providerIndex: 2),
        ]
        let ranked = SearchRanking.rank(predictions, query: "Place")
        XCTAssertEqual(ranked.first?.placeID, "a-id",
                       "Lower providerIndex should win when score and providerScore tied")
    }

    // MARK: - placeID lexicographic final tie-break

    func testPlaceIDLexicographic_FinalTieBreak() {
        let predictions = [
            makePred(placeID: "z", mainText: "Place", providerScore: nil, providerIndex: 0),
            makePred(placeID: "a", mainText: "Place", providerScore: nil, providerIndex: 0),
        ]
        let ranked = SearchRanking.rank(predictions, query: "Place")
        XCTAssertEqual(ranked.first?.placeID, "a",
                       "Lexicographically smaller placeID must win final tie-break")
    }

    // MARK: - Empty input

    func testEmptyInput_ReturnsEmpty() {
        let ranked = SearchRanking.rank([], query: "Hanoi")
        XCTAssertTrue(ranked.isEmpty)
    }

    // MARK: - Absent providerScore doesn't crash

    func testAbsentProviderScore_DoesNotCrash() {
        let predictions = [
            makePred(placeID: "np", mainText: "No Provider", providerScore: nil, providerIndex: 0),
        ]
        let ranked = SearchRanking.rank(predictions, query: "No Provider")
        XCTAssertEqual(ranked.count, 1)
    }

    // MARK: - Stable output

    func testSameInput_ProducesSameOutput() {
        let predictions = [
            makePred(placeID: "x", mainText: "Street A", providerScore: 2.0, providerIndex: 0),
            makePred(placeID: "y", mainText: "Street B", providerScore: 1.0, providerIndex: 1),
        ]
        let ranked1 = SearchRanking.rank(predictions, query: "Street")
        let ranked2 = SearchRanking.rank(predictions, query: "Street")
        XCTAssertEqual(ranked1.map(\.placeID), ranked2.map(\.placeID),
                       "SearchRanking must be deterministic")
    }

    // MARK: - Helpers

    private func makePred(
        placeID: String,
        mainText: String,
        secondaryText: String = "",
        description: String? = nil,
        providerScore: Double? = nil,
        providerIndex: Int = 0
    ) -> GoongRawPrediction {
        GoongRawPrediction(
            placeID:       placeID,
            mainText:      mainText,
            secondaryText: secondaryText,
            description:   description ?? mainText,
            providerScore: providerScore,
            providerIndex: providerIndex
        )
    }
}
