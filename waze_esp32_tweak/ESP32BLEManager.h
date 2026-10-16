#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import "ESP32Protocol.h"

extern NSString *const kESP32BLEStatusChangedNotification;

@interface ESP32BLEManager : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>

@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly, copy) NSString *connectedDeviceName;

+ (instancetype)shared;
- (void)startScanning;
- (void)stopScanning;
- (void)sendNavPacket:(struct NavBinaryPacket *)packet;
- (void)sendRawBytes:(const uint8_t *)bytes length:(size_t)len;

@end
