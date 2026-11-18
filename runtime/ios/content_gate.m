// Écran d'installation du contenu du jeu sur iOS/iPadOS (voir content_gate.h).
// Sans archives VPK complètes, le moteur meurt peu après le lancement
// (« Tried to Seek/Read NULL file handle! », sans rapport de plantage) : on
// vérifie avant, et on explique au joueur quoi copier et combien de place il faut.
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "content_check.h"
#include "content_gate.h"
#include "settings.h"
#include "portal_save_bridge.h"

// Textes : français si c'est la première langue de l'appareil, sinon anglais
// (comme la page Réglages du jeu, en français).
static BOOL french(void) {
    static int cached = -1;
    if (cached < 0) cached = [NSLocale.preferredLanguages.firstObject hasPrefix:@"fr"] ? 1 : 0;
    return cached == 1;
}
#define TEXT(fr, en) (french() ? (fr) : (en))

static NSString *size_text(int64_t bytes) {
    return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile];
}

static NSString *count_text(int count) {  // « 3 592 », « 3,592 »
    return [NSNumberFormatter localizedStringFromNumber:@(count) numberStyle:NSNumberFormatterDecimalStyle];
}

enum {
    LibraryCanvas = 0xF4F7FC, LibraryPaper = 0xFFFFFF, LibraryLine = 0xDCE6F0,
    LibraryInk = 0x17283D, LibrarySecondary = 0x4C6178, LibraryBlue = 0x005CB8,
    LibraryOrange = 0xB54708, LibraryOrangeArt = 0xEF7622,
};

static UIColor *libraryColor(unsigned rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0
                           green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}

// Original artwork for the Library cover, sized to the actual card bounds.
@interface P2PortalCoverView : UIView
@end

static void drawPortal(CGContextRef context, CGPoint center, CGFloat height, CGFloat tilt,
                       unsigned rim, unsigned inside) {
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, center.x, center.y);
    CGContextRotateCTM(context, tilt);
    CGRect oval = CGRectMake(-height * .26, -height * .5, height * .52, height);
    UIColor *color = libraryColor(rim);
    CGContextSetShadowWithColor(context, CGSizeZero, height * .16, [color colorWithAlphaComponent:.32].CGColor);
    CGContextSetFillColorWithColor(context, libraryColor(inside).CGColor);
    CGContextFillEllipseInRect(context, oval);
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    CGContextSetStrokeColorWithColor(context, color.CGColor);
    CGContextSetLineWidth(context, height * .075);
    CGContextStrokeEllipseInRect(context, oval);
    CGContextSetStrokeColorWithColor(context, [UIColor.whiteColor colorWithAlphaComponent:.8].CGColor);
    CGContextSetLineWidth(context, MAX(1, height * .014));
    CGContextStrokeEllipseInRect(context, CGRectInset(oval, height * .0375, height * .0375));
    CGContextRestoreGState(context);
}

@implementation P2PortalCoverView
- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGFloat w = CGRectGetWidth(self.bounds), h = CGRectGetHeight(self.bounds);
    NSArray *colors = @[(id)libraryColor(0xE4F1FF).CGColor, (id)libraryColor(LibraryPaper).CGColor,
                        (id)libraryColor(0xFFF0E3).CGColor];
    CGGradientRef gradient = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)colors, NULL);
    CGContextDrawLinearGradient(context, gradient, CGPointZero, CGPointMake(w, h), 0);
    CGGradientRelease(gradient);

    CGContextSetStrokeColorWithColor(context, libraryColor(LibraryLine).CGColor);
    CGContextSetLineWidth(context, 1);
    for (int i = 0; i <= 8; i++) {
        CGFloat offset = w * (i - 4) / 8;
        CGContextMoveToPoint(context, w * .5 + offset * .4, h * .66);
        CGContextAddLineToPoint(context, w * .5 + offset * 1.65, h);
    }
    CGFloat floorLines[] = {.66, .76, .91};
    for (unsigned i = 0; i < sizeof(floorLines) / sizeof(*floorLines); i++) {
        CGContextMoveToPoint(context, 0, h * floorLines[i]);
        CGContextAddLineToPoint(context, w, h * floorLines[i]);
    }
    CGContextStrokePath(context);

    CGFloat ovalHeight = MIN(h * .7, w * .37);
    drawPortal(context, CGPointMake(w * .35, h * .51), ovalHeight, -.15, 0x1987EB, 0xD5EAFF);
    drawPortal(context, CGPointMake(w * .65, h * .46), ovalHeight, .15, LibraryOrangeArt, 0xFFE3CA);
}
@end

