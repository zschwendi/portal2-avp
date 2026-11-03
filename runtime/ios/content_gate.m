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

@interface P2ContentGateController : UIViewController
@property(nonatomic, readonly) BOOL passed;
- (instancetype)initWithRoots:(const char *const *)roots;
- (BOOL)check:(const char *)trigger;
@end

@implementation P2ContentGateController {
    char *_roots[4];  // game, linux, prep, documents (copies; NULL: absente)
    BOOL _documentsLayout;  // racines par défaut (Documents/game, linux, prep) : liste des fichiers vérifiée aussi
    P2ContentReport _report;
    UILabel *_title, *_detail, *_names, *_space, *_help, *_status;
    UIButton *_button;
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

- (void)dealloc {
    if (_observer) [NSNotificationCenter.defaultCenter removeObserver:_observer];
    for (int i = 0; i < 4; ++i) free(_roots[i]);
}

// Vérifie, ajoute l'espace du volume, écrit Documents/portal2-setup-status.json
// (lu à distance par devicectl) et met l'écran à jour.
- (BOOL)check:(const char *)trigger {
    if (_documentsLayout) p2_content_check(_roots[3], &_report);
    else p2_content_check_roots(_roots[0], _roots[1], _roots[2], &_report);
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
            .engine_started = _report.complete,  // complet : main_ios.c lance le moteur juste après
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
    _passed = _report.complete != 0;
    if (self.isViewLoaded) [self render];
    return _passed;
}

- (void)checkAgain {
    _button.enabled = NO;
    _status.text = TEXT(@"Vérification…", @"Checking…");
    // Après l'affichage du libellé : la vérification bloque le thread principal
    // quelques dizaines de millisecondes.
    [self performSelector:@selector(checkAgainNow) withObject:nil afterDelay:0.05];
}

- (void)checkAgainNow { [self check:"check-again"]; }

- (UILabel *)label:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
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

    _title = [self label:[UIFont systemFontOfSize:26 weight:UIFontWeightBold] color:UIColor.labelColor];
    _detail = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleBody] color:UIColor.labelColor];
    _names = [self label:[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular] color:UIColor.secondaryLabelColor];
    _space = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleCallout] color:UIColor.secondaryLabelColor];
    UILabel *heading = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline] color:UIColor.labelColor];
    heading.text = TEXT(@"Copier les fichiers du jeu depuis le Mac", @"Copy the game files from your Mac");
    _help = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleCallout] color:UIColor.secondaryLabelColor];
    _status = [self label:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote] color:UIColor.secondaryLabelColor];

    UIButtonConfiguration *configuration = UIButtonConfiguration.filledButtonConfiguration;
    configuration.title = TEXT(@"Vérifier à nouveau", @"Check again");
    configuration.buttonSize = UIButtonConfigurationSizeLarge;
    __weak P2ContentGateController *weak = self;
    _button = [UIButton buttonWithConfiguration:configuration primaryAction:
        [UIAction actionWithHandler:^(__kindof UIAction *action) { (void)action; [weak checkAgain]; }]];
    [_button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_button, _status]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 16;

    for (UIView *view in @[_title, _detail, _names, _space, heading, _help, row]) [stack addArrangedSubview:view];
    [stack setCustomSpacing:24 afterView:_space];
    [stack setCustomSpacing:24 afterView:_help];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *width = [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-64];
    width.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:32],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:720],
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
    NSString *model = UIDevice.currentDevice.model;  // « iPad », « iPhone »
    BOOL nothing = r->required_missing >= 3;
    _title.text = nothing ?
        (fr ? [NSString stringWithFormat:@"Les fichiers de Portal 2 ne sont pas encore sur cet %@", model]
            : [NSString stringWithFormat:@"Portal 2’s game files aren’t on this %@ yet", model]) :
        TEXT(@"Les fichiers de Portal 2 sont incomplets", @"Portal 2’s game files are incomplete");

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
    _button.enabled = YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
@end

void rt_ios_content_gate(const char *game, const char *linux_root, const char *prep, const char *documents) {
    @autoreleasepool {
        const char *roots[4] = {game, linux_root, prep, documents};
        P2ContentGateController *gate = [[P2ContentGateController alloc] initWithRoots:roots];
        if ([gate check:"launch"]) return;
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
        window.hidden = YES;
        window.rootViewController = nil;
        fputs("[ios] contenu du jeu complet : démarrage du moteur\n", stderr);
    }
}
#endif
