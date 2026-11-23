// language: Objective-C++, file: Tweak.mm, runtime: iOS ARM64, target: com.global.snmj.ios (v1.0.173)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#include <cstring>
#include <string>
#include <vector>
#include <mutex>
#include "dobby.h"

// ============================================================================
// PHẦN 1: PAYLOAD JS CHẠY TRỰC TIẾP TRONG COCOS SCRIPT ENGINE (SE::SCRIPTENGINE)
// ============================================================================
static const char* kXSamkokEnginePayload = R"JS(
(function() {
    if (window.__xsamkok_master_loaded) return;
    window.__xsamkok_master_loaded = true;

    window.__modCfg = {
        dmgMult: 1.0,
        speedScale: 1.0,
        godMode: false,
        oneHitEnemy: false,
        autoSkip: false,
        autoPush: false,
        unlockSweep: false,
        unlockVip: false,
        netLog: false
    };

    window.__sysMods = {};

    // 1. Hook System.register ngay lúc bundle khởi chạy (nếu kịp) + quét System.entries (nếu inject muộn)
    const hookSystem = () => {
        if (typeof System === 'undefined') return;
        if (System.register && !System.__china_reg) {
            System.__china_reg = true;
            const origRegister = System.register.bind(System);
            System.register = function(name, deps, declare) {
                if (typeof name === 'string') {
                    if (name.endsWith('/env')) {
                        const origDec = declare;
                        declare = function(_export, _context) {
                            return origDec(function(k, v) {
                                if (k === 'DEBUG' || k === 'DEV') v = true;
                                return _export(k, v);
                            }, _context);
                        };
                    }
                    const origDec = declare;
                    declare = function(_export, _context) {
                        const captured = {};
                        const proxyExp = function(k, v) {
                            if (typeof k === 'string') captured[k] = v;
                            else if (k && typeof k === 'object') Object.assign(captured, k);
                            return _export(k, v);
                        };
                        const res = origDec(proxyExp, _context);
                        window.__sysMods[name] = captured;
                        if (res && typeof res.execute === 'function') {
                            const origExec = res.execute.bind(res);
                            res.execute = function() {
                                const r = origExec();
                                patchModuleDeep(name, captured);
                                return r;
                            };
                        }
                        return res;
                    };
                }
                return origRegister(name, deps, declare);
            };
        }

        // Quét các module đã đăng ký sẵn trong SystemJS (trường hợp inject sau khi boot)
        try {
            const symKeys = Object.getOwnPropertySymbols(System);
            for (const s of symKeys) {
                const regMap = System[s];
                if (regMap && typeof regMap === 'object') {
                    for (const modUrl of Object.keys(regMap)) {
                        const entry = regMap[modUrl];
                        if (entry && entry.C && !entry.C.__china_scanned) {
                            entry.C.__china_scanned = true;
                            window.__sysMods[modUrl] = entry.C;
                            patchModuleDeep(modUrl, entry.C);
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

    const wrapUnitHp = (unit) => {
        if (!unit || typeof unit !== 'object' || unit.__hp_hooked) return;
        unit.__hp_hooked = true;

        const keys = Object.keys(unit);
        for (const k of keys) {
            if (!/^(cur)?_?hp$/i.test(k) && !/blood/i.test(k)) continue;
            if (typeof unit[k] !== 'number') continue;

            let val = unit[k];
            try {
                Object.defineProperty(unit, k, {
                    configurable: true,
                    enumerable: true,
                    get: () => val,
                    set: (nv) => {
                        const ally = isAlly(unit);
                        if (ally) {
                            if (window.__modCfg.godMode && nv < val) return;
                        } else {
                            if (window.__modCfg.oneHitEnemy && nv < val) {
                                val = 0;
                                return;
                            }
                            if (window.__modCfg.dmgMult > 1.0 && nv < val) {
                                const loss = val - nv;
                                const next = val - loss * window.__modCfg.dmgMult;
                                val = next < 0 ? 0 : next;
                                return;
                            }
                        }
                        val = nv;
                    }
                });
            } catch (e) {}
        }
    };

    const patchModuleDeep = (modName, exportsObj) => {
        const combatTargets = [
            'enemybase.ts', 'armyctrl.ts', 'warctrl.ts', 'warjsctrl.ts',
            'armymdl.ts', 'heromdl.ts', 'towerctrl.ts', 'slfbctrl.ts'
        ];
        if (combatTargets.some(t => modName.endsWith('/' + t))) {
            for (const expKey of Object.keys(exportsObj)) {
                const cls = exportsObj[expKey];
                if (typeof cls !== 'function' || !cls.prototype) continue;
                const proto = cls.prototype;
                if (proto.__deep_patched) continue;
                proto.__deep_patched = true;

                for (const m of Object.getOwnPropertyNames(proto)) {
                    if (m === 'constructor' || typeof proto[m] !== 'function') continue;
                    const origFn = proto[m];
                    proto[m] = function(...args) {
                        wrapUnitHp(this);
                        for (let i = 0; i < args.length; i++) {
                            if (args[i] && typeof args[i] === 'object') {
                                if (Array.isArray(args[i])) args[i].forEach(wrapUnitHp);
                                else wrapUnitHp(args[i]);
                            }
                        }
                        if (args.length >= 1 && typeof args[0] === 'number' && args[0] !== 0) {
                            if (/hurt|damage|hit|atk|subHp|changeHp|kouXue|shanghai/i.test(m)) {
                                const ally = isAlly(this);
                                if (ally && window.__modCfg.godMode) return 0;
                                if (!ally) {
                                    if (window.__modCfg.oneHitEnemy) {
                                        args[0] = args[0] < 0 ? -999999999 : 999999999;
                                    } else if (window.__modCfg.dmgMult > 1.0) {
                                        args[0] *= window.__modCfg.dmgMult;
                                    }
                                }
                            }
                        }
                        return origFn.apply(this, args);
                    };
                }
            }
        }

        if (modName.endsWith('/privilegemdl.ts')) {
            for (const k of Object.keys(exportsObj)) {
                const proto = exportsObj[k]?.prototype || exportsObj[k];
                if (!proto || proto.__vip_patched) continue;
                proto.__vip_patched = true;
                for (const fn of Object.getOwnPropertyNames(proto)) {
                    if (/isOpen|hasPriv|isActive|checkCard|isBuy/i.test(fn) && typeof proto[fn] === 'function') {
                        const orig = proto[fn];
                        proto[fn] = function(...args) {
                            return window.__modCfg.unlockVip ? true : orig.apply(this, args);
                        };
                    }
                }
            }
        }
        if (modName.endsWith('/playermdl.ts') && exportsObj.Bc1cPlayerM) {
            const proto = exportsObj.Bc1cPlayerM.prototype;
            if (proto && !proto.__vip_patched) {
                proto.__vip_patched = true;
                for (const fn of Object.getOwnPropertyNames(proto)) {
                    if (/getVip|vipLv/i.test(fn) && typeof proto[fn] === 'function') {
                        const orig = proto[fn];
                        proto[fn] = function(...args) {
                            const v = orig.apply(this, args);
                            return window.__modCfg.unlockVip ? Math.max(v || 0, 15) : v;
                        };
                    }
                }
            }
        }
    };

    const maintainEngine = () => {
        hookSystem();
        if (typeof cc !== 'undefined' && cc.director) {
            const sch = cc.director.getScheduler();
            if (sch && !sch.__spd_hooked) {
                sch.__spd_hooked = true;
                const origUpd = sch.update.bind(sch);
                sch.update = function(dt) {
                    origUpd(dt * window.__modCfg.speedScale);
                };
            }
        }
        if (typeof sp !== 'undefined' && sp.Skeleton && sp.Skeleton.prototype && !sp.Skeleton.prototype.__spd_hooked) {
            sp.Skeleton.prototype.__spd_hooked = true;
            const d = Object.getOwnPropertyDescriptor(sp.Skeleton.prototype, 'timeScale');
            if (d && d.set) {
                const origSet = d.set;
                Object.defineProperty(sp.Skeleton.prototype, 'timeScale', {
                    get: d.get,
                    set: function(v) { origSet.call(this, v * window.__modCfg.speedScale); }
                });
            }
        }
        if (typeof WebSocket !== 'undefined' && !WebSocket.prototype.__ws_hooked) {
            WebSocket.prototype.__ws_hooked = true;
            const origSend = WebSocket.prototype.send;
            WebSocket.prototype.send = function(data) {
                if (window.__modCfg.netLog) {
                    console.log('[XS-WS]', data instanceof ArrayBuffer ? ('Bin:' + data.byteLength) : String(data).slice(0, 300));
                }
                return origSend.apply(this, arguments);
            };
        }
    };

    const scanSceneControls = () => {
        if (typeof cc === 'undefined' || !cc.director) return;
        const scene = cc.director.getScene();
        const canvas = scene && scene.getChildByName('Canvas');
        if (!canvas) return;

        const walk = (node) => {
            if (!node) return;
            const nm = (node.name || '').toLowerCase();

            if (window.__modCfg.autoSkip && (nm.includes('skip') || nm.includes('tiaoguo'))) {
                if (!node.active) node.active = true;
                const btn = node.getComponent(cc.Button);
                if (btn) {
                    btn.interactable = true;
                    if (node.activeInHierarchy && !node.__skip_lock) {
                        node.__skip_lock = true;
                        setTimeout(() => {
                            if (node && node.isValid && node.activeInHierarchy) {
                                node.emit('click', btn);
                                if (btn.clickEvents) cc.Component.EventHandler.emitEvents(btn.clickEvents, btn);
                            }
                            if (node) node.__skip_lock = false;
                        }, 350);
                    }
                }
            }

            if (window.__modCfg.unlockSweep && (nm.includes('sweep') || nm.includes('saodang') || nm.includes('fight') || nm.includes('tiaozhan'))) {
                const btn = node.getComponent(cc.Button);
                if (btn && !btn.interactable) btn.interactable = true;
            }

            if (window.__modCfg.autoPush && node.activeInHierarchy && (nm.includes('next') || nm.includes('xiayiguan') || nm.includes('continue') || nm.includes('jixu'))) {
                const btn = node.getComponent(cc.Button);
                if (btn && btn.interactable && !node.__next_lock) {
                    node.__next_lock = true;
                    setTimeout(() => {
                        if (node && node.isValid && node.activeInHierarchy) {
                            node.emit('click', btn);
                            if (btn.clickEvents) cc.Component.EventHandler.emitEvents(btn.clickEvents, btn);
                        }
                        if (node) node.__next_lock = false;
                    }, 600);
                }
            }

            const ch = node.children || [];
            for (let i = 0; i < ch.length; i++) walk(ch[i]);
        };
        walk(canvas);
    };

    window.__toggleOfficialGM = () => {
        if (typeof cc === 'undefined' || !cc.assetManager) return;
        cc.assetManager.loadBundle('bcgmst', (err, bundle) => {
            if (err || !bundle) return;
            bundle.loadDir('', cc.Prefab, (err2, prefabs) => {
                if (err2 || !prefabs || !prefabs.length) return;
                const scene = cc.director.getScene();
                const canvas = scene && scene.getChildByName('Canvas');
                if (!canvas) return;
                const exist = canvas.getChildByName('__OfficialGMNode');
                if (exist) {
                    exist.active = !exist.active;
                    return;
                }
                const gmNode = cc.instantiate(prefabs[0]);
                gmNode.name = '__OfficialGMNode';
                gmNode.zIndex = 9999;
                canvas.addChild(gmNode);
            });
        });
    };

    setInterval(() => {
        maintainEngine();
        scanSceneControls();
    }, 500);
})();
)JS";

// ============================================================================
// PHẦN 2: QUÉT MACH-O & HOOK TRỰC TIẾP SE::SCRIPTENGINE::EVALSTRING CỦA COCOS
// ============================================================================
// Signature C++ trên ARM64 iOS của se::ScriptEngine::evalString(const char* script, ssize_t length, se::Value* ret, const char* fileName)
typedef bool (*EvalStringFn)(void* thisPtr, const char* script, long length, void* ret, const char* fileName);
static EvalStringFn orig_evalString = nullptr;
static void* g_scriptEngineInstance = nullptr;
static bool g_masterInjected = false;
static std::mutex g_cmdMutex;
static std::vector<std::string> g_cmdQueue;

static void EnqueueJSCommand(const std::string& jsCode) {
    std::lock_guard<std::mutex> lock(g_cmdMutex);
    g_cmdQueue.push_back(jsCode);
}

bool hook_evalString(void* thisPtr, const char* script, long length, void* ret, const char* fileName) {
    if (thisPtr != nullptr) {
        g_scriptEngineInstance = thisPtr;
    }

    bool result = orig_evalString(thisPtr, script, length, ret, fileName);

    // Bơm payload chính ngay lần evalString đầu tiên của engine Cocos
    if (!g_masterInjected && thisPtr != nullptr) {
        g_masterInjected = true;
        orig_evalString(thisPtr, kXSamkokEnginePayload, (long)strlen(kXSamkokEnginePayload), nullptr, "xsamkok_master.js");
    }

    // Xả toàn bộ hàng đợi lệnh từ UIKit Menu vào ngay luồng JS đang chạy
    if (g_masterInjected && thisPtr != nullptr) {
        std::vector<std::string> cmds;
        {
            std::lock_guard<std::mutex> lock(g_cmdMutex);
            if (!g_cmdQueue.empty()) {
                cmds.swap(g_cmdQueue);
            }
        }
        for (const auto& c : cmds) {
            orig_evalString(thisPtr, c.c_str(), (long)c.size(), nullptr, "ui_cmd.js");
        }
    }

    return result;
}

// Quét bảng symbol Mach-O của binary chính để tìm _ZN2se12ScriptEngine10evalStringEPKclPNS_5ValueES2_
static void* FindCocosEvalStringSymbol() {
    // 1. Thử tra trực tiếp bằng DobbySymbolResolver trên main executable (image_name = nullptr)
    const char* mangledNames[] = {
        "_ZN2se12ScriptEngine10evalStringEPKclPNS_5ValueES2_",
        "_ZN2se12ScriptEngine10evalStringEPKciPNS_5ValueES2_",
        "__ZN2se12ScriptEngine10evalStringEPKclPNS_5ValueES2_"
    };
    for (const char* symName : mangledNames) {
        void* addr = DobbySymbolResolver(nullptr, symName);
        if (addr != nullptr) return addr;
    }

    // 2. Fallback: duyệt nlist trong Mach-O header của image 0 (binary chính)
    const struct mach_header_64* header = (const struct mach_header_64*)_dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    if (!header || header->magic != MH_MAGIC_64) return nullptr;

    const struct load_command* cmd = (const struct load_command*)((uintptr_t)header + sizeof(struct mach_header_64));
    const struct symtab_command* symtab = nullptr;
    const struct segment_command_64* linkedit = nullptr;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command*)cmd;
        } else if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* seg = (const struct segment_command_64*)cmd;
            if (strcmp(seg->segname, "__LINKEDIT") == 0) {
                linkedit = seg;
            }
        }
        cmd = (const struct load_command*)((uintptr_t)cmd + cmd->cmdsize);
    }

    if (!symtab || !linkedit) return nullptr;

    uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64* syms = (const struct nlist_64*)(linkeditBase + symtab->symoff);
    const char* strtab = (const char*)(linkeditBase + symtab->stroff);

    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        uint32_t strx = syms[i].n_un.n_strx;
        if (strx == 0) continue;
        const char* name = strtab + strx;
        if (strstr(name, "ScriptEngine") && strstr(name, "evalString") && syms[i].n_value != 0) {
            return (void*)(syms[i].n_value + slide);
        }
    }
    return nullptr;
}

