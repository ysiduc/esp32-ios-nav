//
//  ValhallaEngine.h
//  Pure Objective-C interface to the Valhalla C++ routing engine.
//  Swift calls this ObjC interface; C++ is hidden in ValhallaEngine.mm.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Represents a single navigation maneuver step returned by Valhalla.
@interface ValhallaStep : NSObject

/// Distance in meters from this step's start to the next maneuver.
@property (nonatomic, assign) double distanceMeters;
/// Estimated duration in seconds for this step.
@property (nonatomic, assign) double durationSeconds;
/// Street name(s) for this step (may be empty for unnamed roads).
@property (nonatomic, strong) NSString *streetName;
/// Valhalla maneuver type integer (0-35). See valhalla/proto/directions.proto.
@property (nonatomic, assign) NSInteger maneuverType;
/// Human-readable maneuver instruction in the requested language.
@property (nonatomic, strong) NSString *instruction;
/// Encoded polyline 6 (Valhalla uses precision 6) for this step's geometry.
@property (nonatomic, strong) NSString *encodedPolyline;
/// Begin shape index into the trip-level polyline.
@property (nonatomic, assign) NSInteger beginShapeIndex;
/// End shape index into the trip-level polyline.
@property (nonatomic, assign) NSInteger endShapeIndex;

@end

/// Full navigation route returned by Valhalla.
@interface ValhallaRoute : NSObject

/// Total route distance in meters.
@property (nonatomic, assign) double totalDistanceMeters;
/// Total estimated travel time in seconds.
@property (nonatomic, assign) double totalDurationSeconds;
/// Encoded polyline6 of the complete route geometry.
@property (nonatomic, strong) NSString *encodedPolyline6;
/// Ordered array of ValhallaStep objects.
@property (nonatomic, strong) NSArray<ValhallaStep *> *steps;
/// Raw JSON string returned by Valhalla (for debugging/logging).
@property (nonatomic, strong) NSString *rawJSON;

@end

/// Container for primary route and alternative routes returned by Valhalla.
@interface ValhallaRouteResult : NSObject

/// Primary / recommended route from Valhalla.
@property (nonatomic, strong) ValhallaRoute *primaryRoute;
/// Zero, one, or two alternative routes.
@property (nonatomic, strong) NSArray<ValhallaRoute *> *alternativeRoutes;
/// Convenience array containing primaryRoute followed by all alternative routes.
@property (nonatomic, readonly) NSArray<ValhallaRoute *> *allRoutes;

- (instancetype)initWithPrimaryRoute:(ValhallaRoute *)primary
                   alternativeRoutes:(nullable NSArray<ValhallaRoute *> *)alternatives;

@end

/// Errors the Valhalla engine can produce.
typedef NS_ENUM(NSInteger, ValhallaEngineError) {
    ValhallaEngineErrorConfigNotLoaded = 1001,
    ValhallaEngineErrorNoRouteFound    = 1002,
    ValhallaEngineErrorInvalidJSON     = 1003,
    ValhallaEngineErrorEngineException = 1004,
    ValhallaEngineErrorLibraryMissing  = 1005,
};

extern NSString *const ValhallaEngineErrorDomain;

/// Thread-safe singleton wrapper around valhalla::actor_t.
/// All heavy computation is dispatched to a dedicated serial background queue
/// so Swift callers can safely await from the main actor.
@interface ValhallaEngine : NSObject

/// Shared singleton instance (thread-safe Objective-C dispatch_once).
+ (instancetype)shared;
- (instancetype)init NS_UNAVAILABLE;

/// Returns YES if the Valhalla library is compiled and linked (not a stub).
/// Use this to show a "Routing unavailable" fallback UI if NO.
@property (nonatomic, readonly) BOOL isAvailable;

/// Load the Valhalla configuration JSON and initialise the actor.
/// @param configPath Absolute path to valhalla.json in the app bundle or Documents.
/// @param error Output error if loading fails.
/// @return YES on success.
- (BOOL)loadConfigAtPath:(NSString *)configPath error:(NSError **)error;

/// Compute routes given a pre-built structured JSON request.
- (nullable ValhallaRouteResult *)computeRoutesWithRequestJSON:(NSString *)requestJSON
                                                         error:(NSError **)error;

/// Compute routes given parameters (constructs structured JSON internally).
- (nullable ValhallaRouteResult *)computeRoutesFromLat:(double)fromLat
                                               fromLon:(double)fromLon
                                                 toLat:(double)toLat
                                                 toLon:(double)toLon
                                               costing:(NSString *)costing
                                        costingOptions:(nullable NSDictionary<NSString *, id> *)costingOptions
                                            alternates:(NSInteger)alternates
                                                 error:(NSError **)error;

/// Backward-compatible single route calculation (returns primary route).
- (nullable ValhallaRoute *)computeRouteFromLat:(double)fromLat
                                          fromLon:(double)fromLon
                                            toLat:(double)toLat
                                            toLon:(double)toLon
                                          costing:(NSString *)costing
                                            error:(NSError **)error;

/// Pure parser methods exposed for deterministic unit testing.
- (nullable ValhallaRouteResult *)parseValhallaJSONResult:(NSString *)jsonString
                                                    error:(NSError **)error;

- (nullable ValhallaRoute *)parseValhallaJSON:(NSString *)jsonString
                                        error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
