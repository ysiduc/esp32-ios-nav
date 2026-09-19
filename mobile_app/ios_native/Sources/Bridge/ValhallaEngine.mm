//
//  ValhallaEngine.mm
//  Objective-C++ implementation wrapping valhalla::actor_t.
//
//  --- HOW TO ENABLE REAL VALHALLA ---
//  1. Build libvalhalla.a + all dependencies for iOS arm64:
//       https://github.com/valhalla/valhalla/blob/master/docs/building.md
//     Or use the pre-built package:
//       https://github.com/gis-ops/valhalla-ios-prebuilt (if available)
//  2. In Xcode: Build Phases → Link Binary With Libraries → add libvalhalla.a
//  3. Add valhalla headers to HEADER_SEARCH_PATHS
//  4. Replace the #if VALHALLA_AVAILABLE block stubs with real implementation
//
//  Currently this file ships as a STUB that returns a fake JSON skeleton.
//  This allows the Swift codebase to compile and be tested end-to-end;
//  replace the stub bodies when the .a library is ready.
//

#import "ValhallaEngine.h"
#import <Foundation/Foundation.h>

// Toggle this to 1 once libvalhalla.a is linked:
#define VALHALLA_AVAILABLE 0

#if VALHALLA_AVAILABLE
// Real includes when library is linked:
#include <valhalla/tyr/actor.h>
#include <valhalla/midgard/encoded.h>
#include <valhalla/baldr/graphreader.h>
#include <boost/property_tree/json_parser.hpp>
#include <boost/property_tree/ptree.hpp>
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
// Stored as void* to avoid exposing C++ type to ObjC callers.
// Cast back to valhalla::tyr::actor_t* when needed.
@property (nonatomic, assign) void *actorPtr;
#endif

@end

// ---------------------------------------------------------------------------
// MARK: - ValhallaEngine Implementation
// ---------------------------------------------------------------------------

@implementation ValhallaEngine {
#if VALHALLA_AVAILABLE
    valhalla::tyr::actor_t *_actor;
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
            std::string path = [configPath UTF8String];
            boost::property_tree::ptree pt;
            boost::property_tree::json_parser::read_json(path, pt);

            // Deallocate previous actor if reloading
            if (_actor) {
                delete _actor;
                _actor = nullptr;
            }

            _actor = new valhalla::tyr::actor_t(pt, true);
            self.configLoaded = YES;
            success = YES;
        } catch (const std::exception &e) {
            loadError = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                           code:ValhallaEngineErrorEngineException
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                      [NSString stringWithUTF8String:e.what()]}];
        }
    });

    if (error) *error = loadError;
    return success;

#else
    // STUB: mark as loaded so route requests can return fake data for UI testing
    NSLog(@"[ValhallaEngine] STUB mode — loadConfig pretending success. Link libvalhalla.a for real routing.");
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
        try {
            // Build Valhalla JSON request
            NSString *requestJSON = [NSString stringWithFormat:
                @"{\"locations\":[{\"lon\":%.7f,\"lat\":%.7f},{\"lon\":%.7f,\"lat\":%.7f}],"
                @"\"costing\":\"%@\","
                @"\"directions_options\":{\"language\":\"vi\",\"units\":\"kilometers\","
                @"\"narrative\":true},\"format\":\"json\"}",
                fromLon, fromLat, toLon, toLat, costing];

            std::string req([requestJSON UTF8String]);
            std::string resp = _actor->route(req);

            NSString *jsonString = [NSString stringWithUTF8String:resp.c_str()];
            result = [self parseValhallaJSON:jsonString error:&routeError];

        } catch (const std::exception &e) {
            routeError = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                             code:ValhallaEngineErrorEngineException
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithUTF8String:e.what()]}];
        }
    });

    if (error) *error = routeError;
    return result;

