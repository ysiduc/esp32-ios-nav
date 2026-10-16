#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface WazeMapStreamServer : NSObject

+ (instancetype)sharedServer;
- (void)startServerOnPort:(uint16_t)port;
- (void)stopServer;
- (void)startMapCaptureWithView:(UIView *)mapView targetFps:(NSInteger)fps;
- (void)stopMapCapture;
- (void)broadcastJpegFrame:(NSData *)jpegData;

@end
