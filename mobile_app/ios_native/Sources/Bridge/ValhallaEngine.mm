//
//  ValhallaEngine.mm
//  Objective-C++ implementation wrapping valhalla::actor_t via valhalla-wrapper.
//

#import "ValhallaEngine.h"
#import <Foundation/Foundation.h>

// Valhalla is now compiled and linked via valhalla-wrapper.xcframework (libvalhalla_all.a)
#define VALHALLA_AVAILABLE 1

#if VALHALLA_AVAILABLE
#if __has_include(<include/main.h>)
#include <include/main.h>
#elif __has_include("main.h")
#include "main.h"
#else
#include <string>
std::string route(const char *request, void* actor);
std::string trace_route(const char *request, void* actor);
std::string trace_attributes(const char *request, void* actor);
std::string height(const char *request, void* actor);
std::string matrix(const char *request, void* actor);
void* create_valhalla_actor(const char *config_path, void* http_client = nullptr);
void delete_valhalla_actor(void* actor);
#endif
#include <string>
#include <stdexcept>
#endif

NSString *const ValhallaEngineErrorDomain = @"com.ysiduc.ValhallaEngine";

// ---------------------------------------------------------------------------
// MARK: - ValhallaStep
// ---------------------------------------------------------------------------

@implementation ValhallaStep

- (instancetype)init {
    self = [super init];
    if (self) {
        _distanceMeters  = 0;
        _durationSeconds = 0;
        _streetName      = @"";
        _maneuverType    = 0;
        _instruction     = @"";
        _encodedPolyline = @"";
        _beginShapeIndex = 0;
        _endShapeIndex   = 0;
    }
    return self;
}

@end

// ---------------------------------------------------------------------------
// MARK: - ValhallaRoute
// ---------------------------------------------------------------------------

@implementation ValhallaRoute

- (instancetype)init {
    self = [super init];
    if (self) {
        _totalDistanceMeters  = 0;
        _totalDurationSeconds = 0;
        _encodedPolyline6     = @"";
        _steps                = @[];
        _rawJSON              = @"";
    }
    return self;
}

@end

// ---------------------------------------------------------------------------
// MARK: - ValhallaEngine Private State
// ---------------------------------------------------------------------------

@interface ValhallaEngine ()

@property (nonatomic, assign) BOOL configLoaded;
@property (nonatomic, strong) dispatch_queue_t queue;

#if VALHALLA_AVAILABLE
@property (nonatomic, assign) void *actorPtr;
#endif

@end

// ---------------------------------------------------------------------------
// MARK: - ValhallaEngine Implementation
// ---------------------------------------------------------------------------

@implementation ValhallaEngine {
#if VALHALLA_AVAILABLE
    void *_actor;
#endif
}

+ (instancetype)shared {
    static ValhallaEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ValhallaEngine alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _configLoaded = NO;
        _queue = dispatch_queue_create("com.ysiduc.valhalla.routing", DISPATCH_QUEUE_SERIAL);
#if VALHALLA_AVAILABLE
        _actor = nullptr;
#endif
    }
    return self;
}

- (void)dealloc {
#if VALHALLA_AVAILABLE
    if (_actor) {
        delete_valhalla_actor(_actor);
        _actor = nullptr;
    }
#endif
}

- (BOOL)isAvailable {
#if VALHALLA_AVAILABLE
    return YES;
#else
    return NO;
#endif
}

- (BOOL)loadConfigAtPath:(NSString *)configPath error:(NSError **)error {
#if VALHALLA_AVAILABLE
    __block BOOL success = NO;
    __block NSError *loadError = nil;

    dispatch_sync(self.queue, ^{
        try {
            if (_actor) {
                delete_valhalla_actor(_actor);
                _actor = nullptr;
            }

            std::string path = [configPath UTF8String];
            _actor = create_valhalla_actor(path.c_str(), nullptr);
            if (_actor != nullptr) {
                self.configLoaded = YES;
                success = YES;
                NSLog(@"[ValhallaEngine] ✅ Native Valhalla engine initialized successfully from: %@", configPath);
            } else {
                loadError = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                               code:ValhallaEngineErrorEngineException
                                           userInfo:@{NSLocalizedDescriptionKey: @"Failed to create Valhalla actor. Check config and tile paths."}];
                NSLog(@"[ValhallaEngine] ❌ create_valhalla_actor returned null");
            }
        } catch (const std::exception &e) {
            loadError = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                           code:ValhallaEngineErrorEngineException
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                      [NSString stringWithUTF8String:e.what()]}];
            NSLog(@"[ValhallaEngine] ❌ Exception in loadConfigAtPath: %s", e.what());
        } catch (...) {
            loadError = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                           code:ValhallaEngineErrorEngineException
                                       userInfo:@{NSLocalizedDescriptionKey: @"Unknown exception during Valhalla initialization"}];
            NSLog(@"[ValhallaEngine] ❌ Unknown exception in loadConfigAtPath");
        }
    });

    if (error) *error = loadError;
    return success;