typedef NS_ENUM(NSUInteger, P2LaunchIntent) {
    P2LaunchGameMenu,
    P2LaunchCampaign,
    P2LaunchContinue,
};

@interface P2ContentGateController : UIViewController
@property(nonatomic, readonly) BOOL passed;
@property(nonatomic, readonly) BOOL contentReady;
@property(nonatomic, readonly) NSString *selectedSave;
- (instancetype)initWithRoots:(const char *const *)roots;
- (BOOL)check:(const char *)trigger;
@property(nonatomic) BOOL showLauncher;
@property(nonatomic) BOOL offerContinue;
@property(nonatomic) BOOL frameRateOverridden;
@property(nonatomic) BOOL showFPSOverridden;
@end

@implementation P2ContentGateController {
    char *_roots[4];  // game, linux, prep, documents (copies; NULL: absente)
    BOOL _documentsLayout;  // racines par défaut (Documents/game, linux, prep) : liste des fichiers vérifiée aussi
    P2ContentReport _report;
    UILabel *_title, *_detail, *_names, *_space, *_heading, *_help, *_status;
    UIButton *_button, *_menuButton;
    NSString *_continueSave;
    UIStackView *_frameRateChoices;
    UIButton *_playOfflineButton;
    UIButton *_saveButton;
    UILabel *_saveStatus;
    NSUInteger _saveAttempt;
    BOOL _preparingSaves;
    P2LaunchIntent _pendingLaunch;
    id _observer;
}

- (instancetype)initWithRoots:(const char *const *)roots {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        for (int i = 0; i < 4; ++i) _roots[i] = roots[i] && *roots[i] ? strdup(roots[i]) : NULL;
        // Sans --game-dir, --linux-root ni --images : le contenu copié dans
        // Documents, vérifié aussi avec la liste Documents/portal2-content-manifest.txt
        // (sans liste : la première carte de la campagne). Racines explicites
        // (simulateur sur l'installation du Mac) : archives et fichiers requis seulement.
        static const char *const names[3] = {"game", "linux", "prep"};
        _documentsLayout = _roots[3] != NULL;
        for (int i = 0; i < 3 && _documentsLayout; ++i) {
            char expected[1024];
            _documentsLayout = _roots[i] && snprintf(expected, sizeof(expected), "%s/%s", _roots[3], names[i]) <
                               (int)sizeof(expected) && !strcmp(_roots[i], expected);
        }
    }
    return self;
}

- (BOOL)contentReady { return _report.complete; }

- (void)dealloc {
    if (_observer) [NSNotificationCenter.defaultCenter removeObserver:_observer];
    for (int i = 0; i < 4; ++i) free(_roots[i]);
}

