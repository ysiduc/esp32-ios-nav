import SwiftUI

/// Floating search bar with real-time Photon autocomplete dropdown
public struct SearchBarView: View {
    @ObservedObject var searchService: PhotonSearchService
    let onSelect: (SearchResultItem) -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    public var body: some View {
        VStack(spacing: 0) {
            // Search Input Field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.cyan)
                    .font(.system(size: 16, weight: .semibold))

                TextField("Tìm kiếm địa chỉ, số nhà, địa điểm...", text: $searchService.searchText)
                    .foregroundColor(.white)
                    .font(.system(size: 15))
                    .focused($isFocused)
                    .autocorrectionDisabled()

                if searchService.isSearching {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                        .scaleEffect(0.8)
                } else if !searchService.searchText.isEmpty {
                    Button(action: {
                        searchService.clear()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                            .font(.system(size: 16))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(red: 0.12, green: 0.16, blue: 0.22).opacity(0.95))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)

            // Autocomplete Results Dropdown
            if !searchService.results.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(searchService.results) { item in
                            Button(action: {
                                isFocused = false
                                onSelect(item)
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.system(size: 20))

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name)
                                            .foregroundColor(.white)
                                            .font(.system(size: 15, weight: .semibold))
                                            .lineLimit(1)

                                        Text(item.formattedSubtitle)
                                            .foregroundColor(.gray)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    if !item.formattedDistance.isEmpty {
                                        Text(item.formattedDistance)
                                            .foregroundColor(.cyan)
                                            .font(.system(size: 12, weight: .bold))
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color(red: 0.08, green: 0.11, blue: 0.16))
                            }
                            Divider().background(Color.white.opacity(0.08))
                        }
                    }
                }
                .frame(maxHeight: 280)
                .background(Color(red: 0.08, green: 0.11, blue: 0.16))
                .cornerRadius(16)
                .padding(.top, 6)
                .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 6)
            }
        }
    }
}