#else
    NSLog(@"[ValhallaEngine] STUB mode — loadConfig pretending success.");
    self.configLoaded = YES;
    return YES;
#endif
}

- (nullable ValhallaRoute *)computeRouteFromLat:(double)fromLat
                                          fromLon:(double)fromLon
                                            toLat:(double)toLat
                                            toLon:(double)toLon
                                          costing:(NSString *)costing
                                            error:(NSError **)error {

    if (!self.configLoaded) {
        if (error) {
            *error = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                         code:ValhallaEngineErrorConfigNotLoaded
                                     userInfo:@{NSLocalizedDescriptionKey: @"Call loadConfigAtPath: first."}];
        }
        return nil;
    }

#if VALHALLA_AVAILABLE
    __block ValhallaRoute *result = nil;
    __block NSError *routeError  = nil;

    dispatch_sync(self.queue, ^{
        if (!_actor) {
            routeError = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                             code:ValhallaEngineErrorConfigNotLoaded
                                         userInfo:@{NSLocalizedDescriptionKey: @"Valhalla actor is null."}];
            return;
        }

        try {
            // Build Valhalla JSON request
            NSString *requestJSON = [NSString stringWithFormat:
                @"{\"locations\":[{\"lon\":%.7f,\"lat\":%.7f},{\"lon\":%.7f,\"lat\":%.7f}],"
                @"\"costing\":\"%@\","
                @"\"directions_options\":{\"language\":\"vi\",\"units\":\"kilometers\","
                @"\"narrative\":true},\"format\":\"json\"}",
                fromLon, fromLat, toLon, toLat, costing];

            std::string req([requestJSON UTF8String]);
            std::string resp = route(req.c_str(), _actor);

            NSString *jsonString = [NSString stringWithUTF8String:resp.c_str()];
            result = [self parseValhallaJSON:jsonString error:&routeError];

        } catch (const std::exception &e) {
            routeError = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                             code:ValhallaEngineErrorEngineException
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithUTF8String:e.what()]}];
        } catch (...) {
            routeError = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                             code:ValhallaEngineErrorEngineException
                                         userInfo:@{NSLocalizedDescriptionKey: @"Unknown exception during route calculation"}];
        }
    });

    if (error) *error = routeError;
    return result;

#else
    // STUB IMPLEMENTATION
    NSLog(@"[ValhallaEngine] STUB — returning fake route from (%.4f,%.4f) to (%.4f,%.4f)",
          fromLat, fromLon, toLat, toLon);

    double midLat = (fromLat + toLat) / 2.0;
    double midLon = (fromLon + toLon) / 2.0;

    double dlat = (toLat - fromLat) * 111319.9;
    double dlon = (toLon - fromLon) * 111319.9 * cos(fromLat * M_PI / 180.0);
    double totalMeters = sqrt(dlat * dlat + dlon * dlon);

    ValhallaStep *step1 = [[ValhallaStep alloc] init];
    step1.distanceMeters  = totalMeters / 2.0;
    step1.durationSeconds = (totalMeters / 2.0) / 10.0;
    step1.streetName      = @"Đường Thẳng";
    step1.maneuverType    = 1;
    step1.instruction     = @"Đi thẳng";
    step1.beginShapeIndex = 0;
    step1.endShapeIndex   = 1;

    ValhallaStep *step2 = [[ValhallaStep alloc] init];
    step2.distanceMeters  = totalMeters / 2.0;
    step2.durationSeconds = (totalMeters / 2.0) / 10.0;
    step2.streetName      = @"";
    step2.maneuverType    = 6;
    step2.instruction     = @"Đến đích";
    step2.beginShapeIndex = 1;
    step2.endShapeIndex   = 2;

    step1.encodedPolyline = @"";
    step2.encodedPolyline = @"";

    ValhallaRoute *route          = [[ValhallaRoute alloc] init];
    route.totalDistanceMeters     = totalMeters;
    route.totalDurationSeconds    = totalMeters / 10.0;
    route.encodedPolyline6        = @"";
    route.steps                   = @[step1, step2];
    route.rawJSON = [NSString stringWithFormat:
        @"{\"_stub_coords\":[[%.7f,%.7f],[%.7f,%.7f],[%.7f,%.7f]],"
        @"\"trip\":{\"summary\":{\"length\":%.4f,\"time\":%.1f},\"status\":0}}",
        fromLon, fromLat,
        midLon, midLat,
        toLon, toLat,
        totalMeters / 1000.0,
        totalMeters / 10.0];

    return route;
