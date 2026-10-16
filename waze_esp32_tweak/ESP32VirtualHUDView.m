#import "ESP32VirtualHUDView.h"
#import "ESP32BLEManager.h"

@interface ESP32VirtualHUDView ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusBadge;
@property (nonatomic, strong) UILabel *maneuverIconLabel;
@property (nonatomic, strong) UILabel *distToTurnLabel;
@property (nonatomic, strong) UILabel *streetLabel;
@property (nonatomic, strong) UILabel *speedLabel;
@property (nonatomic, strong) UIView *speedLimitCircle;
@property (nonatomic, strong) UILabel *speedLimitLabel;
@property (nonatomic, strong) UILabel *etaLabel;
@property (nonatomic, strong) UILabel *remDistLabel;
@property (nonatomic, strong) UIImageView *minimapView;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, assign) BOOL isMinimized;
@end

@implementation ESP32VirtualHUDView

+ (instancetype)sharedHUD {
    static ESP32VirtualHUDView *hud;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hud = [[ESP32VirtualHUDView alloc] initWithFrame:CGRectMake(20, 100, 320, 190)];
    });
    return hud;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
        [self setupGestures];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onBLEStatusChanged:)
                                                     name:kESP32BLEStatusChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    self.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.11 alpha:0.92];
    self.layer.cornerRadius = 16.0;
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = [UIColor colorWithRed:0.25 green:0.75 blue:1.0 alpha:0.6].CGColor;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 8);
    self.layer.shadowOpacity = 0.5;
    self.layer.shadowRadius = 12.0;
    self.clipsToBounds = YES;

    // Title / Brand
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 150, 20)];
    _titleLabel.text = @"ESP32 HUD SIMULATOR";
    _titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    _titleLabel.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0];
    [self addSubview:_titleLabel];

    // Status Badge
    _statusBadge = [[UILabel alloc] initWithFrame:CGRectMake(170, 10, 115, 20)];
    _statusBadge.text = @"● BLE: SCANNING";
    _statusBadge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    _statusBadge.textColor = [UIColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:1.0];
    _statusBadge.textAlignment = NSTextAlignmentRight;
    [self addSubview:_statusBadge];

    // Close / Minimize Button
    _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _closeButton.frame = CGRectMake(290, 8, 24, 24);
    [_closeButton setTitle:@"✕" forState:UIControlStateNormal];
    _closeButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [_closeButton setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    [_closeButton addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_closeButton];

    // Maneuver Icon
    _maneuverIconLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 38, 48, 48)];
    _maneuverIconLabel.text = @"🧭";
    _maneuverIconLabel.font = [UIFont systemFontOfSize:36];
    _maneuverIconLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_maneuverIconLabel];

    // Distance to turn
    _distToTurnLabel = [[UILabel alloc] initWithFrame:CGRectMake(70, 36, 120, 28)];
    _distToTurnLabel.text = @"-- m";
    _distToTurnLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightHeavy];
    _distToTurnLabel.textColor = [UIColor whiteColor];
    [self addSubview:_distToTurnLabel];

    // Next Street Name
    _streetLabel = [[UILabel alloc] initWithFrame:CGRectMake(70, 64, 140, 22)];
    _streetLabel.text = @"Sẵn sàng điều hướng...";
    _streetLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _streetLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    _streetLabel.numberOfLines = 1;
    [self addSubview:_streetLabel];

    // Minimap Preview (right side)
    _minimapView = [[UIImageView alloc] initWithFrame:CGRectMake(220, 36, 88, 88)];
    _minimapView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    _minimapView.layer.cornerRadius = 8.0;
    _minimapView.layer.borderWidth = 1.0;
    _minimapView.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    _minimapView.clipsToBounds = YES;
    _minimapView.contentMode = UIViewContentModeScaleAspectFill;
    [self addSubview:_minimapView];

    // Speedometer section (bottom)
    _speedLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 130, 80, 48)];
    _speedLabel.text = @"0";
    _speedLabel.font = [UIFont systemFontOfSize:38 weight:UIFontWeightHeavy];
    _speedLabel.textColor = [UIColor whiteColor];
    [self addSubview:_speedLabel];

    UILabel *kmhLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 168, 50, 16)];
    kmhLabel.text = @"km/h";
    kmhLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    kmhLabel.textColor = [UIColor grayColor];
    [self addSubview:kmhLabel];

    // Speed Limit Circle (European/VN standard: white background, red ring)
    _speedLimitCircle = [[UIView alloc] initWithFrame:CGRectMake(85, 136, 36, 36)];
    _speedLimitCircle.backgroundColor = [UIColor whiteColor];
    _speedLimitCircle.layer.cornerRadius = 18.0;
    _speedLimitCircle.layer.borderWidth = 3.5;
    _speedLimitCircle.layer.borderColor = [UIColor redColor].CGColor;
    _speedLimitCircle.clipsToBounds = YES;

    _speedLimitLabel = [[UILabel alloc] initWithFrame:_speedLimitCircle.bounds];
    _speedLimitLabel.text = @"--";
    _speedLimitLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightHeavy];
    _speedLimitLabel.textColor = [UIColor blackColor];
    _speedLimitLabel.textAlignment = NSTextAlignmentCenter;
    [_speedLimitCircle addSubview:_speedLimitLabel];
    [self addSubview:_speedLimitCircle];

    // ETA & Total Distance Info
    _etaLabel = [[UILabel alloc] initWithFrame:CGRectMake(135, 134, 170, 20)];
    _etaLabel.text = @"ETA: --:--";
    _etaLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    _etaLabel.textColor = [UIColor colorWithRed:0.3 green:0.85 blue:0.5 alpha:1.0];
    [self addSubview:_etaLabel];

    _remDistLabel = [[UILabel alloc] initWithFrame:CGRectMake(135, 154, 170, 18)];
    _remDistLabel.text = @"Còn lại: -- km";
    _remDistLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _remDistLabel.textColor = [UIColor lightGrayColor];
    [self addSubview:_remDistLabel];
}

