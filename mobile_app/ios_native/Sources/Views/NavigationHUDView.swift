//
//  NavigationHUDView.swift
//  Active driving Heads-Up Display (HUD) — Google Maps / Waze style.
//
//  Layout:
//    ┌─────────────────────────────────────────────────┐  ← Top banner (green gradient)
//    │  [Turn icon]   500 m        📶BLE               │
//    │                Tên đường tiếp theo               │
//    └─────────────────────────────────────────────────┘
//                      [Map fills middle]
//    ┌─────────────────────────────────────────────────┐  ← Bottom bar (dark)
//    │  12:45 ETA  •  3.2 km  │  ⚡ 47 km/h   [✕ Stop]│
//    └─────────────────────────────────────────────────┘
//

import SwiftUI

public struct NavigationHUDView: View {

    public let progress: NavigationProgress
    public let bleState: BLEConnectionState
    public let isRerouting: Bool
    public let onOpenBLE: () -> Void
    public let onStopNavigation: () -> Void

    public init(
        progress: NavigationProgress,
        bleState: BLEConnectionState,
        isRerouting: Bool = false,
        onOpenBLE: @escaping () -> Void,
        onStopNavigation: @escaping () -> Void
    ) {
        self.progress          = progress
        self.bleState          = bleState
        self.isRerouting       = isRerouting
        self.onOpenBLE         = onOpenBLE
        self.onStopNavigation  = onStopNavigation
    }

    public var body: some View {
        VStack(spacing: 0) {
            // ── Top Turn Banner ───────────────────────────────────────────
            topBanner
                .padding(.horizontal, 14)
                .padding(.top, 6)

            Spacer()

            // ── Bottom Trip Summary ──────────────────────────────────────
            bottomBar
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
    }

    // MARK: - Top Turn Banner

    private var topBanner: some View {
        HStack(alignment: .center, spacing: 14) {

            // Large maneuver icon
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 58, height: 58)

                if isRerouting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)
                } else {
                    Image(systemName: progress.maneuver.sfSymbolName)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)
                }
            }

            // Distance + street name
            VStack(alignment: .leading, spacing: 3) {
                if isRerouting {
                    Text("Đang tính lại...")
                        .font(.system(size: 26, weight: .black, design: .rounded))
                        .foregroundColor(.yellow)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)

                    Text("Đang tìm lộ trình mới")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                } else {
                    Text(progress.formattedDistanceToTurn)
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)

                    Text(streetDisplayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(2)
                }
            }

            Spacer()

            // BLE pill
            bleIndicator
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.50, blue: 0.25),
                    Color(red: 0.02, green: 0.36, blue: 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .cornerRadius(22)
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 5)
    }

    private var streetDisplayName: String {
        if !progress.nextStreetName.isEmpty {
            return progress.nextStreetName
        }
        return progress.maneuver.localizedInstruction
    }

    private var bleIndicator: some View {
        Button(action: onOpenBLE) {
            HStack(spacing: 4) {
                Circle()
                    .fill(bleState == .connected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.30))
            .clipShape(Capsule())
        }
    }

    // MARK: - Bottom Summary Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {

            // ETA + distance
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // ETA countdown
                    Label {
                        Text(progress.formattedRemainingEta)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(Color(red: 0.2, green: 0.9, blue: 0.5))
                    } icon: {
                        Image(systemName: "clock")
                            .font(.system(size: 13))
                            .foregroundColor(Color(red: 0.2, green: 0.9, blue: 0.5))
                    }

                    Text("•")
                        .foregroundColor(.gray)

                    // Remaining km
                    Text(progress.formattedRemainingDistance)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }

                // Speed
                HStack(spacing: 5) {
                    Image(systemName: "gauge.medium")
                        .font(.system(size: 12))
                        .foregroundColor(.cyan)
                    Text("\(progress.currentSpeedKmh) km/h")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.cyan)
                }
            }

            Spacer()

            // Stop navigation button
            Button(action: onStopNavigation) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        RadialGradient(
                            colors: [Color.red, Color(red: 0.7, green: 0, blue: 0)],
                            center: .center,
                            startRadius: 5,
                            endRadius: 24
                        )
                    )
                    .clipShape(Circle())
                    .shadow(color: .red.opacity(0.5), radius: 8, x: 0, y: 3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(red: 0.10, green: 0.14, blue: 0.20).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 7)
    }
}