// Vérifie, ajoute l'espace du volume, écrit Documents/portal2-setup-status.json
// (lu à distance par devicectl) et met l'écran à jour.
- (BOOL)check:(const char *)trigger {
    if (_documentsLayout) p2_content_check(_roots[3], &_report);
    else p2_content_check_roots(_roots[0], _roots[1], _roots[2], &_report);
    BOOL play = !strcmp(trigger, "play");
    _passed = _report.complete && (self.showLauncher ? play : [P2SaveBridge playOffline]);
    if (!play) _continueSave = _report.complete && self.offerContinue ? p2_latest_campaign_save(_roots[3], _roots[0]) : nil;
    if (_roots[3]) {
        NSString *documents = [NSString stringWithUTF8String:_roots[3]];
        NSArray<NSURLResourceKey> *keys = @[NSURLVolumeAvailableCapacityForImportantUsageKey, NSURLVolumeTotalCapacityKey];
        NSDictionary<NSURLResourceKey, id> *values = documents.length ?
            [[NSURL fileURLWithPath:documents isDirectory:YES] resourceValuesForKeys:keys error:nil] : nil;
        NSNumber *available = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
        NSNumber *total = values[NSURLVolumeTotalCapacityKey];
        if ([available isKindOfClass:NSNumber.class]) _report.volume_available = available.longLongValue;
        if ([total isKindOfClass:NSNumber.class]) _report.volume_total = total.longLongValue;
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        id version = info[@"CFBundleShortVersionString"], build = info[@"CFBundleVersion"];
        NSString *system = UIDevice.currentDevice.systemName;  // « iOS », « iPadOS »
        P2ContentStatus status = {
            .platform = system.length ? system.UTF8String : "iOS",
            .app_version = [version isKindOfClass:NSString.class] ? [version UTF8String] : NULL,
            .app_build = [build isKindOfClass:NSString.class] ? [build UTF8String] : NULL,
            .trigger = trigger,
            .engine_started = _passed,  // main_ios.c lance le moteur juste après
        };
        char path[1024];
        if (snprintf(path, sizeof(path), "%s/%s", _roots[3], P2_CONTENT_STATUS_FILE) < (int)sizeof(path) &&
            p2_content_write_status(path, &_report, &status))
            fprintf(stderr, "[ios] %s non écrit : %s\n", P2_CONTENT_STATUS_FILE, strerror(errno));
    }
    fprintf(stderr, "[ios] contenu du jeu (%s) : %s ; %d requis manquants, %d/%d archives manquantes, %d tronquées, "
            "%d index endommagés, liste %s (%d/%d fichiers manquants, %d de taille différente), carte témoin %s, "
            "~%lld octets manquants, %lld µs%s%s\n", trigger,
            _report.complete ? "complet" : "incomplet", _report.required_missing, _report.missing_archives,
            _report.archives, _report.short_archives, _report.bad_directories,
            !_report.manifest ? "absente" : _report.manifest_bad ? "illisible" : "lue", _report.manifest_missing,
            _report.manifest_files, _report.manifest_wrong_size, _report.maps_missing ? "manquante" : "présente ou non requise",
            (long long)_report.missing_bytes, (long long)_report.elapsed_us, _report.names ? " ; premier : " : "",
            p2_content_report_name(&_report, 0));
    if (self.isViewLoaded) [self render];
    return _passed;
}

- (void)checkAgain {
    if (self.showLauncher && _report.complete) {
        P2LaunchIntent intent = P2LaunchGameMenu;
        if (self.offerContinue) intent = _continueSave ? P2LaunchContinue : P2LaunchCampaign;
        [self prepareSaveAndPlay:YES intent:intent];
        return;
    }
    _button.enabled = NO;
    _status.text = TEXT(@"Vérification…", @"Checking…");
    // Après l'affichage du libellé : la vérification bloque le thread principal
    // quelques dizaines de millisecondes.
    [self performSelector:@selector(checkAgainNow) withObject:nil afterDelay:0.05];
}

- (void)prepareSaveAndPlay:(BOOL)withCloud intent:(P2LaunchIntent)intent {
    if (_passed || (_preparingSaves && withCloud)) return;
    _preparingSaves = YES;
    _pendingLaunch = intent;
    NSUInteger attempt = ++_saveAttempt;
    _button.enabled = NO;
    _menuButton.enabled = NO;
    _saveButton.enabled = NO;
    _playOfflineButton.hidden = !withCloud || !P2SaveBridge.cloudConfigured;
    _saveStatus.text = withCloud && P2SaveBridge.cloudConfigured
        ? TEXT(@"Vérification des sauvegardes iCloud…", @"Checking iCloud saves…")
        : TEXT(@"Vérification des sauvegardes locales…", @"Checking local saves…");
    __weak P2ContentGateController *weakSelf = self;
    [P2SaveBridge prepareWithCloud:withCloud completion:^(BOOL ready) {
        P2ContentGateController *owner = weakSelf;
        if (!owner || owner->_saveAttempt != attempt) return;
        owner->_preparingSaves = NO;
        owner->_playOfflineButton.hidden = YES;
        // The save sync may have just replaced the local generation. Choose
        // the slot only after the writer lease has been acquired.
        owner->_selectedSave = ready && intent != P2LaunchGameMenu
            ? p2_latest_campaign_save(owner->_roots[3], owner->_roots[0]) : nil;
        if (ready && (intent != P2LaunchContinue || owner->_selectedSave)) {
            if (![owner check:"play"]) {
                owner->_selectedSave = nil;
                [P2SaveBridge launchDidNotStart];
            }
        } else if (ready) {
            [P2SaveBridge launchDidNotStart];
            [owner check:"save-changed"];
            owner->_saveStatus.text = TEXT(@"Aucune sauvegarde de campagne valide. Ouvrez les sauvegardes pour vérifier les versions.",
                                           @"No valid campaign save was found. Open Saves to check the available versions.");
            return;
        } else {
            [owner check:"save-check"];
        }
        owner->_saveStatus.text = P2SaveBridge.status;
    }];
}

