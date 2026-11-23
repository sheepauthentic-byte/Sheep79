// language: Objective-C++, file: Tweak.mm, runtime: iOS ARM64, target: com.global.snmj.ios (v1.0.173)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

@interface XSamkokMenu : NSObject
@property (nonatomic, strong) UIButton *floatingBtn;
@property (nonatomic, strong) UIView *menuPanel;
@property (nonatomic, strong) UILabel *dmgLabel;
@property (nonatomic, strong) UILabel *spdLabel;
@property (nonatomic, strong) NSMutableDictionary *config;
@property (nonatomic, copy) NSString *configPath;
+ (instancetype)shared;
- (void)install;
@end

@implementation XSamkokMenu

+ (instancetype)shared {
    static XSamkokMenu *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[XSamkokMenu alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject;
        _configPath = [docDir stringByAppendingPathComponent:@"xsamkok_cfg.json"];
        _config = [@{
            @"dmgMult": @1,
            @"speedScale": @1.0,
            @"godMode": @NO,
            @"oneHitEnemy": @NO,
            @"autoSkip": @NO,
            @"autoPush": @NO,
            @"unlockSweep": @NO,
            @"unlockVip": @NO,
            @"openGMTrigger": @0
        } mutableCopy];
        [self saveConfig];
    }
    return self;
}

- (void)saveConfig {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.config options:0 error:&err];
    if (data && !err) {
        [data writeToFile:self.configPath atomically:YES];
    }
}

- (UIWindow *)activeWindow {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

- (void)install {
    UIWindow *win = [self activeWindow];
    if (!win || self.floatingBtn) return;

    self.floatingBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingBtn.frame = CGRectMake(20, 100, 52, 52);
    self.floatingBtn.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.12 alpha:0.92];
    self.floatingBtn.layer.cornerRadius = 26;
    self.floatingBtn.layer.borderWidth = 2.0;
    self.floatingBtn.layer.borderColor = [UIColor colorWithRed:0.0 green:0.95 blue:0.55 alpha:1.0].CGColor;
    [self.floatingBtn setTitle:@"MOD" forState:UIControlStateNormal];
    self.floatingBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [self.floatingBtn setTitleColor:[UIColor colorWithRed:0.0 green:0.95 blue:0.55 alpha:1.0] forState:UIControlStateNormal];
    [self.floatingBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.floatingBtn addGestureRecognizer:pan];
    [win addSubview:self.floatingBtn];

    CGFloat w = 300, h = 445;
    self.menuPanel = [[UIView alloc] initWithFrame:CGRectMake((win.bounds.size.width - w) / 2, (win.bounds.size.height - h) / 2, w, h)];
    self.menuPanel.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.11 alpha:0.95];
    self.menuPanel.layer.cornerRadius = 14;
    self.menuPanel.layer.borderWidth = 1.5;
    self.menuPanel.layer.borderColor = [UIColor colorWithRed:0.0 green:0.85 blue:0.5 alpha:0.85].CGColor;
    self.menuPanel.hidden = YES;
    [win addSubview:self.menuPanel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, w - 55, 24)];
    title.text = @"X-SAMKOK v1.0.173 | SHEEPCT";
    title.font = [UIFont boldSystemFontOfSize:13.5];
    title.textColor = [UIColor colorWithRed:0.0 green:0.95 blue:0.55 alpha:1.0];
    [self.menuPanel addSubview:title];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(w - 38, 8, 28, 28);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.menuPanel addSubview:closeBtn];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 42, w - 24, h - 52)];
    [self.menuPanel addSubview:scroll];

    CGFloat y = 4;

    self.dmgLabel = [[UILabel alloc] initWithFrame:CGRectMake(4, y, w - 32, 20)];
    self.dmgLabel.text = @"Nhân Sát Thương Phe Ta: 1x";
    self.dmgLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.dmgLabel.textColor = [UIColor whiteColor];
    [scroll addSubview:self.dmgLabel];
    y += 22;

    UISlider *dmgSlider = [[UISlider alloc] initWithFrame:CGRectMake(4, y, w - 32, 26)];
    dmgSlider.minimumValue = 1.0;
    dmgSlider.maximumValue = 100.0;
    dmgSlider.value = 1.0;
    dmgSlider.minimumTrackTintColor = [UIColor systemRedColor];
    [dmgSlider addTarget:self action:@selector(onDmgChanged:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:dmgSlider];
    y += 34;

    self.spdLabel = [[UILabel alloc] initWithFrame:CGRectMake(4, y, w - 32, 20)];
    self.spdLabel.text = @"Tốc Độ Trận & Game: 1.0x";
    self.spdLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.spdLabel.textColor = [UIColor whiteColor];
    [scroll addSubview:self.spdLabel];
    y += 22;

    UISlider *spdSlider = [[UISlider alloc] initWithFrame:CGRectMake(4, y, w - 32, 26)];
    spdSlider.minimumValue = 1.0;
    spdSlider.maximumValue = 8.0;
    spdSlider.value = 1.0;
    spdSlider.minimumTrackTintColor = [UIColor systemGreenColor];
    [spdSlider addTarget:self action:@selector(onSpdChanged:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:spdSlider];
    y += 38;

    NSArray *items = @[
        @{@"t": @"Bất Tử Phe Ta (God Mode)", @"k": @"godMode"},
        @{@"t": @"One-Hit Địch (1 Chạm Chết)", @"k": @"oneHitEnemy"},
        @{@"t": @"Auto Skip Trận Đấu (0s)", @"k": @"autoSkip"},
        @{@"t": @"Auto Leo Ải / Leo Tháp", @"k": @"autoPush"},
        @{@"t": @"Mở Khóa Càn Quét / Khiêu Chiến", @"k": @"unlockSweep"},
        @{@"t": @"VIP 15 & Đặc Quyền Client", @"k": @"unlockVip"}
    ];

    for (NSInteger i = 0; i < items.count; i++) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, w - 24, 36)];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        row.layer.cornerRadius = 8;

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, w - 90, 36)];
        lbl.text = items[i][@"t"];
        lbl.font = [UIFont systemFontOfSize:12.5];
        lbl.textColor = [UIColor colorWithWhite:0.93 alpha:1.0];
        [row addSubview:lbl];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(w - 82, 2.5, 51, 31)];
        sw.transform = CGAffineTransformMakeScale(0.8, 0.8);
        sw.tag = i;
        sw.accessibilityIdentifier = items[i][@"k"];
        sw.onTintColor = [UIColor colorWithRed:0.0 green:0.85 blue:0.5 alpha:1.0];
        [sw addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sw];

        [scroll addSubview:row];
        y += 42;
    }

    UIButton *gmBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    gmBtn.frame = CGRectMake(0, y + 4, w - 24, 38);
    gmBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.55 blue:0.1 alpha:1.0];
    gmBtn.layer.cornerRadius = 8;
    [gmBtn setTitle:@"MỞ / ẨN BẢNG GM (BCGMST)" forState:UIControlStateNormal];
    gmBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [gmBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [gmBtn addTarget:self action:@selector(onTapGM) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:gmBtn];
    y += 48;

    scroll.contentSize = CGSizeMake(w - 24, y);
}