- (void)setupGestures {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:self.superview];
}

- (void)showInView:(UIView *)parentView {
    if (!self.superview) {
        [parentView addSubview:self];
        self.alpha = 0.0;
        [UIView animateWithDuration:0.3 animations:^{
            self.alpha = 1.0;
        }];
    }
}

- (void)hide {
    [UIView animateWithDuration:0.25 animations:^{
        self.alpha = 0.0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}

- (void)onBLEStatusChanged:(NSNotification *)note {
    ESP32BLEManager *ble = [ESP32BLEManager shared];
    if (ble.isConnected) {
        self.statusBadge.text = @"● BLE: CONNECTED";
        self.statusBadge.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1.0];
    } else {
        self.statusBadge.text = @"● BLE: DISCONNECTED";
        self.statusBadge.textColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0];
    }
}

- (void)updateWithManeuver:(NavManeuverIcon)maneuver
            distanceToTurn:(NSString *)distanceToTurn
              remainingEta:(NSString *)remainingEta
         remainingDistance:(NSString *)remainingDistance
                nextStreet:(NSString *)nextStreet
              currentSpeed:(NSInteger)currentSpeed
                speedLimit:(NSInteger)speedLimit {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.distToTurnLabel.text = distanceToTurn ?: @"--";
        self.streetLabel.text = nextStreet ?: @"Đang chạy...";
        self.etaLabel.text = [NSString stringWithFormat:@"ETA: %@", remainingEta ?: @"--:--"];
        self.remDistLabel.text = [NSString stringWithFormat:@"Còn lại: %@", remainingDistance ?: @"-- km"];
        self.speedLabel.text = [NSString stringWithFormat:@"%ld", (long)currentSpeed];
        
        if (speedLimit > 0) {
            self.speedLimitLabel.text = [NSString stringWithFormat:@"%ld", (long)speedLimit];
            self.speedLimitCircle.hidden = NO;
            // Cảnh báo nếu vượt quá tốc độ
            if (currentSpeed > speedLimit) {
                self.speedLabel.textColor = [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:1.0];
            } else {
                self.speedLabel.textColor = [UIColor whiteColor];
            }
        } else {
            self.speedLimitCircle.hidden = YES;
            self.speedLabel.textColor = [UIColor whiteColor];
        }

        // Maneuver Icons
        switch (maneuver) {
            case MANEUVER_STRAIGHT:      self.maneuverIconLabel.text = @"⬆️"; break;
            case MANEUVER_SLIGHT_RIGHT:  self.maneuverIconLabel.text = @"↗️"; break;
            case MANEUVER_RIGHT:         self.maneuverIconLabel.text = @"➡️"; break;
            case MANEUVER_SHARP_RIGHT:   self.maneuverIconLabel.text = @"⤴️"; break;
            case MANEUVER_UTURN:         self.maneuverIconLabel.text = @"↩️"; break;
            case MANEUVER_LEFT:          self.maneuverIconLabel.text = @"⬅️"; break;
            case MANEUVER_ROUNDABOUT:    self.maneuverIconLabel.text = @"🔄"; break;
            case MANEUVER_ARRIVE:        self.maneuverIconLabel.text = @"🏁"; break;
            default:                     self.maneuverIconLabel.text = @"🧭"; break;
        }
    });
}

- (void)updateMinimapImage:(UIImage *)image {
    if (!image) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.minimapView.image = image;
    });
}

@end