- (void)playOffline { [self prepareSaveAndPlay:NO intent:_pendingLaunch]; }

- (void)showSaveSettings {
    __weak P2ContentGateController *weakSelf = self;
    [P2SaveBridge presentFrom:self savesChanged:^{
        P2ContentGateController *owner = weakSelf;
        if (!owner || owner->_preparingSaves || owner->_passed) return;
        if (owner->_report.complete && owner.offerContinue)
            owner->_continueSave = p2_latest_campaign_save(owner->_roots[3], owner->_roots[0]);
        owner->_saveStatus.text = P2SaveBridge.status;
        [owner render];
    }];
}

- (void)checkAgainNow { [self check:"check-again"]; }

- (void)openGameMenu {
    [self prepareSaveAndPlay:YES intent:P2LaunchGameMenu];
}

- (void)showFrameRate:(int)limit {
    for (UIButton *choice in _frameRateChoices.arrangedSubviews) {
        choice.selected = choice.tag == limit;
        UIButtonConfiguration *style = choice.configuration;
        style.baseBackgroundColor = libraryColor(choice.selected ? LibraryBlue : LibraryCanvas);
        style.baseForegroundColor = libraryColor(choice.selected ? LibraryPaper : LibraryInk);
        choice.configuration = style;
        choice.accessibilityTraits = UIAccessibilityTraitButton | (choice.selected ? UIAccessibilityTraitSelected : 0);
    }
}

- (void)changeFrameRate:(UIButton *)sender {
    if (self.frameRateOverridden) return;
    int limit = sender.tag == 60 ? 60 : 120;
    NSString *value = limit == 60 ? @"60" : @"120";
    [NSUserDefaults.standardUserDefaults setObject:value forKey:@(P2_IOS_FRAME_RATE_KEY)];
    setenv(P2_IOS_FRAME_RATE_ENV, value.UTF8String, 1);
    [self showFrameRate:limit];
}

- (void)changeShowFPS:(UISwitch *)sender {
    if (self.showFPSOverridden) return;
    [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:@(P2_IOS_SHOW_FPS_KEY)];
    setenv(P2_IOS_SHOW_FPS_ENV, sender.isOn ? "1" : "0", 1);
}

- (UILabel *)label:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}

- (UIStackView *)surfaceWithViews:(NSArray<UIView *> *)views {
    UIStackView *surface = [[UIStackView alloc] initWithArrangedSubviews:views];
    surface.axis = UILayoutConstraintAxisVertical;
    surface.spacing = 10;
    surface.layoutMargins = UIEdgeInsetsMake(14, 14, 14, 14);
    surface.layoutMarginsRelativeArrangement = YES;
    surface.backgroundColor = libraryColor(LibraryPaper);
    surface.layer.cornerRadius = 18;
    surface.layer.borderWidth = 1;
    surface.layer.borderColor = libraryColor(LibraryLine).CGColor;
    return surface;
}