// ============================================================================
// PHẦN 3: GIAO DIỆN FLOATING MENU NATIVE UIKIT (KÉO THẢ + SLIDER + TOGGLE)
// ============================================================================
@interface SheepctMenuController : NSObject
@property (nonatomic, strong) UIButton *floatingBtn;
@property (nonatomic, strong) UIView *menuPanel;
@property (nonatomic, strong) UILabel *dmgLabel;
@property (nonatomic, strong) UILabel *spdLabel;
@property (nonatomic, strong) UILabel *statusLabel;
+ (instancetype)sharedInstance;
- (void)setupUI;
@end

@implementation SheepctMenuController

+ (instancetype)sharedInstance {
    static SheepctMenuController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SheepctMenuController alloc] init];
    });
    return instance;
}

- (UIWindow *)getKeyWindow {
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

- (void)setupUI {
    UIWindow *mainWin = [self getKeyWindow];
    if (!mainWin || self.floatingBtn) return;

    self.floatingBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingBtn.frame = CGRectMake(20, 100, 52, 52);
    self.floatingBtn.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.12 alpha:0.92];
    self.floatingBtn.layer.cornerRadius = 26;
    self.floatingBtn.layer.borderWidth = 2.0;
    self.floatingBtn.layer.borderColor = [UIColor colorWithRed:0.0 green:0.95 blue:0.55 alpha:1.0].CGColor;
    [self.floatingBtn setTitle:@"MOD" forState:UIControlStateNormal];
    self.floatingBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [self.floatingBtn setTitleColor:[UIColor colorWithRed:0.0 green:0.95 blue:0.55 alpha:1.0] forState:UIControlStateNormal];
    [self.floatingBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.floatingBtn addGestureRecognizer:pan];
    [mainWin addSubview:self.floatingBtn];

    CGFloat panelW = 300;
    CGFloat panelH = 465;
    CGFloat screenW = mainWin.bounds.size.width;
    CGFloat screenH = mainWin.bounds.size.height;

    self.menuPanel = [[UIView alloc] initWithFrame:CGRectMake((screenW - panelW) / 2, (screenH - panelH) / 2, panelW, panelH)];
    self.menuPanel.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.11 alpha:0.95];
    self.menuPanel.layer.cornerRadius = 14;
    self.menuPanel.layer.borderWidth = 1.5;
    self.menuPanel.layer.borderColor = [UIColor colorWithRed:0.0 green:0.85 blue:0.5 alpha:0.8].CGColor;
    self.menuPanel.hidden = YES;
    [mainWin addSubview:self.menuPanel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(15, 8, panelW - 60, 22)];
    title.text = @"X-SAMKOK v1.0.173 | SHEEPCT";
    title.font = [UIFont boldSystemFontOfSize:13.5];
    title.textColor = [UIColor colorWithRed:0.0 green:0.95 blue:0.55 alpha:1.0];
    [self.menuPanel addSubview:title];

    // Dòng báo trạng thái kết nối Cocos JS Engine để kiểm tra ngay lúc mở menu
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 28, panelW - 60, 16)];
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.textColor = g_masterInjected ? [UIColor systemGreenColor] : [UIColor systemYellowColor];
    self.statusLabel.text = g_masterInjected ? @"JS Engine: ĐÃ KẾT NỐI (ACTIVE)" : @"JS Engine: ĐANG CHỜ HOOK...";
    [self.menuPanel addSubview:self.statusLabel];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(panelW - 40, 8, 30, 30);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.menuPanel addSubview:closeBtn];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 48, panelW - 24, panelH - 58)];
    scroll.showsVerticalScrollIndicator = YES;
    [self.menuPanel addSubview:scroll];

    CGFloat y = 5;

    self.dmgLabel = [[UILabel alloc] initWithFrame:CGRectMake(4, y, panelW - 32, 20)];
    self.dmgLabel.text = @"Nhân Sát Thương Phe Ta: 1x";
    self.dmgLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.dmgLabel.textColor = [UIColor whiteColor];
    [scroll addSubview:self.dmgLabel];
    y += 22;

    UISlider *dmgSlider = [[UISlider alloc] initWithFrame:CGRectMake(4, y, panelW - 32, 26)];
    dmgSlider.minimumValue = 1.0;
    dmgSlider.maximumValue = 100.0;
    dmgSlider.value = 1.0;
    dmgSlider.minimumTrackTintColor = [UIColor systemRedColor];
    [dmgSlider addTarget:self action:@selector(onDmgSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:dmgSlider];
    y += 34;

    self.spdLabel = [[UILabel alloc] initWithFrame:CGRectMake(4, y, panelW - 32, 20)];
    self.spdLabel.text = @"Tốc Độ Trận & Game: 1.0x";
    self.spdLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.spdLabel.textColor = [UIColor whiteColor];
    [scroll addSubview:self.spdLabel];
    y += 22;

    UISlider *spdSlider = [[UISlider alloc] initWithFrame:CGRectMake(4, y, panelW - 32, 26)];
    spdSlider.minimumValue = 1.0;
    spdSlider.maximumValue = 8.0;
    spdSlider.value = 1.0;
    spdSlider.minimumTrackTintColor = [UIColor systemGreenColor];
    [spdSlider addTarget:self action:@selector(onSpdSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:spdSlider];
    y += 38;

    NSArray *switches = @[
        @{@"title": @"Bất Tử Phe Ta (God Mode)", @"tag": @1},
        @{@"title": @"One-Hit Địch (1 Chạm Chết)", @"tag": @2},
        @{@"title": @"Auto Skip Trận Đấu (0s)", @"tag": @3},
        @{@"title": @"Auto Leo Ải / Leo Tháp", @"tag": @4},
        @{@"title": @"Mở Khóa Càn Quét / Khiêu Chiến", @"tag": @5},
        @{@"title": @"VIP 15 & Đặc Quyền Client", @"tag": @6},
        @{@"title": @"Log Gói Tin WebSocket", @"tag": @7}
    ];

    for (NSDictionary *item in switches) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, panelW - 24, 36)];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        row.layer.cornerRadius = 8;

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, panelW - 90, 36)];
        lbl.text = item[@"title"];
        lbl.font = [UIFont systemFontOfSize:12.5];
        lbl.textColor = [UIColor colorWithWhite:0.93 alpha:1.0];
        [row addSubview:lbl];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 82, 2.5, 51, 31)];
        sw.transform = CGAffineTransformMakeScale(0.8, 0.8);
        sw.tag = [item[@"tag"] integerValue];
        sw.onTintColor = [UIColor colorWithRed:0.0 green:0.85 blue:0.5 alpha:1.0];
        [sw addTarget:self action:@selector(onSwitchToggled:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sw];

        [scroll addSubview:row];
        y += 42;
    }

    UIButton *gmBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    gmBtn.frame = CGRectMake(0, y + 4, panelW - 24, 38);
    gmBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.55 blue:0.1 alpha:1.0];
    gmBtn.layer.cornerRadius = 8;
    [gmBtn setTitle:@"MỞ BẢNG GM GỐC (BCGMST)" forState:UIControlStateNormal];
    gmBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [gmBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [gmBtn addTarget:self action:@selector(onOpenGMPressed) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:gmBtn];
    y += 50;

    scroll.contentSize = CGSizeMake(panelW - 24, y);
}

