import SwiftUI

/// Bluetooth Settings and Peripheral Scanner Sheet
public struct BLEScannerSheet: View {
    @ObservedObject var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.08, green: 0.11, blue: 0.16).ignoresSafeArea()

                VStack(spacing: 16) {
                    // Header Status Card
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TRẠNG THÁI KẾT NỐI")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.cyan)

                            Text(bleManager.connectionState.rawValue)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.white)

                            if bleManager.connectionState == .connected {
                                Text("MTU đã thỏa thuận: \(bleManager.negotiatedMTU) bytes")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                            }
                        }

                        Spacer()

                        Button(action: {
                            if bleManager.connectionState == .scanning {
                                bleManager.stopScanning()
                            } else {
                                bleManager.startScanning()
                            }
                        }) {
                            HStack(spacing: 6) {
                                if bleManager.connectionState == .scanning {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                    Text("Dừng")
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Quét")
                                }
                            }
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    }
                    .padding(16)
                    .background(Color(red: 0.12, green: 0.16, blue: 0.22))
                    .cornerRadius(16)

                    // Connected Device (if any)
                    if let connected = bleManager.connectedPeripheral {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("THIẾT BỊ ĐANG KẾT NỐI")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.green)

                            HStack {
                                Image(systemName: "display")
                                    .font(.system(size: 24))
                                    .foregroundColor(.cyan)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connected.name ?? "ESP32 Navi")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)

                                    Text(connected.identifier.uuidString.prefix(18) + "...")
                                        .font(.system(size: 11))
                                        .foregroundColor(.gray)
                                }

                                Spacer()

                                Button("Ngắt kết nối") {
                                    bleManager.disconnect()
                                }
                                .font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.2))
                                .foregroundColor(.red)
                                .cornerRadius(8)
                            }
                        }
                        .padding(16)
                        .background(Color(red: 0.12, green: 0.16, blue: 0.22))
                        .cornerRadius(16)
                    }

                    // Discovered Peripherals List
                    VStack(alignment: .leading, spacing: 8) {
                        Text("THIẾT BỊ TÌM THẤY")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.gray)

                        if bleManager.discoveredDevices.isEmpty {
                            VStack(spacing: 12) {
                                Spacer()
                                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                    .font(.system(size: 36))
                                    .foregroundColor(.gray.opacity(0.5))

                                Text("Chưa tìm thấy thiết bị ESP32 nào gần đây.\nHãy bật nguồn mạch ESP32.")
                                    .font(.system(size: 13))
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: 180)
                        } else {
                            List(bleManager.discoveredDevices) { device in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.white)

                                        HStack(spacing: 8) {
                                            Text("RSSI: \(device.rssi) dBm")
                                                .font(.system(size: 12))
                                                .foregroundColor(device.rssi > -70 ? .green : .orange)
                                        }
                                    }

                                    Spacer()

                                    Button("Kết nối") {
                                        bleManager.connect(to: device.peripheral)
                                    }
                                    .font(.system(size: 13, weight: .bold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Color.cyan)
                                    .foregroundColor(.black)
                                    .cornerRadius(8)
                                }
                                .listRowBackground(Color(red: 0.12, green: 0.16, blue: 0.22))
                            }
                            .listStyle(PlainListStyle())
                            .cornerRadius(16)
                        }
                    }

                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("Cài đặt Bluetooth ESP32")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") {
                        dismiss()
                    }
                    .foregroundColor(.cyan)
                }
            }
        }
    }
}