- (UIView *)launcherSettings {
    UIColor *ink = libraryColor(LibraryInk);
    CGFloat settingsGap = 12;
    BOOL accessibleText = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    UILabel *settings = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline] color:ink];
    settings.text = TEXT(@"Réglages", @"Settings");
    settings.accessibilityTraits |= UIAccessibilityTraitHeader;
    UILabel *frameRate = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleBody] color:ink];
    frameRate.text = TEXT(@"Limite d’images par seconde", @"Frame rate limit");
    _frameRateChoices = [[UIStackView alloc] init];
    _frameRateChoices.spacing = 8;
    for (NSNumber *limit in @[@120, @60]) {
        UIButtonConfiguration *style = UIButtonConfiguration.filledButtonConfiguration;
        style.title = [NSString stringWithFormat:TEXT(@"%@ i/s", @"%@ FPS"), limit];
        style.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        UIButton *choice = [UIButton buttonWithConfiguration:style primaryAction:nil];
        choice.tag = limit.integerValue;
        choice.enabled = !self.frameRateOverridden;
        [choice.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
        [choice addTarget:self action:@selector(changeFrameRate:) forControlEvents:UIControlEventTouchUpInside];
        [_frameRateChoices addArrangedSubview:choice];
    }
    [self showFrameRate:rt_ios_requested_frame_rate(rt_ios_is_ipad(), getenv(P2_IOS_FRAME_RATE_ENV))];
    UIStackView *frameRateRow = [[UIStackView alloc] initWithArrangedSubviews:@[frameRate, _frameRateChoices]];
    frameRateRow.axis = accessibleText ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    frameRateRow.alignment = accessibleText ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
    frameRateRow.spacing = settingsGap;
    [_frameRateChoices setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *fpsCounter = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleBody] color:ink];
    fpsCounter.text = TEXT(@"Compteur d’images", @"FPS counter");
    fpsCounter.isAccessibilityElement = NO;
    UISwitch *fpsSwitch = [[UISwitch alloc] init];
    fpsSwitch.on = rt_ios_show_fps(getenv(P2_IOS_SHOW_FPS_ENV));
    fpsSwitch.enabled = !self.showFPSOverridden;
    fpsSwitch.onTintColor = libraryColor(LibraryBlue);
    fpsSwitch.accessibilityLabel = fpsCounter.text;
    [fpsSwitch addTarget:self action:@selector(changeShowFPS:) forControlEvents:UIControlEventValueChanged];
    [fpsSwitch setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *fpsRow = [[UIStackView alloc] initWithArrangedSubviews:@[fpsCounter, fpsSwitch]];
    fpsRow.alignment = UIStackViewAlignmentCenter;
    fpsRow.spacing = settingsGap;
    [fpsRow.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;

    UIView *divider = [[UIView alloc] init];
    divider.backgroundColor = libraryColor(LibraryLine);
    [divider.heightAnchor constraintEqualToConstant:1].active = YES;
    _saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_saveButton setTitle:TEXT(@"Sauvegardes", @"Saves") forState:UIControlStateNormal];
    [_saveButton addTarget:self action:@selector(showSaveSettings) forControlEvents:UIControlEventTouchUpInside];
    _saveStatus = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote] color:ink];
    _saveStatus.numberOfLines = 0;
    _saveStatus.text = P2SaveBridge.status;
    _playOfflineButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_playOfflineButton setTitle:TEXT(@"Jouer hors ligne", @"Play Offline") forState:UIControlStateNormal];
    [_playOfflineButton addTarget:self action:@selector(playOffline) forControlEvents:UIControlEventTouchUpInside];
    _playOfflineButton.hidden = YES;
    return [self surfaceWithViews:@[settings, frameRateRow, divider, fpsRow, _saveButton, _saveStatus, _playOfflineButton]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.view.backgroundColor = libraryColor(LibraryCanvas);
    self.view.tintColor = libraryColor(LibraryBlue);
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    UIColor *ink = libraryColor(LibraryInk), *secondary = libraryColor(LibrarySecondary);
    UILabel *brand = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline] color:secondary];
    brand.text = @"Portal 2";
    UILabel *library = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle] color:ink];
    library.text = TEXT(@"Bibliothèque", @"Library");
    library.accessibilityTraits |= UIAccessibilityTraitHeader;

    P2PortalCoverView *cover = [[P2PortalCoverView alloc] init];
    cover.contentMode = UIViewContentModeRedraw;
    cover.isAccessibilityElement = NO;
    cover.layer.cornerRadius = 12;
    cover.clipsToBounds = YES;
    CGFloat maxCoverHeight = rt_ios_is_ipad() ? 164 : 118;
    NSLayoutConstraint *coverAspect = [cover.heightAnchor constraintEqualToAnchor:cover.widthAnchor multiplier:.30];
    coverAspect.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [cover.heightAnchor constraintGreaterThanOrEqualToConstant:96],
        [cover.heightAnchor constraintLessThanOrEqualToConstant:maxCoverHeight], coverAspect,
    ]];

    _title = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline] color:ink];
    _detail = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleBody] color:ink];
    _names = [self label:[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular] color:secondary];
    _space = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleCallout] color:secondary];
    _heading = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline] color:ink];
    _heading.text = TEXT(@"Copier les fichiers du jeu depuis le Mac", @"Copy the game files from your Mac");
    _help = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleCallout] color:secondary];
    _status = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote] color:secondary];

    UIButtonConfiguration *configuration = UIButtonConfiguration.filledButtonConfiguration;
    configuration.title = TEXT(@"Vérifier à nouveau", @"Check again");
    configuration.buttonSize = UIButtonConfigurationSizeLarge;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    configuration.baseBackgroundColor = libraryColor(LibraryBlue);
    configuration.baseForegroundColor = libraryColor(LibraryPaper);
    configuration.imagePadding = 8;
    __weak P2ContentGateController *weak = self;
    _button = [UIButton buttonWithConfiguration:configuration primaryAction:
        [UIAction actionWithHandler:^(__kindof UIAction *action) { (void)action; [weak checkAgain]; }]];
    [_button setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [_button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    UIButtonConfiguration *menu = UIButtonConfiguration.tintedButtonConfiguration;
    menu.title = TEXT(@"Menu du jeu", @"Game Menu");
    menu.buttonSize = UIButtonConfigurationSizeLarge;
    menu.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    menu.baseForegroundColor = libraryColor(LibraryBlue);
    _menuButton = [UIButton buttonWithConfiguration:menu primaryAction:
        [UIAction actionWithHandler:^(__kindof UIAction *action) { (void)action; [weak openGameMenu]; }]];
    [_menuButton setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [_menuButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    BOOL accessibleActions = self.offerContinue &&
        UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_button, _menuButton, _status]];
    row.axis = accessibleActions ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    row.alignment = accessibleActions ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
    row.spacing = 16;

    UIStackView *game = [self surfaceWithViews:@[cover, _title, row, _detail, _names, _space, _heading, _help]];
    [stack addArrangedSubview:brand];
    [stack setCustomSpacing:2 afterView:brand];
    [stack addArrangedSubview:library];
    [stack addArrangedSubview:game];
    if (self.showLauncher) [stack addArrangedSubview:[self launcherSettings]];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *width = [stack.widthAnchor constraintEqualToConstant:720];
    width.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-18],
        [scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-36],
        width,
    ]];
    [self render];
    // Retour au jeu après le Finder ou les Réglages (espace libéré) : on revérifie.
    _observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) { (void)note; [weak check:"foreground"]; }];
}