- (void)toggleMenu {
    self.menuPanel.hidden = !self.menuPanel.hidden;
    self.statusLabel.textColor = g_masterInjected ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    self.statusLabel.text = g_masterInjected ? @"JS Engine: ĐÃ KẾT NỐI (ACTIVE)" : @"JS Engine: CHƯA HOOK ĐƯỢC SYMBOL";
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIWindow *win = [self getKeyWindow];
    CGPoint delta = [pan translationInView:win];
    CGPoint center = self.floatingBtn.center;
    center.x = MAX(30, MIN(win.bounds.size.width - 30, center.x + delta.x));
    center.y = MAX(40, MIN(win.bounds.size.height - 40, center.y + delta.y));
    self.floatingBtn.center = center;
    [pan setTranslation:CGPointZero inView:win];
}

- (void)onDmgSliderChanged:(UISlider *)slider {
    int val = (int)roundf(slider.value);
    self.dmgLabel.text = [NSString stringWithFormat:@"Nhân Sát Thương Phe Ta: %dx", val];
    EnqueueJSCommand("if(window.__modCfg) window.__modCfg.dmgMult = " + std::to_string(val) + ";");
}

- (void)onSpdSliderChanged:(UISlider *)slider {
    float val = roundf(slider.value * 2.0f) / 2.0f;
    self.spdLabel.text = [NSString stringWithFormat:@"Tốc Độ Trận & Game: %.1fx", val];
    EnqueueJSCommand("if(window.__modCfg) window.__modCfg.speedScale = " + std::to_string(val) + ";");
}

