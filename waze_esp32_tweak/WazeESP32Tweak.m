#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ESP32Protocol.h"
#import "ESP32BLEManager.h"
#import "ESP32VirtualHUDView.h"
#import "WazeMapStreamServer.h"

static uint8_t s_currentSpeed = 0;
static uint8_t s_allowedSpeed = 0;

static uint32_t parseDistanceMeters(NSString *str) {
    if (!str || str.length == 0) return 0;
    NSString *clean = [str lowercaseString];
    clean = [clean stringByReplacingOccurrencesOfString:@"," withString:@"."];
    double val = [clean doubleValue];
    if ([clean containsString:@"km"]) {
        return (uint32_t)(val * 1000.0);
    }
    return (uint32_t)val;
}

static uint32_t parseEtaSeconds(NSString *etaStr) {
    if (!etaStr || etaStr.length == 0) return 0;
    // format like "18:25" or "12m" or "1h 15m"
    if ([etaStr containsString:@":"]) {
        NSArray *parts = [etaStr componentsSeparatedByString:@":"];
        if (parts.count == 2) {
            NSInteger h = [parts[0] integerValue];
            NSInteger m = [parts[1] integerValue];
            NSDate *now = [NSDate date];
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSDateComponents *comps = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
            comps.hour = h;
            comps.minute = m;
            comps.second = 0;
            NSDate *target = [cal dateFromComponents:comps];
            NSTimeInterval diff = [target timeIntervalSinceDate:now];
            if (diff < 0) diff += 86400; // Next day
            return (uint32_t)diff;
        }
    }
    return 600; // default 10 mins
}

static NavManeuverIcon detectManeuverIcon(NSString *instruction, NSString *exitNumber) {
    if (exitNumber && exitNumber.length > 0) {
        return MANEUVER_ROUNDABOUT;
    }
    if (!instruction) return MANEUVER_STRAIGHT;
    NSString *lower = [instruction lowercaseString];
    if ([lower containsString:@"quay đầu"] || [lower containsString:@"u-turn"]) return MANEUVER_UTURN;
    if ([lower containsString:@"rẽ phải"] || [lower containsString:@"turn right"]) return MANEUVER_RIGHT;
    if ([lower containsString:@"chếch phải"] || [lower containsString:@"slight right"] || [lower containsString:@"keep right"]) return MANEUVER_SLIGHT_RIGHT;
    if ([lower containsString:@"rẽ gắt phải"] || [lower containsString:@"sharp right"]) return MANEUVER_SHARP_RIGHT;
    if ([lower containsString:@"rẽ trái"] || [lower containsString:@"turn left"]) return MANEUVER_LEFT;
    if ([lower containsString:@"chếch trái"] || [lower containsString:@"slight left"] || [lower containsString:@"keep left"]) return MANEUVER_LEFT;
    if ([lower containsString:@"đã đến"] || [lower containsString:@"arrived"]) return MANEUVER_ARRIVE;
    if ([lower containsString:@"bùng binh"] || [lower containsString:@"vòng xuyến"] || [lower containsString:@"roundabout"]) return MANEUVER_ROUNDABOUT;
    return MANEUVER_STRAIGHT;
}

#pragma mark - Hook Implementations

static id (*orig_WZNavStatus_init)(id self, SEL _cmd, id a1, id a2, id a3, id a4, id a5, id a6, id a7);
static id hooked_WZNavStatus_init(id self, SEL _cmd, id a1, id a2, id a3, id a4, id a5, id a6, id a7) {
    id res = orig_WZNavStatus_init(self, _cmd, a1, a2, a3, a4, a5, a6, a7);

    NSString *distNext = (NSString *)a1;
    NSString *instruction = (NSString *)a2;
    NSString *exitNum = (NSString *)a3;
    NSString *eta = (NSString *)a4;
    NSString *distTotal = (NSString *)a5;

    NavManeuverIcon icon = detectManeuverIcon(instruction, exitNum);
    uint32_t distToTurnMeters = parseDistanceMeters(distNext);
    uint32_t remainingDistMeters = parseDistanceMeters(distTotal);
    uint32_t etaSecs = parseEtaSeconds(eta);

    // 1. Send binary packet to ESP32 over BLE
    struct NavBinaryPacket packet;
    memset(&packet, 0, sizeof(packet));
    packet.header = NAV_MAGIC_HEADER;
    packet.maneuverIcon = (uint8_t)icon;
    packet.distanceToTurn = distToTurnMeters;
    packet.remainingDistance = remainingDistMeters;
    packet.remainingEta = etaSecs;
    packet.currentSpeed = s_currentSpeed;
    packet.speedLimit = s_allowedSpeed;

    const char *streetC = [(instruction ?: @"") UTF8String];
    size_t sLen = strlen(streetC);
    if (sLen > MAX_STREET_NAME_LEN - 1) sLen = MAX_STREET_NAME_LEN - 1;
    packet.nextStreetNameLen = (uint8_t)sLen;
    strncpy(packet.nextStreetName, streetC, sLen);

    [[ESP32BLEManager shared] sendNavPacket:&packet];

    // 2. Update Virtual HUD Simulator on iPhone screen
    [[ESP32VirtualHUDView sharedHUD] updateWithManeuver:icon
                                         distanceToTurn:distNext
                                           remainingEta:eta
                                      remainingDistance:distTotal
                                             nextStreet:instruction
                                           currentSpeed:s_currentSpeed
                                             speedLimit:s_allowedSpeed];

    return res;
}

