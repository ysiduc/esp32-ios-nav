import Foundation
@preconcurrency import CoreBluetooth
import Combine

/// Central Manager handling Bluetooth Low Energy communication with the ESP32 screen
@MainActor
public final class BLEManager: NSObject, ObservableObject {
    @Published public private(set) var connectionState: BLEConnectionState = .disconnected
    @Published public private(set) var connectedPeripheral: CBPeripheral?
    @Published public private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published public private(set) var negotiatedMTU: Int = 23
    @Published public private(set) var lastSentPacketTime: Date?

    private var centralManager: CBCentralManager!
    private var navigationCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?

    private var reconnectAttempts: Int = 0
    private var reconnectTimer: Timer?
    private var targetPeripheralUUID: UUID?

    public override init() {
        super.init()
        guard !ProcessInfo.isRunningUnitTests else { return }
        self.centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "ESP32NavCentralManager",
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    /// Start scanning for ESP32 peripherals
    public func startScanning() {
        guard centralManager != nil, centralManager.state == .poweredOn else { return }
        connectionState = .scanning
        discoveredDevices.removeAll()

        centralManager.scanForPeripherals(
            withServices: [BLEProtocolConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // Also scan without service filter for 5s to catch unadvertised peripherals
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.connectionState == .scanning else { return }
            self.centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    /// Stop scanning
    public func stopScanning() {
        centralManager?.stopScan()
        if connectionState == .scanning {
            connectionState = .disconnected
        }
    }

    /// Connect to a specific peripheral
    public func connect(to peripheral: CBPeripheral) {
        stopScanning()
        connectionState = .connecting
        targetPeripheralUUID = peripheral.identifier
        peripheral.delegate = self
        centralManager?.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    /// Disconnect current peripheral
    public func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempts = 0
        targetPeripheralUUID = nil

        if let p = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(p)
        }
        connectionState = .disconnected
    }

    /// Send binary packed navigation packet to ESP32 screen
    public func sendNavigationPacket(_ progress: NavigationProgress) {
        guard connectionState == .connected,
              let peripheral = connectedPeripheral,
              let characteristic = navigationCharacteristic else {
            return
        }

        let packetData = BLEPacket.serialize(progress: progress)

        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

        peripheral.writeValue(packetData, for: characteristic, type: writeType)
        lastSentPacketTime = Date()
    }

    // MARK: - Auto-Reconnect with Exponential Backoff
    private func scheduleReconnect() {
        guard let uuid = targetPeripheralUUID else { return }
        connectionState = .reconnecting

        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 16.0) // 2s, 4s, 8s, max 16s

        print("[BLEManager] Connection lost. Scheduling reconnect attempt #\(reconnectAttempts) in \(Int(delay))s...")
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let known = self.centralManager.retrievePeripherals(withIdentifiers: [uuid])
                if let peripheral = known.first {
                    self.connect(to: peripheral)
                } else {
                    self.startScanning()
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[BLEManager] Bluetooth is powered ON.")
            startScanning()
        case .poweredOff:
            connectionState = .disconnected
            print("[BLEManager] Bluetooth is powered OFF.")
        case .unauthorized:
            connectionState = .disconnected
            print("[BLEManager] Bluetooth unauthorized.")
        default:
            connectionState = .disconnected
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = restoredPeripherals.first {
            print("[BLEManager] Restored peripheral: \(peripheral.name ?? "ESP32")")
            self.connectedPeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Thiết bị không tên"

        let isTarget = BLEProtocolConstants.targetDevicePrefixes.contains { prefix in
            name.localizedCaseInsensitiveContains(prefix)
        }

        let device = DiscoveredDevice(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue
        )

        if !discoveredDevices.contains(where: { $0.id == device.id }) {
            discoveredDevices.append(device)
            discoveredDevices.sort { $0.rssi > $1.rssi }
        }

        // Auto-connect if target device found
        if isTarget && connectionState == .scanning {
            print("[BLEManager] Auto-connecting to target: \(name)")
            connect(to: peripheral)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[BLEManager] Connected to \(peripheral.name ?? "ESP32")!")
        connectedPeripheral = peripheral
        reconnectAttempts = 0
        reconnectTimer?.invalidate()

        // Discover services
        peripheral.discoverServices([BLEProtocolConstants.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[BLEManager] Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[BLEManager] Disconnected from peripheral: \(error?.localizedDescription ?? "clean disconnect")")
        connectedPeripheral = nil
        navigationCharacteristic = nil
        statusCharacteristic = nil

        if targetPeripheralUUID != nil {
            scheduleReconnect()
        } else {
            connectionState = .disconnected
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }

        for service in services where service.uuid == BLEProtocolConstants.serviceUUID {
            peripheral.discoverCharacteristics([
                BLEProtocolConstants.navigationDataCharUUID,
                BLEProtocolConstants.deviceStatusCharUUID
            ], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        for char in characteristics {
            if char.uuid == BLEProtocolConstants.navigationDataCharUUID {
                self.navigationCharacteristic = char
            } else if char.uuid == BLEProtocolConstants.deviceStatusCharUUID {
                self.statusCharacteristic = char
                // Subscribe to status updates if notify capable
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
        }

        if navigationCharacteristic != nil {
            connectionState = .connected
            negotiatedMTU = peripheral.maximumWriteValueLength(for: .withoutResponse)
            print("[BLEManager] Link Ready! Max write length: \(negotiatedMTU) bytes")
        }
    }
}
