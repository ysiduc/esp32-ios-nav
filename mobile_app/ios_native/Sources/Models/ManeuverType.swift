import SwiftUI

/// Maneuver Types representing navigation directions
/// Raw value matches the binary BLE protocol byte sent to ESP32:
/// 0=None, 1=Straight, 2=Slight Right, 3=Right, 4=Sharp Right,
/// 5=U-Turn, 6=Left, 7=Roundabout, 8=Arrive
public enum ManeuverType: UInt8, CaseIterable, Codable, Sendable {
    case none = 0
    case straight = 1
    case slightRight = 2
    case right = 3
    case sharpRight = 4
    case uTurn = 5
    case left = 6
    case roundabout = 7
    case arrive = 8
    case slightLeft = 9
    case sharpLeft = 10

    /// Byte code sent in the BLE Binary Packet (0..8)
    public var bleCode: UInt8 {
        switch self {
        case .none: return 0
        case .straight: return 1
        case .slightRight: return 2
        case .right: return 3
        case .sharpRight: return 4
        case .uTurn: return 5
        case .left: return 6
        case .roundabout: return 7
        case .arrive: return 8
        case .slightLeft: return 6  // Map to Left on simple 8-icon display
        case .sharpLeft: return 6   // Map to Left on simple 8-icon display
        }
    }

    /// SF Symbol icon name for SwiftUI HUD
    public var sfSymbolName: String {
        switch self {
        case .none: return "questionmark.circle"
        case .straight: return "arrow.up"
        case .slightRight: return "arrow.up.right"
        case .right: return "arrow.turn.up.right"
        case .sharpRight: return "arrow.uturn.right"
        case .uTurn: return "arrow.uturn.down"
        case .left: return "arrow.turn.up.left"
        case .slightLeft: return "arrow.up.left"
        case .sharpLeft: return "arrow.uturn.left"
        case .roundabout: return "arrow.triangle.2.circlepath"
        case .arrive: return "flag.checkered"
        }
    }

    /// Vietnamese navigation prompt
    public var localizedInstruction: String {
        switch self {
        case .none: return "Tiếp tục"
        case .straight: return "Đi thẳng"
        case .slightRight: return "Chếch sang phải"
        case .right: return "Rẽ phải"
        case .sharpRight: return "Rẽ gấp sang phải"
        case .uTurn: return "Quay đầu xe"
        case .left: return "Rẽ trái"
        case .slightLeft: return "Chếch sang trái"
        case .sharpLeft: return "Rẽ gấp sang trái"
        case .roundabout: return "Đi vào bùng binh"
        case .arrive: return "Đến đích"
        }
    }

    /// Map from Valhalla maneuver type code and modifier
    public static func fromValhalla(type: Int, modifier: String? = nil) -> ManeuverType {
        let mod = modifier?.lowercased() ?? ""
        if type == 4 || type == 5 || type == 6 { return .arrive }
        if type >= 24 && type <= 27 { return .roundabout }
        if mod.contains("u-turn") || mod.contains("uturn") { return .uTurn }
        if mod.contains("sharp right") { return .sharpRight }
        if mod.contains("slight right") { return .slightRight }
        if mod.contains("right") { return .right }
        if mod.contains("sharp left") { return .sharpLeft }
        if mod.contains("slight left") { return .slightLeft }
        if mod.contains("left") { return .left }
        if mod.contains("straight") { return .straight }

        switch type {
        case 7, 8, 9: return .straight
        case 10: return .slightRight
        case 11: return .right
        case 12: return .sharpRight
        case 13: return .uTurn
        case 14: return .sharpLeft
        case 15: return .left
        case 16: return .slightLeft
        default: return .straight
        }
    }
}
