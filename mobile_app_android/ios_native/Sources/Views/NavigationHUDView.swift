import SwiftUI

/// Active driving HUD banner overlay resembling Google Maps turn-by-turn guidance
public struct NavigationHUDView: View {
    let progress: NavigationProgress
    let bleState: BLEConnectionState
    let onOpenBLE: () -> Void
    let onStopNavigation: () -> Void

    public var body: some View {
        VStack(spacing: 0) {
            // Top Driving Guidance Banner
            VStack(spacing: 8) {
                HStack(alignment: .center, spacing: 14) {
                    // Turn Maneuver Icon
                    Image(systemName: progress.maneuver.sfSymbolName)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.white.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 2) {
                        // Large Distance to Turn
                        Text(progress.formattedDistanceToTurn)
                            .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundColor(.white)

                        // Next Street / Turn Instruction
                        Text(progress.nextStreetName.isEmpty ? progress.maneuver.localizedInstruction : progress.nextStreetName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                    }

                    Spacer()

                    // BLE Connection Pill Indicator
                    Button(action: onOpenBLE) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(bleState == .connected ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)

                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 11))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.48, blue: 0.25), Color(red: 0.02, green: 0.38, blue: 0.18)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(20)
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)

            Spacer()

            // Bottom Trip Summary Card
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(progress.formattedRemainingEta)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.green)

                        Text("•")
                            .foregroundColor(.gray)

                        Text(progress.formattedRemainingDistance)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 12))
                            .foregroundColor(.cyan)

                        Text("\(progress.currentSpeedKmh) km/h")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.cyan)
                    }
                }

                Spacer()

                // Red Exit/Stop Button
                Button(action: onStopNavigation) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 46, height: 46)
                        .background(Color.red)
                        .clipShape(Circle())
                        .shadow(color: .red.opacity(0.4), radius: 6, x: 0, y: 3)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(red: 0.12, green: 0.16, blue: 0.22).opacity(0.96))
            .cornerRadius(24)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }
}
