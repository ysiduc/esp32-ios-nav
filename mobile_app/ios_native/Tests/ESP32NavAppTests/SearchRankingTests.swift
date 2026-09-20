//
//  SearchRankingTests.swift
//  Unit tests for SearchRanking — Vietnamese normalization, exact/prefix ranking,
//  provider tie-breaking, response parser (score, compound, status), request builder, determinism.
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
        XCTAssertEqual(ranked.first?.placeID, "prefix")
    }

    // MARK: - Token coverage

    func testTokenCoverage_MultiTokenQuery() {
        let predictions = [
            makePred(placeID: "single", mainText: "Ho", description: "Ho", providerIndex: 0),
            makePred(placeID: "double", mainText: "Ho Chi", description: "Ho Chi Minh City", providerIndex: 1),
        ]
        let ranked = SearchRanking.rank(predictions, query: "Ho Chi Minh")
        XCTAssertEqual(ranked.first?.placeID, "double")
    }

    // MARK: - Provider score tie-break

    func testProviderScore_TieBreak() {
        let predictions = [
            makePred(placeID: "low",  mainText: "Same Place", providerScore: 1.0, providerIndex: 0),
            makePred(placeID: "high", mainText: "Same Place", providerScore: 5.0, providerIndex: 1),
        ]
        let ranked = SearchRanking.rank(predictions, query: "Same Place")
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

    // MARK: - Response Parser: Score & Compound fields

    func testParser_GoongScoreField() throws {
        let json = """
        {
          "status": "OK",
          "predictions": [
            {
              "description": "91 Trung Kính, Yên Hòa, Cầu Giấy, Hà Nội",
              "place_id": "id-1",
              "structured_formatting": {
                "main_text": "91 Trung Kính",
                "secondary_text": "Yên Hòa, Cầu Giấy, Hà Nội"
              },
              "score": 633.7587
            }
          ]
        }
        """.data(using: .utf8)!

        let predictions = try GoongPlacesHTTPClient.parseAutocompleteResponse(json)
        XCTAssertEqual(predictions.count, 1)
        XCTAssertEqual(predictions.first?.placeID, "id-1")
        XCTAssertEqual(predictions.first?.mainText, "91 Trung Kính")
        XCTAssertEqual(predictions.first?.providerScore, 633.7587)
    }

    func testParser_LegacyProviderRankingFallback() throws {
        let json = """
        {
          "status": "OK",
          "predictions": [
            {
              "description": "Old Format Place",
              "place_id": "id-old",
              "structured_formatting": {
                "main_text": "Old Format Place",
                "secondary_text": ""
              },
              "provider_ranking": 42.5
            }
          ]
        }
        """.data(using: .utf8)!

        let predictions = try GoongPlacesHTTPClient.parseAutocompleteResponse(json)
        XCTAssertEqual(predictions.count, 1)
        XCTAssertEqual(predictions.first?.providerScore, 42.5)
    }

    func testParser_MissingScoreField_DoesNotReject() throws {
        let json = """
        {
          "status": "OK",
          "predictions": [
            {
              "description": "Place without score",
              "place_id": "id-no-score",
              "structured_formatting": {
                "main_text": "No Score Place",
                "secondary_text": ""
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let predictions = try GoongPlacesHTTPClient.parseAutocompleteResponse(json)
        XCTAssertEqual(predictions.count, 1)
        XCTAssertNil(predictions.first?.providerScore)
    }

    func testParser_CompoundFields() throws {
        let json = """
        {
          "status": "OK",
          "predictions": [
            {
              "description": "91 Trung Kính, Yên Hòa, Cầu Giấy, Hà Nội",
              "place_id": "id-compound",
              "structured_formatting": {
                "main_text": "91 Trung Kính",
                "secondary_text": "Yên Hòa, Cầu Giấy, Hà Nội"
              },
              "compound": {
                "district": "Cầu Giấy",
                "commune": "Yên Hòa",
                "province": "Hà Nội"
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let predictions = try GoongPlacesHTTPClient.parseAutocompleteResponse(json)
        XCTAssertEqual(predictions.count, 1)
        XCTAssertEqual(predictions.first?.district, "Cầu Giấy")
        XCTAssertEqual(predictions.first?.commune, "Yên Hòa")
        XCTAssertEqual(predictions.first?.province, "Hà Nội")
    }

    func testParser_MissingCompound_DoesNotReject() throws {
        let json = """
        {
          "status": "OK",
          "predictions": [
            {
              "description": "Place without compound",
              "place_id": "id-no-compound",
              "structured_formatting": {
                "main_text": "No Compound Place",
                "secondary_text": ""
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let predictions = try GoongPlacesHTTPClient.parseAutocompleteResponse(json)
        XCTAssertEqual(predictions.count, 1)
        XCTAssertNil(predictions.first?.district)
        XCTAssertNil(predictions.first?.commune)
        XCTAssertNil(predictions.first?.province)
    }

    // MARK: - Status Validation

    func testParser_StatusOk_EmptyPredictions_ReturnsEmpty() throws {
        let json = """
        {
          "status": "OK",
          "predictions": []
        }
        """.data(using: .utf8)!

        let predictions = try GoongPlacesHTTPClient.parseAutocompleteResponse(json)
        XCTAssertTrue(predictions.isEmpty)
    }

    func testParser_StatusZeroResults_ReturnsEmpty() throws {
        let json = """
        {
          "status": "ZERO_RESULTS",
          "predictions": []
        }
        """.data(using: .utf8)!

        let predictions = try GoongPlacesHTTPClient.parseAutocompleteResponse(json)
        XCTAssertTrue(predictions.isEmpty)
    }

    func testParser_StatusNonSuccess_ThrowsApiStatus() throws {
        let json = """
        {
          "status": "REQUEST_DENIED",
          "error_message": "The provided API key is invalid."
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try GoongPlacesHTTPClient.parseAutocompleteResponse(json)) { error in
            guard case GoongSearchError.apiStatus(let status) = error else {
                XCTFail("Expected GoongSearchError.apiStatus, got \(error)")
                return
            }
            XCTAssertEqual(status, "REQUEST_DENIED")
        }
    }

    func testParser_InvalidJSON_ThrowsDecodingError() {
        let invalidData = "not a json string".data(using: .utf8)!
        XCTAssertThrowsError(try GoongPlacesHTTPClient.parseAutocompleteResponse(invalidData)) { error in
            guard case GoongSearchError.decodingError = error else {
                XCTFail("Expected GoongSearchError.decodingError, got \(error)")
                return
            }
        }
    }

    // MARK: - Request Builder Tests

    func testRequestBuilder_ContainsAllRequiredParameters() {
        let loc = CLLocationCoordinate2D(latitude: 21.028511, longitude: 105.804817)
        let url = GoongRequestBuilder.buildAutocompleteURL(
            apiKey: "test-key-xyz",
            query: "91 Trung Kính",
            location: loc,
            radius: 2000,
            limit: 10,
            sessionToken: "session-uuid-123"
        )

        XCTAssertNotNil(url)
        let urlString = url?.absoluteString ?? ""
        XCTAssertTrue(urlString.contains("rsapi.goong.io/Place/AutoComplete"))
        XCTAssertTrue(urlString.contains("api_key=test-key-xyz"))
        XCTAssertTrue(urlString.contains("sessiontoken=session-uuid-123"))
        XCTAssertTrue(urlString.contains("radius=2000"))
        XCTAssertTrue(urlString.contains("limit=10"))
        XCTAssertTrue(urlString.contains("more_compound=true"))
        XCTAssertTrue(urlString.contains("location=21.028511,105.804817"))
    }

    func testRequestBuilder_NoLocationWhenNil() {
        let url = GoongRequestBuilder.buildAutocompleteURL(
            apiKey: "test-key-xyz",
            query: "Test No Location",
            location: nil,
            radius: 2000,
            limit: 10,
            sessionToken: "session-uuid-123"
        )

        XCTAssertNotNil(url)
        let urlString = url?.absoluteString ?? ""
        XCTAssertFalse(urlString.contains("location="))
    }

    // MARK: - Integration: Decoded Score Influences Ranking

    func testDecodedScoreFromJSON_InfluencesRanking() throws {
        let json = """
        {
          "status": "OK",
          "predictions": [
            {
              "description": "Phở Gia Truyền, Quán A",
              "place_id": "pho-a",
              "structured_formatting": {
                "main_text": "Phở Gia Truyền",
                "secondary_text": "Quán A"
              },
              "score": 500.0
            },
            {
              "description": "Phở Gia Truyền, Quán B",
              "place_id": "pho-b",
              "structured_formatting": {
                "main_text": "Phở Gia Truyền",
                "secondary_text": "Quán B"
              },
              "score": 900.0
            }
          ]
        }
        """.data(using: .utf8)!

        let rawPredictions = try GoongPlacesHTTPClient.parseAutocompleteResponse(json)
        let ranked = SearchRanking.rank(rawPredictions, query: "Phở Gia Truyền")

        XCTAssertEqual(ranked.first?.placeID, "pho-b",
                       "Higher decoded provider score must rank first when text scores are identical")
    }

    // MARK: - Deduplication Order

    func testDeduplication_AfterRanking_RetainsBestRanked() {
        let raw = [
            makePred(placeID: "dup-id", mainText: "Lower Ranked Match", providerScore: 10.0, providerIndex: 0),
            makePred(placeID: "dup-id", mainText: "Exact Match",       providerScore: 100.0, providerIndex: 1),
        ]
        let ranked = SearchRanking.rank(raw, query: "Exact Match")
        var seen = Set<String>()
        let deduped = ranked.filter { seen.insert($0.placeID).inserted }

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.mainText, "Exact Match",
                       "Deduplication after ranking must retain the best-ranked prediction")
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