// Formulation des archives : sans liste des fichiers lisible, ou pour ce que
// seule la vérification des archives voit.
- (void)archiveParts:(NSMutableArray<NSString *> *)parts {
    const P2ContentReport *r = &_report;
    BOOL fr = french();
    if (r->manifest_bad) [parts addObject:TEXT(@"la liste des fichiers du jeu (" P2_CONTENT_MANIFEST_FILE ") est illisible ou endommagée",
                                               @"the game file list (" P2_CONTENT_MANIFEST_FILE ") is unreadable or damaged")];
    int missing = r->missing_archives, cut = r->short_archives, bad = r->bad_directories, required = r->required_missing;
    if (missing == 1) [parts addObject:[NSString stringWithFormat:TEXT(@"1 archive du jeu sur %d manque",
                                                                      @"1 of %d game archives is missing"), r->archives]];
    else if (missing) [parts addObject:[NSString stringWithFormat:TEXT(@"%d archives du jeu sur %d manquent",
                                                                      @"%d of %d game archives are missing"), missing, r->archives]];
    if (cut) [parts addObject:fr ?
        (cut == 1 ? @"1 archive n’est copiée qu’en partie" : [NSString stringWithFormat:@"%d archives ne sont copiées qu’en partie", cut]) :
        (cut == 1 ? @"1 archive is only partly copied" : [NSString stringWithFormat:@"%d archives are only partly copied", cut])];
    if (bad) [parts addObject:fr ?
        (bad == 1 ? @"1 index d’archives est endommagé ou tronqué" : [NSString stringWithFormat:@"%d index d’archives sont endommagés ou tronqués", bad]) :
        (bad == 1 ? @"1 archive index is damaged or cut short" : [NSString stringWithFormat:@"%d archive indexes are damaged or cut short", bad])];
    if (required) [parts addObject:fr ?
        (required == 1 ? @"1 fichier requis manque" : [NSString stringWithFormat:@"%d fichiers requis manquent", required]) :
        (required == 1 ? @"1 required file is missing" : [NSString stringWithFormat:@"%d required files are missing", required])];
    if (r->maps_missing) [parts addObject:TEXT(@"les cartes de la campagne (game/portal2/maps) manquent",
                                               @"the campaign maps (game/portal2/maps) are missing")];
}

