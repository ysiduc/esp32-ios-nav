#import "WazeMapStreamServer.h"
#import "ESP32VirtualHUDView.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>

static const char *WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

@interface WazeMapStreamServer () {
    int _serverFd;
    NSMutableArray<NSNumber *> *_clientFds;
    dispatch_queue_t _netQueue;
    CADisplayLink *_displayLink;
    __weak UIView *_targetMapView;
    NSInteger _fps;
    NSInteger _frameCount;
    BOOL _isCapturing;
}
@end

@implementation WazeMapStreamServer

+ (instancetype)sharedServer {
    static WazeMapStreamServer *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[WazeMapStreamServer alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverFd = -1;
        _clientFds = [NSMutableArray array];
        _netQueue = dispatch_queue_create("com.waze.esp32.mapstream", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startServerOnPort:(uint16_t)port {
    dispatch_async(_netQueue, ^{
        if (self->_serverFd >= 0) return;

        self->_serverFd = socket(AF_INET, SOCK_STREAM, 0);
        if (self->_serverFd < 0) {
            NSLog(@"[WazeMapStream] Socket creation failed");
            return;
        }

        int opt = 1;
        setsockopt(self->_serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port = htons(port);

        if (bind(self->_serverFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            NSLog(@"[WazeMapStream] Bind to port %d failed", port);
            close(self->_serverFd);
            self->_serverFd = -1;
            return;
        }

        if (listen(self->_serverFd, 4) < 0) {
            NSLog(@"[WazeMapStream] Listen failed");
            close(self->_serverFd);
            self->_serverFd = -1;
            return;
        }

        NSLog(@"[WazeMapStream] WebSocket Server listening on port %d", port);
        [self acceptLoop];
    });
}

- (void)acceptLoop {
    dispatch_async(_netQueue, ^{
        while (self->_serverFd >= 0) {
            struct sockaddr_in clientAddr;
            socklen_t clientLen = sizeof(clientAddr);
            int clientFd = accept(self->_serverFd, (struct sockaddr *)&clientAddr, &clientLen);
            if (clientFd < 0) break;

            NSLog(@"[WazeMapStream] New client connected fd=%d", clientFd);
            [self handleClientHandshake:clientFd];
        }
    });
}

- (void)handleClientHandshake:(int)clientFd {
    char buffer[2048];
    ssize_t n = recv(clientFd, buffer, sizeof(buffer) - 1, 0);
    if (n <= 0) {
        close(clientFd);
        return;
    }
    buffer[n] = '\0';
    NSString *req = [NSString stringWithUTF8String:buffer];

    // Find Sec-WebSocket-Key
    NSString *key = nil;
    NSArray *lines = [req componentsSeparatedByString:@"\r\n"];
    for (NSString *line in lines) {
        if ([line hasPrefix:@"Sec-WebSocket-Key:"]) {
            key = [[line substringFromIndex:18] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            break;
        }
    }

    if (key.length > 0) {
        NSString *combined = [key stringByAppendingString:[NSString stringWithUTF8String:WS_GUID]];
        NSData *combinedData = [combined dataUsingEncoding:NSUTF8StringEncoding];

        uint8_t digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(combinedData.bytes, (CC_LONG)combinedData.length, digest);

        NSData *shaData = [NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
        NSString *acceptKey = [shaData base64EncodedStringWithOptions:0];

        NSString *response = [NSString stringWithFormat:
            @"HTTP/1.1 101 Switching Protocols\r\n"
            @"Upgrade: websocket\r\n"
            @"Connection: Upgrade\r\n"
            @"Sec-WebSocket-Accept: %@\r\n\r\n", acceptKey];

        const char *respBytes = [response UTF8String];
        send(clientFd, respBytes, strlen(respBytes), 0);

        @synchronized (self->_clientFds) {
            [self->_clientFds addObject:@(clientFd)];
        }
        NSLog(@"[WazeMapStream] WebSocket Handshake successful for fd=%d", clientFd);
    } else {
        close(clientFd);
    }
}

- (void)stopServer {
    dispatch_async(_netQueue, ^{
        if (self->_serverFd >= 0) {
            close(self->_serverFd);
            self->_serverFd = -1;
        }
        @synchronized (self->_clientFds) {
            for (NSNumber *fdNum in self->_clientFds) {
                close([fdNum intValue]);
            }
            [self->_clientFds removeAllObjects];
        }
    });
}

#pragma mark - Map View Capture & JPEG Encoding

- (void)startMapCaptureWithView:(UIView *)mapView targetFps:(NSInteger)fps {
    if (!mapView) return;
    _targetMapView = mapView;
    _fps = (fps > 0 && fps <= 30) ? fps : 12;
    _frameCount = 0;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_displayLink) {
            [self->_displayLink invalidate];
        }
        self->_displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(captureFrame:)];
        [self->_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        self->_isCapturing = YES;
        NSLog(@"[WazeMapStream] Started map capture at %ld FPS", (long)self->_fps);
    });
}

- (void)stopMapCapture {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_displayLink) {
            [self->_displayLink invalidate];
            self->_displayLink = nil;
        }
        self->_isCapturing = NO;
    });
}

- (void)captureFrame:(CADisplayLink *)link {
    if (!_targetMapView || !_isCapturing) return;

    // Throttle 60Hz display link to target FPS
    NSInteger interval = 60 / _fps;
    if (++_frameCount % interval != 0) return;

    // Target ST7789 display crop: 154x280 (matching ESP32 firmware display_ui.h)
    CGSize targetSize = CGSizeMake(154, 280);
    CGRect viewBounds = _targetMapView.bounds;
    if (viewBounds.size.width <= 0 || viewBounds.size.height <= 0) return;

    CGRect cropRect = CGRectMake((viewBounds.size.width - targetSize.width) / 2.0,
                                 (viewBounds.size.height - targetSize.height) / 2.0,
                                 targetSize.width, targetSize.height);

    UIGraphicsBeginImageContextWithOptions(targetSize, YES, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextTranslateCTM(ctx, -cropRect.origin.x, -cropRect.origin.y);
        [_targetMapView drawViewHierarchyInRect:viewBounds afterScreenUpdates:NO];
        UIImage *cropped = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (cropped) {
            // 1. Update Minimap thumbnail on Virtual HUD
            [[ESP32VirtualHUDView sharedHUD] updateMinimapImage:cropped];

            // 2. Compress to JPEG (Quality 0.35 -> ~4KB) and stream to ESP32
            NSData *jpegData = UIImageJPEGRepresentation(cropped, 0.35);
            if (jpegData.length > 0) {
                [self broadcastJpegFrame:jpegData];
            }
        }
    } else {
        UIGraphicsEndImageContext();
    }
}

#pragma mark - WebSocket Binary Frame Broadcasting

- (void)broadcastJpegFrame:(NSData *)jpegData {
    if (jpegData.length == 0) return;

    dispatch_async(_netQueue, ^{
        @synchronized (self->_clientFds) {
            if (self->_clientFds.count == 0) return;

            // Construct RFC 6455 Binary Frame (Opcode 0x02, FIN bit set = 0x82)
            NSMutableData *frame = [NSMutableData data];
            uint8_t b1 = 0x82; // FIN + Binary Frame
            [frame appendBytes:&b1 length:1];

            size_t payloadLen = jpegData.length;
            if (payloadLen <= 125) {
                uint8_t b2 = (uint8_t)payloadLen;
                [frame appendBytes:&b2 length:1];
            } else if (payloadLen <= 65535) {
                uint8_t b2 = 126;
                uint16_t len16 = htons((uint16_t)payloadLen);
                [frame appendBytes:&b2 length:1];
                [frame appendBytes:&len16 length:2];
            } else {
                uint8_t b2 = 127;
                uint64_t len64 = CFSwapInt64HostToBig((uint64_t)payloadLen);
                [frame appendBytes:&b2 length:1];
                [frame appendBytes:&len64 length:8];
            }
            [frame appendData:jpegData];

            NSMutableArray<NSNumber *> *deadClients = [NSMutableArray array];
            for (NSNumber *fdNum in self->_clientFds) {
                int cFd = [fdNum intValue];
                ssize_t sent = send(cFd, frame.bytes, frame.length, MSG_NOSIGNAL);
                if (sent <= 0) {
                    [deadClients addObject:fdNum];
                    close(cFd);
                }
            }
            [self->_clientFds removeObjectsInArray:deadClients];
        }
    });
}

@end
