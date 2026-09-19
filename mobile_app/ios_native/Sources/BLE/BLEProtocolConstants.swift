import CoreBluetooth
import Foundation

/// BLE UUID definitions and protocol constants
public enum BLEProtocolConstants {
    /// Custom Navigation Service UUID (FFE0 = 0xFFE0)
    public static let serviceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")

    /// Navigation Binary Packet Characteristic (Write Without Response / Notify)
    public static let navigationDataCharUUID = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")

    /// Device Status / Control Characteristic (Read / Write)
    public static let deviceStatusCharUUID = CBUUID(string: "0000FFE2-0000-1000-8000-00805F9B34FB")

    /// Target peripheral device name prefix — matches ESP32 firmware NimBLEDevice::init name
    public static let targetDevicePrefixes = [
        "ysiducw",     // Current firmware name
        "ysid",        // Short BLE advertisement name
        "ESP32-S3",    // Legacy name
        "ESP32-NAV",
        "ESP32_NAV",
    ]
}

/// BLE connection states
public enum BLEConnectionState: String, Sendable {
    case disconnected   = "Chưa kết nối"
    case scanning       = "Đang quét tìm ESP32..."
    case connecting     = "Đang kết nối..."
    case connected      = "Đã kết nối ESP32"
    case reconnecting   = "Mất kết nối, đang thử lại..."
}

/// Discovered Peripheral representation for UI lists
public struct DiscoveredDevice: Identifiable, Hashable {
    public let id: UUID
    public let peripheral: CBPeripheral
    public let name: String
    public let rssi: Int

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool { lhs.id == rhs.id }
}