#endif
}

// ---------------------------------------------------------------------------
// MARK: - JSON Parser (real Valhalla response)
// ---------------------------------------------------------------------------

- (nullable ValhallaRoute *)parseValhallaJSON:(NSString *)jsonString
                                        error:(NSError **)error {
    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                         code:ValhallaEngineErrorInvalidJSON
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to encode JSON string as UTF-8"}];
        }
        return nil;
    }

    NSError *parseError = nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data
                                                          options:0
                                                            error:&parseError];
    if (!root || parseError) {
        if (error) *error = parseError;
        return nil;
    }

    NSDictionary *trip = root[@"trip"];
    if (!trip) {
        NSString *msg = @"No route found";
        if ([root[@"error"] isKindOfClass:[NSDictionary class]]) {
            msg = root[@"error"][@"message"] ?: @"No route found";
        } else if ([root[@"error"] isKindOfClass:[NSString class]]) {
            msg = root[@"error"];
        } else if ([root[@"message"] isKindOfClass:[NSString class]]) {
            msg = root[@"message"];
        }
        if (error) {
            *error = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                         code:ValhallaEngineErrorNoRouteFound
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return nil;
    }

    NSDictionary *summary = trip[@"summary"];
    double totalKm  = [summary[@"length"] doubleValue];
    double totalSec = [summary[@"time"]   doubleValue];

    NSArray *legs = trip[@"legs"];
    if (!legs || legs.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                         code:ValhallaEngineErrorNoRouteFound
                                     userInfo:@{NSLocalizedDescriptionKey: @"No legs in route"}];
        }
        return nil;
    }

    NSDictionary *leg0 = legs[0];
    NSString *legPolyline = leg0[@"shape"] ?: @"";
    NSArray *maneuvers    = leg0[@"maneuvers"] ?: @[];

    NSMutableArray<ValhallaStep *> *steps = [NSMutableArray array];
    for (NSDictionary *m in maneuvers) {
        ValhallaStep *step  = [[ValhallaStep alloc] init];
        step.distanceMeters  = [m[@"length"] doubleValue] * 1000.0;
        step.durationSeconds = [m[@"time"]   doubleValue];
        step.maneuverType    = [m[@"type"]   integerValue];
        step.instruction     = m[@"instruction"] ?: @"";
        step.beginShapeIndex = [m[@"begin_shape_index"] integerValue];
        step.endShapeIndex   = [m[@"end_shape_index"]   integerValue];

        NSArray *streetNames = m[@"street_names"];
        step.streetName = (streetNames && streetNames.count > 0) ? streetNames[0] : @"";
        if (step.streetName.length == 0) {
            NSDictionary *sign = m[@"sign"];
            NSArray *exitToward = sign[@"exit_toward_elements"];
            if (exitToward && exitToward.count > 0) {
                step.streetName = exitToward[0][@"text"] ?: @"";
            }
        }

        [steps addObject:step];
    }

    ValhallaRoute *route      = [[ValhallaRoute alloc] init];
    route.totalDistanceMeters = totalKm * 1000.0;
    route.totalDurationSeconds = totalSec;
    route.encodedPolyline6    = legPolyline;
    route.steps               = [steps copy];
    route.rawJSON             = jsonString;

    return route;
}

@end
