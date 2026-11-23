#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>
#include "dobby.h"

// Payload JS can thiệp thẳng vào Cocos Creator 3.x khi engine nạp script
static const char* kCocosModJS = R"JS(
;(function() {
    if (window.__xs_dobby_injected) return;
    window.__xs_dobby_injected = true;

    window.__modCfg = {
        dmgMult: 1,
        speedScale: 1.0,
        godMode: false,
        oneHitEnemy: false,
        autoSkip: false,
        autoPush: false,
        unlockSweep: false,
        unlockVip: false,
        openGMTrigger: 0
    };
    let lastGM = 0;

    const syncCfg = () => {
        try {
            if (typeof jsb !== 'undefined' && jsb.fileUtils) {
                const p = jsb.fileUtils.getWritablePath() + 'xsamkok_cfg.json';
                if (jsb.fileUtils.isFileExist(p)) {
                    const s = jsb.fileUtils.getStringFromFile(p);
                    if (s) {
                        Object.assign(window.__modCfg, JSON.parse(s));
                        if (window.__modCfg.openGMTrigger !== lastGM) {
                            lastGM = window.__modCfg.openGMTrigger;
                            openOfficialGM();
                        }
                    }
                }
            }
        } catch (e) {}
    };

    const isAlly = (u) => {
        if (!u || typeof u !== 'object') return false;
        if (typeof u.isEnemy === 'boolean') return !u.isEnemy;
        if (typeof u.isSelf === 'boolean') return u.isSelf;
        if (typeof u.camp === 'number') return u.camp === 1;
        if (typeof u.side === 'number') return u.side === 1 || u.side === 0;
        if (typeof u.team === 'number') return u.team === 1 || u.team === 0;
        if (u.node && u.node.position) return u.node.position.x < 0;
        return false;
    };

    const wrapHp = (unit) => {
        if (!unit || typeof unit !== 'object' || unit.__hp_w) return;
        unit.__hp_w = true;
        for (const k of Object.keys(unit)) {
            if (!/^(cur)?_?hp$/i.test(k) && !/blood/i.test(k)) continue;
            if (typeof unit[k] !== 'number') continue;
            let v = unit[k];
            try {
                Object.defineProperty(unit, k, {
                    configurable: true,
                    enumerable: true,
                    get: () => v,
                    set: (nv) => {
                        const ally = isAlly(unit);
                        if (ally) {
                            if (window.__modCfg.godMode && nv < v) return;
                        } else {
                            if (window.__modCfg.oneHitEnemy && nv < v) { v = 0; return; }
                            if (window.__modCfg.dmgMult > 1 && nv < v) {
                                const nxt = v - (v - nv) * window.__modCfg.dmgMult;
                                v = nxt < 0 ? 0 : nxt;
                                return;
                            }
                        }
                        v = nv;
                    }
                });
            } catch (e) {}
        }
    };

    const patchMod = (name, exp) => {
        if (!exp || typeof exp !== 'object') return;
        const targets = ['enemybase.ts', 'armyctrl.ts', 'warctrl.ts', 'warjsctrl.ts', 'armymdl.ts', 'heromdl.ts', 'towerctrl.ts', 'slfbctrl.ts'];
        if (targets.some(t => name.endsWith('/' + t))) {
            for (const k of Object.keys(exp)) {
                const cls = exp[k];
                if (typeof cls !== 'function' || !cls.prototype || cls.prototype.__p) continue;
                const proto = cls.prototype;
                proto.__p = true;
                for (const m of Object.getOwnPropertyNames(proto)) {
                    if (m === 'constructor' || typeof proto[m] !== 'function') continue;
                    const orig = proto[m];
                    proto[m] = function(...args) {
                        wrapHp(this);
                        for (let i = 0; i < args.length; i++) {
                            if (args[i] && typeof args[i] === 'object') {
                                if (Array.isArray(args[i])) args[i].forEach(wrapHp);
                                else wrapHp(args[i]);
                            }
                        }
                        if (args.length >= 1 && typeof args[0] === 'number' && args[0] !== 0) {
                            if (/hurt|damage|hit|atk|subHp|changeHp|kouXue|shanghai/i.test(m)) {
                                const ally = isAlly(this);
                                if (ally && window.__modCfg.godMode) return 0;
                                if (!ally) {
                                    if (window.__modCfg.oneHitEnemy) args[0] = args[0] < 0 ? -999999999 : 999999999;
                                    else if (window.__modCfg.dmgMult > 1) args[0] *= window.__modCfg.dmgMult;
                                }
                            }
                        }
                        return orig.apply(this, args);
                    };
                }
            }
        }
        if (name.endsWith('/privilegemdl.ts')) {
            for (const k of Object.keys(exp)) {
                const proto = exp[k]?.prototype || exp[k];
                if (!proto || proto.__v) continue;
                proto.__v = true;
                for (const fn of Object.getOwnPropertyNames(proto)) {
                    if (/isOpen|hasPriv|isActive|checkCard|isBuy/i.test(fn) && typeof proto[fn] === 'function') {
                        const orig = proto[fn];
                        proto[fn] = function(...args) { return window.__modCfg.unlockVip ? true : orig.apply(this, args); };
                    }
                }
            }
        }
        if (name.endsWith('/playermdl.ts') && exp.Bc1cPlayerM) {
            const proto = exp.Bc1cPlayerM.prototype;
            if (proto && !proto.__v) {
                proto.__v = true;
                for (const fn of Object.getOwnPropertyNames(proto)) {
                    if (/getVip|vipLv/i.test(fn) && typeof proto[fn] === 'function') {
                        const orig = proto[fn];
                        proto[fn] = function(...args) {
                            const val = orig.apply(this, args);
                            return window.__modCfg.unlockVip ? Math.max(val || 0, 15) : val;
                        };
                    }
                }
            }
        }
    };

    const hookSystem = () => {
        if (typeof System === 'undefined' || !System.register) {
            setTimeout(hookSystem, 10);
            return;
        }
        if (System.__hk) return;
        System.__hk = true;
        const origReg = System.register.bind(System);
        System.register = function(name, deps, declare) {
            if (typeof name === 'string') {
                if (name.endsWith('/env')) {
                    const origDec = declare;
                    declare = function(_e, _c) {
                        return origDec((k, v) => _e(k, (k === 'DEBUG' || k === 'DEV') ? true : v), _c);
                    };
                }
                const origDec = declare;
                declare = function(_e, _c) {
                    const cap = {};
                    const pExp = (k, v) => {
                        if (typeof k === 'string') cap[k] = v;
                        else if (k && typeof k === 'object') Object.assign(cap, k);
                        return _e(k, v);
                    };
                    const res = origDec(pExp, _c);
                    if (res && typeof res.execute === 'function') {
                        const origEx = res.execute.bind(res);
                        res.execute = function() {
                            const r = origEx();
                            patchMod(name, cap);
                            return r;
                        };
                    }
                    return res;
                };
            }
            return origReg(name, deps, declare);
        };
    };
    hookSystem();

    const openOfficialGM = () => {
        if (typeof cc === 'undefined' || !cc.assetManager) return;
        cc.assetManager.loadBundle('bcgmst', (err, b) => {
            if (err || !b) return;
            b.loadDir('', cc.Prefab, (e2, p) => {
                if (e2 || !p || !p.length) return;
                const sc = cc.director.getScene();
                const cv = sc && sc.getChildByName('Canvas');
                if (!cv) return;
                const old = cv.getChildByName('__GMNode');
                if (old) { old.active = !old.active; return; }
                const n = cc.instantiate(p[0]);
                n.name = '__GMNode';
                n.zIndex = 9999;
                cv.addChild(n);
            });
        });
    };

    setInterval(() => {
        syncCfg();
        if (typeof cc !== 'undefined' && cc.director) {
            const sch = cc.director.getScheduler();
            if (sch && !sch.__s) {
                sch.__s = true;
                const origU = sch.update.bind(sch);
                sch.update = function(dt) { origU(dt * window.__modCfg.speedScale); };
            }
            const sc = cc.director.getScene();
            const cv = sc && sc.getChildByName('Canvas');
            if (cv) {
                const walk = (n) => {
                    if (!n) return;
                    const nm = (n.name || '').toLowerCase();
                    if (window.__modCfg.autoSkip && (nm.includes('skip') || nm.includes('tiaoguo'))) {
                        if (!n.active) n.active = true;
                        const b = n.getComponent(cc.Button);
                        if (b) {
                            b.interactable = true;
                            if (n.activeInHierarchy && !n.__sk) {
                                n.__sk = true;
                                setTimeout(() => {
                                    if (n && n.isValid && n.activeInHierarchy) {
                                        n.emit('click', b);
                                        if (b.clickEvents) cc.Component.EventHandler.emitEvents(b.clickEvents, b);
                                    }
                                    if (n) n.__sk = false;
                                }, 350);
                            }
                        }
                    }
                    if (window.__modCfg.unlockSweep && (nm.includes('sweep') || nm.includes('saodang') || nm.includes('fight') || nm.includes('tiaozhan'))) {
                        const b = n.getComponent(cc.Button);
                        if (b && !b.interactable) b.interactable = true;
                    }
                    if (window.__modCfg.autoPush && n.activeInHierarchy && (nm.includes('next') || nm.includes('xiayiguan') || nm.includes('continue') || nm.includes('jixu'))) {
                        const b = n.getComponent(cc.Button);
                        if (b && b.interactable && !n.__nx) {
                            n.__nx = true;
                            setTimeout(() => {
                                if (n && n.isValid && n.activeInHierarchy) {
                                    n.emit('click', b);
                                    if (b.clickEvents) cc.Component.EventHandler.emitEvents(b.clickEvents, b);
                                }
                                if (n) n.__nx = false;
                            }, 600);
                        }
                    }
                    const ch = n.children || [];
                    for (let i = 0; i < ch.length; i++) walk(ch[i]);
                };
                walk(cv);
            }
        }
        if (typeof sp !== 'undefined' && sp.Skeleton && sp.Skeleton.prototype && !sp.Skeleton.prototype.__s) {
            sp.Skeleton.prototype.__s = true;
            const d = Object.getOwnPropertyDescriptor(sp.Skeleton.prototype, 'timeScale');
            if (d && d.set) {
                const origSet = d.set;
                Object.defineProperty(sp.Skeleton.prototype, 'timeScale', {
                    get: d.get,
                    set: function(v) { origSet.call(this, v * window.__modCfg.speedScale); }
                });
            }
        }
    }, 300);
})();
)JS";