- (void)render {
    const P2ContentReport *r = &_report;
    BOOL fr = french();
    BOOL ready = r->complete != 0;
    BOOL canResume = ready && _continueSave != nil;
    for (UILabel *label in @[_detail, _names, _space, _heading, _help, _status]) label.hidden = ready;
    UIButtonConfiguration *configuration = _button.configuration;
    configuration.title = ready ? (canResume ? TEXT(@"Continuer", @"Continue") : TEXT(@"Jouer", @"Play")) :
        TEXT(@"Vérifier à nouveau", @"Check again");
    configuration.image = [UIImage systemImageNamed:ready ? @"play.fill" : @"arrow.clockwise"];
    _button.configuration = configuration;
    _button.enabled = !_preparingSaves;
    _menuButton.enabled = !_preparingSaves;
    _saveButton.enabled = !_preparingSaves;
    _menuButton.hidden = !canResume;
    if (ready) {
        _title.text = TEXT(@"Prêt à jouer", @"Ready to play");
        _title.textColor = libraryColor(LibraryBlue);
        return;
    }
    NSString *model = UIDevice.currentDevice.model;  // « iPad », « iPhone »
    BOOL nothing = r->required_missing >= 3;
    _title.text = nothing ? TEXT(@"Fichiers du jeu requis", @"Game files required") :
                            TEXT(@"Fichiers du jeu incomplets", @"Game files incomplete");
    _title.textColor = libraryColor(LibraryOrange);

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (nothing) {
        _detail.text = TEXT(@"Portal 2 utilise votre propre copie du jeu : son contenu (game), les fichiers du dépôt "
                            @"Linux (linux) et les images préparées (prep).",
                            @"Portal 2 runs from your own copy of the game: its content (game), the Linux depot "
                            @"files (linux) and the prepared images (prep).");
    } else {
        // Avec la liste des fichiers de l'import : chaque fichier manquant (cartes comprises).
        int listed = r->manifest && !r->manifest_bad ? r->manifest_missing : 0;
        int differ = r->manifest && !r->manifest_bad ? r->manifest_wrong_size : 0;
        if (listed == 1) [parts addObject:[NSString stringWithFormat:TEXT(@"1 fichier du jeu sur %@ manque",
                                                                         @"1 of %@ game files is missing"), count_text(r->manifest_files)]];
        else if (listed) [parts addObject:[NSString stringWithFormat:TEXT(@"%@ fichiers du jeu sur %@ manquent",
                                                                         @"%@ of %@ game files are missing"),
                                           count_text(listed), count_text(r->manifest_files)]];
        if (differ) [parts addObject:fr ?
            (differ == 1 ? @"1 fichier du jeu n’est copié qu’en partie ou diffère de celui du Mac" :
                           [NSString stringWithFormat:@"%@ fichiers du jeu ne sont copiés qu’en partie ou diffèrent de ceux du Mac", count_text(differ)]) :
            (differ == 1 ? @"1 game file is only partly copied or differs from your Mac’s copy" :
                           [NSString stringWithFormat:@"%@ game files are only partly copied or differ from your Mac’s copies", count_text(differ)])];
        // Sans liste lisible, ou ce que seule la vérification des archives voit.
        if (!parts.count) [self archiveParts:parts];
        NSString *text = [parts componentsJoinedByString:fr ? @" ; " : @"; "];
        if (text.length) text = [[text substringToIndex:1].uppercaseString stringByAppendingString:[text substringFromIndex:1]];
        if (r->missing_bytes > 0)
            text = [text stringByAppendingFormat:fr ? @", environ %@" : @", about %@", size_text(r->missing_bytes)];
        _detail.text = [text stringByAppendingString:@"."];
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (int i = 0; i < r->names; ++i) [names addObject:@(p2_content_report_name(r, i))];
    // Une archive manquante est aussi un fichier manquant de la liste : comptée une fois.
    int archive_problems = r->required_missing + r->bad_directories + r->missing_archives + r->short_archives;
    int listed_problems = r->manifest && !r->manifest_bad ? r->manifest_missing + r->manifest_wrong_size : 0;
    int problems = (archive_problems > listed_problems ? archive_problems : listed_problems) + r->manifest_bad + r->maps_missing;
    _names.text = names.count ? [NSString stringWithFormat:@"%@%@%@", TEXT(@"Manquants ou endommagés : ", @"Missing or damaged: "),
                                 [names componentsJoinedByString:@", "], problems > (int)names.count ? @", …" : @""] : nil;
    _names.hidden = names.count == 0;

    NSMutableString *space = [NSMutableString string];
    if (r->volume_available >= 0) {
        [space appendString:fr ? [NSString stringWithFormat:@"Espace libre sur cet %@ : %@", model, size_text(r->volume_available)]
                               : [NSString stringWithFormat:@"Free space on this %@: %@", model, size_text(r->volume_available)]];
        if (r->volume_total > 0) [space appendFormat:fr ? @" sur %@" : @" of %@", size_text(r->volume_total)];
        [space appendString:@"."];
    }
    if (r->missing_bytes > 0) {
        [space appendFormat:fr ? @" Nécessaire : environ %@." : @" Needed: about %@.", size_text(r->missing_bytes)];
        if (r->volume_available >= 0 && r->volume_available < r->missing_bytes)
            [space appendFormat:fr ? @" Libérez d’abord au moins %@ (Réglages › Général › Stockage %@)."
                                   : @" Free up at least %@ in Settings › General › %@ Storage first.",
                                size_text(r->missing_bytes - r->volume_available), model];
    }
    _space.text = [space stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    BOOL short_space = r->volume_available >= 0 && r->missing_bytes > r->volume_available;
    _space.textColor = short_space ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;

    _help.text = fr ?
        [NSString stringWithFormat:@"Le plus simple : branchez cet %@ au Mac et lancez tools/ios_device.sh data dans le dossier "
            @"portal2-avp. Ou ouvrez-le dans le Finder, choisissez Fichiers et copiez sur Portal 2 des dossiers nommés game "
            @"(le contenu de Portal 2), linux (le dépôt Linux) et prep (build/game/prep). Revenez ensuite et touchez "
            @"« Vérifier à nouveau ».", model] :
        [NSString stringWithFormat:@"Easiest: connect this %@ to your Mac and run tools/ios_device.sh data in the portal2-avp "
            @"folder. Or open it in Finder, choose Files, and copy folders named game (the Portal 2 content), linux (the Linux "
            @"depot) and prep (build/game/prep) onto Portal 2. Then come back and tap Check again.", model];

    NSString *time = [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle
                                                    timeStyle:NSDateFormatterMediumStyle];
    _status.text = [NSString stringWithFormat:TEXT(@"Vérifié à %@ : toujours incomplet.", @"Checked at %@: still incomplete."), time];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
@end

void rt_ios_content_gate(const char *game, const char *linux_root, const char *prep,
                         const char *documents, const char *user_dir, int show_launcher,
                         int frame_rate_overridden, int show_fps_overridden,
                         char resume_save[P2_CAMPAIGN_SAVE_STEM_SIZE]) {
    @autoreleasepool {
        if (user_dir) [P2SaveBridge configureUserDirectory:[NSString stringWithUTF8String:user_dir]];
        const char *roots[4] = {game, linux_root, prep, documents};
        P2ContentGateController *gate = [[P2ContentGateController alloc] initWithRoots:roots];
        gate.showLauncher = show_launcher;
        gate.offerContinue = resume_save != NULL;
        gate.frameRateOverridden = frame_rate_overridden;
        gate.showFPSOverridden = show_fps_overridden;
        if ([gate check:"launch"]) return;
        if (!gate.showLauncher && gate.contentReady) gate.showLauncher = YES;
        // SDL_main tourne déjà dans la boucle d'UIKit (cycle de vie classique,
        // sans UIScene) : une fenêtre à nous, et la boucle d'exécution tourne
        // ici, comme SDL_PumpEvents, jusqu'à une vérification réussie.
        UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        window.rootViewController = gate;
        [window makeKeyAndVisible];
        while (!gate.passed) {
            @autoreleasepool {
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            }
        }
        if (resume_save && gate.selectedSave)
            snprintf(resume_save, P2_CAMPAIGN_SAVE_STEM_SIZE, "%s", gate.selectedSave.UTF8String);
        window.hidden = YES;
        window.rootViewController = nil;
        fputs("[ios] contenu du jeu complet : démarrage du moteur\n", stderr);
    }
}
#endif
