#import <UIKit/UIKit.h>
#import "ESP32Protocol.h"

@interface ESP32VirtualHUDView : UIView

+ (instancetype)sharedHUD;
- (void)showInView:(UIView *)parentView;
- (void)hide;
- (void)updateWithManeuver:(NavManeuverIcon)maneuver
            distanceToTurn:(NSString *)distanceToTurn
              remainingEta:(NSString *)remainingEta
         remainingDistance:(NSString *)remainingDistance
                nextStreet:(NSString *)nextStreet
              currentSpeed:(NSInteger)currentSpeed
                speedLimit:(NSInteger)speedLimit;

- (void)updateMinimapImage:(UIImage *)image;

@end