// ============================================================================
// DOBBY HOOK VÀO FOPEN / FREAD ĐỂ CHẶN LÚC COCOS NẠP MAIN.JS / APPLICATION.JS
// ============================================================================
static std::mutex g_fileMutex;
static std::unordered_map<FILE*, std::string> g_trackedFiles;
static bool g_jsPayloadDelivered = false;

static FILE* (*orig_fopen)(const char* filename, const char* mode) = nullptr;
static size_t (*orig_fread)(void* ptr, size_t size, size_t count, FILE* stream) = nullptr;
static int (*orig_fclose)(FILE* stream) = nullptr;

FILE* hook_fopen(const char* filename, const char* mode) {
    FILE* fp = orig_fopen(filename, mode);
    if (fp && filename) {
        // Bắt đúng thời điểm Cocos đọc file main.js (luôn là file JS plaintext không mã hóa đầu tiên engine nạp)
        if (strstr(filename, "/main.js") != nullptr && strstr(filename, "assets/") == nullptr) {
            std::lock_guard<std::mutex> lk(g_fileMutex);
            g_trackedFiles[fp] = filename;
        }
    }
    return fp;
}

size_t hook_fread(void* ptr, size_t size, size_t count, FILE* stream) {
    size_t readItems = orig_fread(ptr, size, count, stream);
    if (stream && ptr && readItems > 0) {
        std::lock_guard<std::mutex> lk(g_fileMutex);
        auto it = g_trackedFiles.find(stream);
        if (it != g_trackedFiles.end()) {
            // Kiểm tra xem đã đọc tới cuối file main.js chưa
            size_t totalBytes = size * count;
            size_t actualBytes = size * readItems;
            size_t payloadLen = strlen(kCocosModJS);

            // Nếu buffer còn đủ chỗ hoặc đang đọc nốt phần cuối file, nối thêm payload JS
            if (!g_jsPayloadDelivered && (actualBytes + payloadLen + 2 <= totalBytes)) {
                char* buf = (char*)ptr;
                buf[actualBytes] = '\n';
                memcpy(buf + actualBytes + 1, kCocosModJS, payloadLen);
                g_jsPayloadDelivered = true;
                if (size == 1) {
                    return actualBytes + 1 + payloadLen;
                }
            }
        }
    }
    return readItems;
}

