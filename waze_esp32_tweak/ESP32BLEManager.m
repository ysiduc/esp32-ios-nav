#import "ESP32BLEManager.h"

NSString *const kESP32BLEStatusChangedNotification = @"kESP32BLEStatusChangedNotification";

@interface ESP32BLEManager ()
@property (nonatomic, strong) CBCentralManager *centralManager;
@property (nonatomic, strong) CBPeripheral *targetPeripheral;
@property (nonatomic, strong) CBCharacteristic *writeCharacteristic;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, copy) NSString *connectedDeviceName;
@property (nonatomic, strong) NSTimer *reconnectTimer;
@end

@implementation ESP32BLEManager

+ (instancetype)shared {
    static ESP32BLEManager *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[ESP32BLEManager alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isConnected = NO;
        _connectedDeviceName = @"";
        _centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:@{
            CBCentralManagerOptionShowPowerAlertKey: @YES
        }];
    }
    return self;
}

- (void)startScanning {
    if (self.centralManager.state == CBManagerStatePoweredOn) {
        CBUUID *serviceUUID = [CBUUID UUIDWithString:ESP32_NAV_SERVICE_UUID];
        [self.centralManager scanForPeripheralsWithServices:@[serviceUUID] options:@{
            CBCentralManagerScanOptionAllowDuplicatesKey: @NO
        }];
        NSLog(@"[WazeESP32] Scanning for ESP32 with service %@", ESP32_NAV_SERVICE_UUID);
    }
}

- (void)stopScanning {
    [self.centralManager stopScan];
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state == CBManagerStatePoweredOn) {
        NSLog(@"[WazeESP32] Bluetooth Powered On");
        [self startScanning];
    } else {
        NSLog(@"[WazeESP32] Bluetooth State: %ld", (long)central.state);
        self.isConnected = NO;
        self.connectedDeviceName = @"";
        [[NSNotificationCenter defaultCenter] postNotificationName:kESP32BLEStatusChangedNotification object:self];
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    NSString *name = peripheral.name ?: [advertisementData objectForKey:CBAdvertisementDataLocalNameKey] ?: @"";
    NSLog(@"[WazeESP32] Discovered device: %@ (RSSI: %@)", name, RSSI);

    self.targetPeripheral = peripheral;
    self.targetPeripheral.delegate = self;
    [self.centralManager stopScan];
    [self.centralManager connectPeripheral:peripheral options:nil];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    NSLog(@"[WazeESP32] Connected to peripheral: %@", peripheral.name);
    self.isConnected = YES;
    self.connectedDeviceName = peripheral.name ?: @"ESP32 HUD";
    [[NSNotificationCenter defaultCenter] postNotificationName:kESP32BLEStatusChangedNotification object:self];
    
    CBUUID *serviceUUID = [CBUUID UUIDWithString:ESP32_NAV_SERVICE_UUID];
    [peripheral discoverServices:@[serviceUUID]];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    NSLog(@"[WazeESP32] Failed to connect: %@", error.localizedDescription);
    self.isConnected = NO;
    self.connectedDeviceName = @"";
    [[NSNotificationCenter defaultCenter] postNotificationName:kESP32BLEStatusChangedNotification object:self];
    [self startScanning];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    NSLog(@"[WazeESP32] Disconnected from peripheral: %@", error.localizedDescription);
    self.isConnected = NO;
    self.connectedDeviceName = @"";
    self.writeCharacteristic = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:kESP32BLEStatusChangedNotification object:self];
    
    // Auto reconnect after 2 seconds
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self startScanning];
    });
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) {
        NSLog(@"[WazeESP32] Discover services error: %@", error.localizedDescription);
        return;
    }
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:[CBUUID UUIDWithString:ESP32_NAV_SERVICE_UUID]]) {
            CBUUID *charUUID = [CBUUID UUIDWithString:ESP32_NAV_CHAR_UUID];
            [peripheral discoverCharacteristics:@[charUUID] forService:service];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error) {
        NSLog(@"[WazeESP32] Discover char error: %@", error.localizedDescription);
        return;
    }
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID isEqual:[CBUUID UUIDWithString:ESP32_NAV_CHAR_UUID]]) {
            self.writeCharacteristic = c;
            NSLog(@"[WazeESP32] Ready! Found Write Characteristic: %@", c.UUID);
        }
    }
}

#pragma mark - Transmission

- (void)sendNavPacket:(struct NavBinaryPacket *)packet {
    if (!self.isConnected || !self.writeCharacteristic || !self.targetPeripheral) {
        return;
    }
    size_t packetLen = 17 + packet->nextStreetNameLen; // header + fields + street
    uint8_t *bytePtr = (uint8_t *)packet;
    
    // Calculate XOR checksum
    uint8_t chk = 0;
    for (size_t i = 0; i < packetLen; ++i) {
        chk ^= bytePtr[i];
    }
    bytePtr[packetLen] = chk;

    [self sendRawBytes:bytePtr length:packetLen + 1];
}

- (void)sendRawBytes:(const uint8_t *)bytes length:(size_t)len {
    if (!self.isConnected || !self.writeCharacteristic || !self.targetPeripheral) {
        return;
    }
    NSData *data = [NSData dataWithBytes:bytes length:len];
    CBCharacteristicWriteType writeType = (self.writeCharacteristic.properties & CBCharacteristicPropertyWriteWithoutResponse)
                                          ? CBCharacteristicWriteWithoutResponse
                                          : CBCharacteristicWriteWithResponse;
    [self.targetPeripheral writeValue:data forCharacteristic:self.writeCharacteristic type:writeType];
}

@end