- (void)onSwitchToggled:(UISwitch *)sw {
    std::string state = sw.isOn ? "true" : "false";
    switch (sw.tag) {
        case 1: EnqueueJSCommand("if(window.__modCfg) window.__modCfg.godMode = " + state + ";"); break;
        case 2: EnqueueJSCommand("if(window.__modCfg) window.__modCfg.oneHitEnemy = " + state + ";"); break;
        case 3: EnqueueJSCommand("if(window.__modCfg) window.__modCfg.autoSkip = " + state + ";"); break;
        case 4: EnqueueJSCommand("if(window.__modCfg) window.__modCfg.autoPush = " + state + ";"); break;
        case 5: EnqueueJSCommand("if(window.__modCfg) window.__modCfg.unlockSweep = " + state + ";"); break;
        case 6: EnqueueJSCommand("if(window.__modCfg) window.__modCfg.unlockVip = " + state + ";"); break;
        case 7: EnqueueJSCommand("if(window.__modCfg) window.__modCfg.netLog = " + state + ";"); break;
    }
}

- (void)onOpenGMPressed {
    EnqueueJSCommand("if(window.__toggleOfficialGM) window.__toggleOfficialGM();");
}

@end

// ============================================================================
// PHẦN 4: ENTRY POINT KHỞI TẠO DYLIB
// ============================================================================
__attribute__((constructor))
static void InitXSamkokMasterDylib() {
    void* evalAddr = FindCocosEvalStringSymbol();
    if (evalAddr != nullptr) {
        DobbyHook(evalAddr, (void*)hook_evalString, (void**)&orig_evalString);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[SheepctMenuController sharedInstance] setupUI];
    });
}