int hook_fclose(FILE* stream) {
    if (stream) {
        std::lock_guard<std::mutex> lk(g_fileMutex);
        g_trackedFiles.erase(stream);
    }
    return orig_fclose(stream);
}

// ============================================================================
// GIAO DIỆN FLOATING MENU NATIVE UIKIT
// ============================================================================
@interface XSamkokDobbyMenu : NSObject
@property (nonatomic, strong) UIButton *floatingBtn;
@property (nonatomic, strong) UIView *menuPanel;
@property (nonatomic, strong) UILabel *dmgLabel;
@property (nonatomic, strong) UILabel *spdLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableDictionary *config;
@property (nonatomic, copy) NSString *configPath;
+ (instancetype)shared;
- (void)install;
@end

@implementation XSamkokDobbyMenu

+ (instancetype)shared {
    static XSamkokDobbyMenu *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[XSamkokDobbyMenu alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
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
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.config options:0 error:nil];
    if (data) [data writeToFile:self.configPath atomically:YES];
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

    CGFloat w = 300, h = 465;
    self.menuPanel = [[UIView alloc] initWithFrame:CGRectMake((win.bounds.size.width - w) / 2, (win.bounds.size.height - h) / 2, w, h)];
    self.menuPanel.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.11 alpha:0.95];
    self.menuPanel.layer.cornerRadius = 14;
    self.menuPanel.layer.borderWidth = 1.5;
    self.menuPanel.layer.borderColor = [UIColor colorWithRed:0.0 green:0.85 blue:0.5 alpha:0.85].CGColor;
    self.menuPanel.hidden = YES;
    [win addSubview:self.menuPanel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, w - 55, 22)];
    title.text = @"X-SAMKOK v1.0.173 | DOBBY";
    title.font = [UIFont boldSystemFontOfSize:13.5];
    title.textColor = [UIColor colorWithRed:0.0 green:0.95 blue:0.55 alpha:1.0];
    [self.menuPanel addSubview:title];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 28, w - 55, 16)];
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    [self.menuPanel addSubview:self.statusLabel];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(w - 38, 8, 28, 28);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.menuPanel addSubview:closeBtn];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 48, w - 24, h - 58)];
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
    self.statusLabel.textColor = g_jsPayloadDelivered ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    self.statusLabel.text = g_jsPayloadDelivered ? @"Dobby Inject main.js: THÀNH CÔNG" : @"Dobby Inject main.js: CHƯA BẮT ĐƯỢC";
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
static void InitDobbyTweak() {
    void* symFopen = DobbySymbolResolver(nullptr, "fopen");
    void* symFread = DobbySymbolResolver(nullptr, "fread");
    void* symFclose = DobbySymbolResolver(nullptr, "fclose");

    if (symFopen) DobbyHook(symFopen, (void*)hook_fopen, (void**)&orig_fopen);
    if (symFread) DobbyHook(symFread, (void*)hook_fread, (void**)&orig_fread);
    if (symFclose) DobbyHook(symFclose, (void*)hook_fclose, (void**)&orig_fclose);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[XSamkokDobbyMenu shared] install];
    });
}