- (void)togglePanel {
    self.menuPanel.hidden = !self.menuPanel.hidden;
}

- (void)onPan:(UIPanGestureRecognizer *)pan {
    UIWindow *win = [self activeWindow];
    CGPoint d = [pan translationInView:win];
    CGPoint c = self.floatingBtn.center;
    c.x = MAX(30, MIN(win.bounds.size.width - 30, c.x + d.x));
    c.y = MAX(40, MIN(win.bounds.size.height - 40, c.y + d.y));
    self.floatingBtn.center = c;
    [pan setTranslation:CGPointZero inView:win];
}

- (void)onDmgChanged:(UISlider *)s {
    int v = (int)roundf(s.value);
    self.dmgLabel.text = [NSString stringWithFormat:@"Nhân Sát Thương Phe Ta: %dx", v];
    self.config[@"dmgMult"] = @(v);
    [self saveConfig];
}

- (void)onSpdChanged:(UISlider *)s {
    float v = roundf(s.value * 2.0f) / 2.0f;
    self.spdLabel.text = [NSString stringWithFormat:@"Tốc Độ Trận & Game: %.1fx", v];
    self.config[@"speedScale"] = @(v);
    [self saveConfig];
}

- (void)onSwitch:(UISwitch *)sw {
    if (sw.accessibilityIdentifier) {
        self.config[sw.accessibilityIdentifier] = @(sw.isOn);
        [self saveConfig];
    }
}

- (void)onTapGM {
    NSInteger cur = [self.config[@"openGMTrigger"] integerValue];
    self.config[@"openGMTrigger"] = @(cur + 1);
    [self saveConfig];
}

@end

__attribute__((constructor))
static void InitDylib() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[XSamkokMenu shared] install];
    });
}
