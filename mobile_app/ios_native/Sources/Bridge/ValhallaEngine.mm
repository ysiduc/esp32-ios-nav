//
//  ValhallaEngine.mm
//  Objective-C++ implementation wrapping valhalla::actor_t via valhalla-wrapper.
//

#import "ValhallaEngine.h"
#import <Foundation/Foundation.h>

// Valhalla is compiled and linked via valhalla-wrapper.xcframework (libvalhalla_all.a)
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
// MARK: - ValhallaRouteResult
// ---------------------------------------------------------------------------

@implementation ValhallaRouteResult

- (instancetype)initWithPrimaryRoute:(ValhallaRoute *)primary
                   alternativeRoutes:(nullable NSArray<ValhallaRoute *> *)alternatives {
    self = [super init];
    if (self) {
        _primaryRoute = primary;
        _alternativeRoutes = alternatives ?: @[];
    }
    return self;
}

- (NSArray<ValhallaRoute *> *)allRoutes {
    NSMutableArray *all = [NSMutableArray arrayWithCapacity:1 + _alternativeRoutes.count];
    if (_primaryRoute) {
        [all addObject:_primaryRoute];
    }
    [all addObjectsFromArray:_alternativeRoutes];
    return [all copy];
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
        if (_actor) {
            delete_valhalla_actor(_actor);
            _actor = nullptr;
        }

        try {
            _actor = create_valhalla_actor([configPath UTF8String], nullptr);
            if (_actor) {
                self.configLoaded = YES;
                success = YES;
                NSLog(@"[ValhallaEngine] ✅ Actor created from: %@", configPath);
            } else {
                loadError = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                               code:ValhallaEngineErrorConfigNotLoaded
                                           userInfo:@{NSLocalizedDescriptionKey: @"create_valhalla_actor returned null"}];
                NSLog(@"[ValhallaEngine] ❌ Failed to create actor");
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
    NSLog(@"[ValhallaEngine] Library missing — loadConfig returning error.");
    if (error) {
        *error = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                     code:ValhallaEngineErrorLibraryMissing
                                 userInfo:@{NSLocalizedDescriptionKey: @"Valhalla C++ library is not compiled or available."}];
    }
    self.configLoaded = NO;
    return NO;
#endif
}

- (nullable ValhallaRouteResult *)computeRoutesWithRequestJSON:(NSString *)requestJSON
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
    __block ValhallaRouteResult *result = nil;
    __block NSError *routeError  = nil;

    dispatch_sync(self.queue, ^{
        if (!_actor) {
            routeError = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                             code:ValhallaEngineErrorConfigNotLoaded
                                         userInfo:@{NSLocalizedDescriptionKey: @"Valhalla actor is null."}];
            return;
        }

        try {
            std::string req([requestJSON UTF8String]);
            std::string resp = route(req.c_str(), _actor);

            NSString *jsonString = [NSString stringWithUTF8String:resp.c_str()];
            result = [self parseValhallaJSONResult:jsonString error:&routeError];

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
    NSLog(@"[ValhallaEngine] Unavailable — Valhalla C++ library not compiled. Returning explicit error.");
    if (error) {
        *error = [NSError errorWithDomain:ValhallaEngineErrorDomain
                                     code:ValhallaEngineErrorLibraryMissing
                                 userInfo:@{NSLocalizedDescriptionKey: @"Valhalla C++ library is not compiled or available"}];
    }
    return nil;
#endif
}

- (nullable ValhallaRouteResult *)computeRoutesFromLat:(double)fromLat
                                               fromLon:(double)fromLon
                                                 toLat:(double)toLat
                                                 toLon:(double)toLon
                                               costing:(NSString *)costing
                                        costingOptions:(nullable NSDictionary<NSString *, id> *)costingOptions
                                            alternates:(NSInteger)alternates
                                                 error:(NSError **)error {
    NSMutableDictionary *req = [NSMutableDictionary dictionary];
    req[@"locations"] = @[
        @{@"lon": @(fromLon), @"lat": @(fromLat)},
        @{@"lon": @(toLon), @"lat": @(toLat)}
    ];
    req[@"costing"] = costing ?: @"motorcycle";
    req[@"directions_options"] = @{
        @"language": @"vi",
        @"units": @"kilometers",
        @"narrative": @YES
    };
    req[@"format"] = @"json";

    if (alternates > 0) {
        req[@"alternates"] = @(alternates);
    }

    if (costingOptions && costingOptions.count > 0) {
        req[@"costing_options"] = @{
            costing ?: @"motorcycle": costingOptions
        };
    }

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:req options:0 error:&jsonError];
    if (!data || jsonError) {
        if (error) *error = jsonError;
        return nil;
    }

    NSString *requestJSON = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [self computeRoutesWithRequestJSON:requestJSON error:error];
}

- (nullable ValhallaRoute *)computeRouteFromLat:(double)fromLat
                                          fromLon:(double)fromLon
                                            toLat:(double)toLat
                                            toLon:(double)toLon
                                          costing:(NSString *)costing
                                            error:(NSError **)error {
    ValhallaRouteResult *res = [self computeRoutesFromLat:fromLat
                                                  fromLon:fromLon
                                                    toLat:toLat
                                                    toLon:toLon
                                                  costing:costing
                                           costingOptions:nil
                                               alternates:0
                                                    error:error];
    return res.primaryRoute;
}

// ---------------------------------------------------------------------------
// MARK: - JSON Parsers
// ---------------------------------------------------------------------------

- (nullable ValhallaRoute *)parseValhallaJSON:(NSString *)jsonString
                                        error:(NSError **)error {
    ValhallaRouteResult *res = [self parseValhallaJSONResult:jsonString error:error];
    return res.primaryRoute;
}

- (nullable ValhallaRouteResult *)parseValhallaJSONResult:(NSString *)jsonString
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

    NSDictionary *primaryTrip = root[@"trip"];
    if (!primaryTrip) {
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

    ValhallaRoute *primaryRoute = [self parseSingleTrip:primaryTrip rawJSON:jsonString error:error];
    if (!primaryRoute) {
        return nil;
    }

    NSMutableArray<ValhallaRoute *> *altRoutes = [NSMutableArray array];
    NSArray *rawAlternates = root[@"alternates"];
    if ([rawAlternates isKindOfClass:[NSArray class]]) {
        for (id altItem in rawAlternates) {
            NSDictionary *altTrip = nil;
            if ([altItem isKindOfClass:[NSDictionary class]]) {
                if (altItem[@"trip"] && [altItem[@"trip"] isKindOfClass:[NSDictionary class]]) {
                    altTrip = altItem[@"trip"];
                } else {
                    altTrip = altItem;
                }
            }
            if (altTrip) {
                ValhallaRoute *altRoute = [self parseSingleTrip:altTrip rawJSON:@"" error:nil];
                if (altRoute) {
                    [altRoutes addObject:altRoute];
                }
            }
        }
    }

    return [[ValhallaRouteResult alloc] initWithPrimaryRoute:primaryRoute
                                           alternativeRoutes:[altRoutes copy]];
}

- (nullable ValhallaRoute *)parseSingleTrip:(NSDictionary *)trip
                                    rawJSON:(NSString *)rawJSON
                                      error:(NSError **)error {
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

    // P4 turn-by-turn routes are origin + destination single-leg navigation paths.
    // If multiple legs are present, leg0 is the primary navigation leg.
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
    route.rawJSON             = rawJSON;

    return route;
}

@end