static void (*orig_Speedometer_update)(id self, SEL _cmd, double curSpeed, double allowed, id units, id a4, id a5, id a6);
static void hooked_Speedometer_update(id self, SEL _cmd, double curSpeed, double allowed, id units, id a4, id a5, id a6) {
    orig_Speedometer_update(self, _cmd, curSpeed, allowed, units, a4, a5, a6);
    s_currentSpeed = (uint8_t)curSpeed;
    s_allowedSpeed = (uint8_t)allowed;
}

static void (*orig_WazeMainVC_viewDidAppear)(id self, SEL _cmd, BOOL animated);
static void hooked_WazeMainVC_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_WazeMainVC_viewDidAppear(self, _cmd, animated);
    UIViewController *vc = (UIViewController *)self;
    [[ESP32VirtualHUDView sharedHUD] showInView:vc.view];
}

static void (*orig_MapBridgeVC_mapIsReady)(id self, SEL _cmd);
static void hooked_MapBridgeVC_mapIsReady(id self, SEL _cmd) {
    orig_MapBridgeVC_mapIsReady(self, _cmd);
    UIViewController *vc = (UIViewController *)self;
    UIView *mapCanvas = vc.view;
    [[WazeMapStreamServer sharedServer] startMapCaptureWithView:mapCanvas targetFps:12];
}

#pragma mark - Constructor (Auto Loaded by dyld)

__attribute__((constructor))
static void WazeESP32TweakInit(void) {
    NSLog(@"[WazeESP32] Initializing Waze ESP32 Navigation & Virtual HUD Tweak...");

    // Start BLE Manager
    [[ESP32BLEManager shared] startScanning];

    // Start WebSocket Map Stream Server on Port 8080 (for ESP32 ST7789 TFT)
    [[WazeMapStreamServer sharedServer] startServerOnPort:8080];

    // 1. Hook WZNavigationStatus
    Class clsNav = objc_getClass("WZNavigationStatus");
    if (clsNav) {
        SEL sel = @selector(initWithDistanceToNextInstruction:nextInstruction:exitNumber:estimatedTimeOfArrival:distanceToArrival:destinationCity:routeGeoJson:);
        Method m = class_getInstanceMethod(clsNav, sel);
        if (m) {
            orig_WZNavStatus_init = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_WZNavStatus_init);
            NSLog(@"[WazeESP32] Hooked WZNavigationStatus successfully");
        }
    }

    // 2. Hook SpeedometerVC
    Class clsSpeed = objc_getClass("SpeedometerVC");
    if (clsSpeed) {
        SEL sel = @selector(speedometerDidUpdateWithCurrentSpeed:allowedSpeed:units:alertOffset:alertOffsetFixed:debugLimit:);
        Method m = class_getInstanceMethod(clsSpeed, sel);
        if (m) {
            orig_Speedometer_update = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_Speedometer_update);
            NSLog(@"[WazeESP32] Hooked SpeedometerVC successfully");
        }
    }

    // 3. Hook WazeMainViewController
    Class clsMain = objc_getClass("WazeMainViewController");
    if (clsMain) {
        SEL sel = @selector(viewDidAppear:);
        Method m = class_getInstanceMethod(clsMain, sel);
        if (m) {
            orig_WazeMainVC_viewDidAppear = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_WazeMainVC_viewDidAppear);
            NSLog(@"[WazeESP32] Hooked WazeMainViewController successfully");
        }
    }

    // 4. Hook MapBridgeViewController
    Class clsMap = objc_getClass("MapBridgeViewController");
    if (clsMap) {
        SEL sel = @selector(mapIsReady);
        Method m = class_getInstanceMethod(clsMap, sel);
        if (m) {
            orig_MapBridgeVC_mapIsReady = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_MapBridgeVC_mapIsReady);
            NSLog(@"[WazeESP32] Hooked MapBridgeViewController successfully");
        }
    }
}
