//
//  SearchRankingTests.swift
//  Unit tests for SearchRanking — Vietnamese normalization, exact/prefix ranking,
//  token coverage, deterministic tie-breaking.
//

import CoreLocation
import XCTest
@testable import ESP32NavApp

@MainActor
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

    func testNormalize_DaNang() {
        XCTAssertEqual(SearchRanking.normalize("Đà Nẵng"), "da nang")
    }

    func testNormalize_HoHoanKiem() {
        XCTAssertEqual(SearchRanking.normalize("Hồ Hoàn Kiếm"), "ho hoan kiem")
    }

    func testNormalize_PunctuationHyphen() {
        XCTAssertEqual(SearchRanking.normalize("91-Trung Kính"), "91 trung kinh")
    }

    func testNormalize_PunctuationComma() {
        XCTAssertEqual(SearchRanking.normalize("Hồ Hoàn Kiếm, Hà Nội"), "ho hoan kiem ha noi")
    }

    func testNormalize_LocaleDeterministic() {
        let input = "123-A Lê Lợi, P. 4, Q. 1, TP. Hồ Chí Minh"
        let expected = "123 a le loi p 4 q 1 tp ho chi minh"
        XCTAssertEqual(SearchRanking.normalize(input), expected)
    }

    // MARK: - Ranking Tests

    private func makePred(id: String, title: String, subtitle: String = "") -> SearchPrediction {
        SearchPrediction(id: id, title: title, subtitle: subtitle)
    }

    func testRank_ExactMatch_ScoresHigherThanPrefix() {
        let p1 = makePred(id: "1", title: "Hà Nội")
        let p2 = makePred(id: "2", title: "Hà Nội Tower")
        let ranked = SearchRanking.rank([p2, p1], query: "Hà Nội")

        XCTAssertEqual(ranked.first?.id, "1", "Exact title match must rank first")
    }

    func testRank_PrefixMatch_ScoresHigherThanTokenMatch() {
        let p1 = makePred(id: "1", title: "Hoàn Kiếm")
        let p2 = makePred(id: "2", title: "Quán Cà Phê Nhìn Ra Hồ Hoàn Kiếm")
        let ranked = SearchRanking.rank([p2, p1], query: "Hoàn")

        XCTAssertEqual(ranked.first?.id, "1", "Prefix match must rank higher than substring/token match")
    }

    func testRank_TokenCoverageBoostsRelevance() {
        let p1 = makePred(id: "1", title: "Hồ Hoàn Kiếm", subtitle: "Hà Nội")
        let p2 = makePred(id: "2", title: "Hồ Hoàn Kiếm", subtitle: "Việt Nam")
        let ranked = SearchRanking.rank([p2, p1], query: "Hồ Hoàn Kiếm Hà Nội")

        XCTAssertEqual(ranked.first?.id, "1", "Higher token coverage in description must rank higher")
    }

    func testRank_OriginalIndexTieBreak() {
        let p1 = makePred(id: "z", title: "Same Name")
        let p2 = makePred(id: "a", title: "Same Name")
        let ranked = SearchRanking.rank([p1, p2], query: "Same Name")

        XCTAssertEqual(ranked.first?.id, "z", "Earlier original index must be preserved on tie")
    }

    func testRank_EmptyInput_ReturnsEmpty() {
        let ranked = SearchRanking.rank([], query: "Hanoi")
        XCTAssertTrue(ranked.isEmpty)
    }

    func testRank_Deterministic() {
        let predictions = [
            makePred(id: "x", title: "Street A"),
            makePred(id: "y", title: "Street B")
        ]
        let ranked1 = SearchRanking.rank(predictions, query: "Street")
        let ranked2 = SearchRanking.rank(predictions, query: "Street")
        XCTAssertEqual(ranked1.map(\.id), ranked2.map(\.id), "SearchRanking must be deterministic")
    }
}
