import Foundation

/// Binary Packet Serializer matching the ESP32 C++ packed struct protocol
/// Total length = 1 + 1 + 4 + 4 + 4 + 1 + 1 + 1 + N + 1 = 18 + N bytes (<= 50 bytes, fits standard BLE MTU)
public struct BLEPacket {
    public static let magicHeader: UInt8 = 0xAA
    public static let maxStreetNameLength: Int = 32

    /// Serialize NavigationProgress into raw Data with XOR checksum
    public static func serialize(progress: NavigationProgress) -> Data {
        var data = Data()

        // 1. Header (0xAA)
        data.append(magicHeader)

        // 2. Maneuver Icon Code (0..8)
        data.append(progress.maneuver.bleCode)

        // 3. Distance to Turn (UInt32 Little Endian)
        var distTurn = progress.distanceToTurnMeters.littleEndian
        withUnsafeBytes(of: &distTurn) { data.append(contentsOf: $0) }

        // 4. Remaining Distance (UInt32 Little Endian)
        var remDist = progress.remainingDistanceMeters.littleEndian
        withUnsafeBytes(of: &remDist) { data.append(contentsOf: $0) }

        // 5. Remaining ETA in seconds (UInt32 Little Endian)
        var remEta = progress.remainingEtaSeconds.littleEndian
        withUnsafeBytes(of: &remEta) { data.append(contentsOf: $0) }

        // 6. Current Speed (UInt8)
        data.append(progress.currentSpeedKmh)

        // 7. Speed Limit (UInt8)
        data.append(progress.speedLimitKmh)

        // 8. Next Street Name (max 32 UTF-8 bytes)
        let cleanStreet = progress.nextStreetName
            .folding(options: .diacriticInsensitive, locale: .current) // Optionally clean Vietnamese for ASCII display or keep UTF-8
        let streetBytes = Array(cleanStreet.utf8.prefix(maxStreetNameLength))
        let streetLen = UInt8(streetBytes.count)

        data.append(streetLen)
        data.append(contentsOf: streetBytes)

        // 9. Checksum: XOR of all preceding bytes
        var checksum: UInt8 = 0
        for byte in data {
            checksum ^= byte
        }
        data.append(checksum)

        return data
    }

    /// Validate and deserialize incoming binary packet from ESP32 (if needed)
    public static func validate(data: Data) -> Bool {
        guard data.count >= 19 else { return false }
        guard data[0] == magicHeader else { return false }

        var expectedChecksum: UInt8 = 0
        for i in 0..<(data.count - 1) {
            expectedChecksum ^= data[i]
        }
        return expectedChecksum == data[data.count - 1]
    }
}