#else
    // -----------------------------------------------------------------------
    // STUB IMPLEMENTATION
    // Returns a tiny fake route with 2 straight steps so the navigation HUD
    // can be visually tested before libvalhalla.a is integrated.
    // -----------------------------------------------------------------------
    NSLog(@"[ValhallaEngine] STUB — returning fake route from (%.4f,%.4f) to (%.4f,%.4f)",
          fromLat, fromLon, toLat, toLon);

    // Build a fake straight-line 2-step route between origin and destination.
    // Mid-point is the only turn.
    double midLat = (fromLat + toLat) / 2.0;
    double midLon = (fromLon + toLon) / 2.0;

    // Approximate distance using simple haversine approximation (metres)
    double dlat = (toLat - fromLat) * 111319.9;
    double dlon = (toLon - fromLon) * 111319.9 * cos(fromLat * M_PI / 180.0);
    double totalMeters = sqrt(dlat * dlat + dlon * dlon);

    // Step 1: straight to midpoint
    ValhallaStep *step1 = [[ValhallaStep alloc] init];
    step1.distanceMeters  = totalMeters / 2.0;
    step1.durationSeconds = (totalMeters / 2.0) / 10.0; // ~36km/h
    step1.streetName      = @"Đường Thẳng";
    step1.maneuverType    = 1; // kManeuverTypeStart
    step1.instruction     = @"Đi thẳng";
    step1.beginShapeIndex = 0;
    step1.endShapeIndex   = 1;

    // Step 2: arrive at destination
    ValhallaStep *step2 = [[ValhallaStep alloc] init];
    step2.distanceMeters  = totalMeters / 2.0;
    step2.durationSeconds = (totalMeters / 2.0) / 10.0;
    step2.streetName      = @"";
    step2.maneuverType    = 6; // kManeuverTypeDestination
    step2.instruction     = @"Đến đích";
    step2.beginShapeIndex = 1;
    step2.endShapeIndex   = 2;

    // Simple 3-point encoded polyline6: origin → mid → dest
    // We skip actual polyline6 encoding in stub; ValhallaWrapper uses raw coords instead.
    step1.encodedPolyline = @""; // handled in ValhallaWrapper stub path
    step2.encodedPolyline = @"";

    NSString *fakeJSON = [NSString stringWithFormat:
        @"{\"trip\":{\"summary\":{\"length\":%.4f,\"time\":%.1f},\"legs\":[{\"summary\":{\"length\":%.4f,\"time\":%.1f},\"maneuvers\":[]}]}}",
        totalMeters / 1000.0, totalMeters / 10.0,
        totalMeters / 1000.0, totalMeters / 10.0];

    ValhallaRoute *route          = [[ValhallaRoute alloc] init];
    route.totalDistanceMeters     = totalMeters;
    route.totalDurationSeconds    = totalMeters / 10.0; // ~36 km/h average
    route.encodedPolyline6        = @"";
    route.steps                   = @[step1, step2];
    route.rawJSON                 = fakeJSON;

    // Attach raw coordinates as a JSON array for ValhallaWrapper to decode
    // (since we skip real polyline6 encoding in the stub)
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

/// Parses the standard Valhalla JSON route response into a ValhallaRoute object.
/// See: https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/#outputs-of-a-route
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

    // Check for Valhalla error response (status != 0)
    NSDictionary *trip = root[@"trip"];
    if (!trip) {
        NSDictionary *routeError = root[@"error"];
        NSString *msg = routeError[@"message"] ?: @"No route found";
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

    // Legs → maneuvers (Valhalla puts all steps in leg 0 for a single-leg route)
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
        step.distanceMeters  = [m[@"length"] doubleValue] * 1000.0; // km → metres
        step.durationSeconds = [m[@"time"]   doubleValue];
        step.maneuverType    = [m[@"type"]   integerValue];
        step.instruction     = m[@"instruction"] ?: @"";
        step.beginShapeIndex = [m[@"begin_shape_index"] integerValue];
        step.endShapeIndex   = [m[@"end_shape_index"]   integerValue];

        // Street name: first street_names entry, or sign->exit_toward_elements
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
