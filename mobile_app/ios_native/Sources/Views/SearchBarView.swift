//
//  SearchBarView.swift
//  Standalone search bar component — uses GoongSearchService autocomplete.
//  Integrated directly into MainMapView; this file kept for modularity.
//

import SwiftUI

/// Standalone search bar connected to GoongSearchService.
/// Embed in a ZStack or VStack to overlay on top of the map.
public struct SearchBarView: View {

    @ObservedObject var searchService: GoongSearchService
    var onSelectPrediction: (GoongPrediction) -> Void
    var onCancel: () -> Void

    @State private var query: String = ""
    @FocusState private var isFocused: Bool

    public var body: some View {
        VStack(spacing: 8) {
            // Input row
            HStack(spacing: 10) {
                Image(systemName: isFocused ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(isFocused ? Color(red: 0, green: 0.75, blue: 1.0) : .gray)
                    .animation(.easeInOut(duration: 0.2), value: isFocused)

                TextField("Tìm kiếm địa điểm tại Việt Nam…", text: $query)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .tint(Color(red: 0, green: 0.75, blue: 1.0))
                    .focused($isFocused)
                    .onChange(of: query) { newVal in
                        searchService.search(newVal)
                    }

                if !query.isEmpty {
                    Button(action: {
                        query = ""
                        searchService.clear()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }

                if searchService.isLoading {
                    ProgressView().scaleEffect(0.75).tint(.cyan)
                }

                Button("Huỷ") { onCancel() }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(red: 0, green: 0.75, blue: 1.0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.12, green: 0.16, blue: 0.22).opacity(0.97))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                isFocused
                                    ? Color(red: 0, green: 0.75, blue: 1.0).opacity(0.5)
                                    : Color.white.opacity(0.08),
                                lineWidth: 1.5
                            )
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)

            // Results list
            if !searchService.predictions.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(searchService.predictions) { prediction in
                            Button(action: {
                                query = prediction.mainText
                                onSelectPrediction(prediction)
                                isFocused = false
                            }) {
                                GoongPredictionRow(prediction: prediction)
                            }
                            .buttonStyle(PlainButtonStyle())

                            if prediction.id != searchService.predictions.last?.id {
                                Divider().background(Color.white.opacity(0.06))
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(red: 0.10, green: 0.13, blue: 0.19).opacity(0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 5)
            }

            if let err = searchService.errorMessage {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 14)
            }
        }
    }
}

private struct GoongPredictionRow: View {
    let prediction: GoongPrediction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 14))
                .foregroundColor(Color(red: 0, green: 0.75, blue: 1.0))
                .frame(width: 30, height: 30)
                .background(Color(red: 0, green: 0.75, blue: 1.0).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(prediction.mainText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if !prediction.secondaryText.isEmpty {
                    Text(prediction.secondaryText)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(.gray.opacity(0.4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
