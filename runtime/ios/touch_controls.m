// Commandes tactiles de Portal 2 sur iPhone/iPad.
//
// Une surcouche UIKit posée sur la fenêtre de SDL, affichée en partie
// seulement : quand l'interface du jeu est visible (menus, pause, écrans de
// chargement ; game_state.c le demande au moteur), elle s'efface et laisse les
// doigts à SDL, pour qui un toucher est un clic. En partie, elle traduit les
// doigts en ce que le jeu comprend par défaut, clavier et souris :
// - stick gauche : déplacement analogique, par une manette SDL virtuelle
//   (axe gauche) que le jeu lit comme une manette Xbox : direction continue,
//   vitesse proportionnelle à l'inclinaison. À défaut de manette virtuelle
//   (création refusée par SDL), touches W/A/S/D en 8 directions ;
// - stick droit : caméra, mouvements de souris relatifs à vitesse
//   proportionnelle à l'inclinaison (courbe quadratique pour viser finement) ;
//   chaque stick se centre là où le doigt se pose, dans sa moitié d'écran ;
//   un bouton bascule la moitié droite en trackpad : le glissement du doigt
//   devient directement le mouvement de souris (choix retenu entre parties,
//   P2TouchTrackpad dans les réglages de l'app) ;
// - portails : tapes au dos (ci-dessous) ; sans capteur de mouvement
//   (simulateur) ou avec P2_BACKTAP=0, une paire de boutons bleu (clic gauche)
//   / orange (clic droit) dans chaque coin du haut ; sur iPad, exactement deux
//   ovales horizontaux en quinconce sous le pouce droit, dans le coin du bas
//   (bleu en bas vers l'intérieur, orange plus haut contre le bord) ;
// - icônes : sauter (espace), s'accroupir (Ctrl gauche), utiliser (E),
//   pause (Échap) ; sur iPad, les trois premières entourent les ovales dans le
//   coin bas droit, et le mode de caméra tient le coin bas gauche sous le stick
//   (disposition : touch_router.c) ;
// - tapes au dos ou sur les côtés du téléphone (index derrière, en paysage) :
//   à gauche portail bleu, à droite orange ; détection dans back_tap.c,
//   nourrie ici par CoreMotion (P2_BACKTAP=0 la coupe, réglages dans
//   docs/ios.md).
// Avec une manette ou un clavier connecté, elle se cache jusqu'au premier
// toucher ; avec une vraie manette, la manette virtuelle est retirée pour que
// le jeu ne lise qu'elle.
// La propriété des doigts, la disposition et l'état tenu sont dans
// touch_router.c (testé sur l'hôte) : tout ce qui est tenu est relâché à
// l'ouverture d'un menu, à la connexion d'une manette ou d'un clavier, au
// départ en arrière-plan et à chaque nouvelle disposition (rotation, zone
// sûre) ; un doigt resté posé ne retire pas ensuite. Les événements SDL sont
// poussés sur le thread principal, celui du jeu. P2_TOUCH_CONTROLS=0 la désactive, =1 l'affiche toujours ; P2_TOUCH_LOOK règle la vitesse
// de la caméra (1 par défaut, stick et trackpad).
//
// Disposition et dessin inspirés de la manette tactile de TOTK de
// MacNativeGames (games/totk/ios/Sources/touch_pad.m, licence MIT).
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <CoreMotion/CoreMotion.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <SDL.h>
#include <SDL_syswm.h>
#include <math.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "back_tap.h"
#include "touch_router.h"

int rt_ios_game_ui_visible(void);   // game_state.c
extern unsigned long rt_ios_frames;  // gl_ios.m : images présentées
void rt_ios_move_response_linear(int on);
int rt_ios_move_response(void);
void rt_ios_console_command(const char *name);   // game_state.c


// Manette virtuelle : deux axes seulement (stick gauche), aucun bouton, pour
// qu'elle ne porte aucune autre commande que le déplacement.
static SDL_Joystick *virtual_pad(void) {
    SDL_VirtualJoystickDesc desc = {0};
    desc.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    desc.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    desc.naxes = 2;
    desc.axis_mask = (1u << SDL_CONTROLLER_AXIS_LEFTX) | (1u << SDL_CONTROLLER_AXIS_LEFTY);
    desc.name = "Commandes tactiles";
    int index = SDL_JoystickAttachVirtualEx(&desc);
    SDL_Joystick *pad = index < 0 ? NULL : SDL_JoystickOpen(index);
    if (index >= 0 && !pad) SDL_JoystickDetachVirtual(index);
    fprintf(stderr, "[ios] manette virtuelle : %s\n", pad ? "créée" : SDL_GetError());
    return pad;
}
static void remove_virtual_pad(SDL_Joystick *pad) {
    SDL_JoystickID id = SDL_JoystickInstanceID(pad);
    SDL_JoystickClose(pad);
    for (int i = 0; i < SDL_NumJoysticks(); ++i)
        if (SDL_JoystickGetDeviceInstanceID(i) == id) { SDL_JoystickDetachVirtual(i); break; }
    fprintf(stderr, "[ios] manette virtuelle retirée\n");
}

static const CGFloat kKnobSize = 54;
static NSString *const kTrackpadKey = @"P2TouchTrackpad";

static float env_float(const char *name, float def, float min) {
    const char *e = getenv(name); return e && atof(e) >= min ? (float)atof(e) : def;
}
// P2_TOUCH_LOOK : vitesse de la caméra. Accélération du trackpad : gain 1 sous
// P2_TOUCH_ACCEL_LOW pt/s (visée fine inchangée), puis montée en douceur
// jusqu'à P2_TOUCH_ACCEL (multiplicateur maximal) à P2_TOUCH_ACCEL_HIGH pt/s ;
// vitesse du doigt lissée (P2_TOUCH_ACCEL_SMOOTH, poids du nouvel
// échantillon). P2_TOUCH_ACCEL=1 la coupe.
static rt_touch_tuning touch_tuning(void) {
    rt_touch_tuning t;
    rt_touch_tuning_defaults(&t);
    t.look_speed = env_float("P2_TOUCH_LOOK", t.look_speed, 0.01f);
    t.accel_max = env_float("P2_TOUCH_ACCEL", t.accel_max, 1);
    t.accel_low = env_float("P2_TOUCH_ACCEL_LOW", t.accel_low, 0);
    t.accel_high = env_float("P2_TOUCH_ACCEL_HIGH", t.accel_high, t.accel_low + 1);
    if (t.accel_high <= t.accel_low) t.accel_high = t.accel_low + 1;
    t.accel_smooth = fminf(1, env_float("P2_TOUCH_ACCEL_SMOOTH", t.accel_smooth, 0.01f));
    t.log = getenv("P2_TOUCH_ACCEL_LOG") != NULL;
    fprintf(stderr, "[ios] trackpad : gain %.2f à %g pt/s, %.2f à %g, %.2f à %g, %.2f à 3000 pt/s\n",
        rt_touch_trackpad_gain(&t, 100), 100.0, rt_touch_trackpad_gain(&t, 600), 600.0,
        rt_touch_trackpad_gain(&t, 1000), 1000.0, rt_touch_trackpad_gain(&t, 3000));
    return t;
}

// La boucle de SDL (CFRunLoopRunInMode à délai nul) ne laisse jamais UIKit
// valider ses transactions : un dessin demandé n'apparaîtrait pas. Forcé ici.
static void redraw(UIView *view) {
    [view setNeedsDisplay];
    [view.layer displayIfNeeded];
    [CATransaction flush];
}

// ---- tapes au dos (CoreMotion) ----
// Échantillons de mouvement (accélération utilisateur, rotation, gravité) sur
// une file dédiée, jugés par back_tap.c ; une tape acceptée est déposée dans
// backtap_pending et cliquée par la minuterie de la surcouche (step), qui
// connaît l'état menu/jeu. Les débuts et fins de toucher arrivent du thread
// principal : verrou autour du détecteur. Pas d'autorisation à demander pour
// ces capteurs (seule l'activité physique, CMMotionActivityManager, en exige une).
static CMMotionManager *backtap_motion;
static NSOperationQueue *backtap_queue;
static os_unfair_lock backtap_lock = OS_UNFAIR_LOCK_INIT;
static rt_backtap backtap_detector;
static _Atomic int backtap_orient;    // +1 : axe y de l'appareil vers la droite de l'écran
static _Atomic int backtap_active;    // en partie, surcouche affichée
static _Atomic int backtap_pending;   // tape à cliquer : -1 gauche, +1 droite
static int backtap_log;               // P2_BACKTAP_LOG=1 : chaque candidat, et le bruit toutes les 5 s
static float backtap_hold;            // s : durée de l'appui
// P2_BACKTAP_RAW=<fichier> (relatif à HOME) : échantillons et touchers bruts,
// rejoués sur le Mac par tools/backtap_replay.c pour régler les seuils.
static FILE *backtap_raw;
// Journal, sur la file des capteurs seulement : origine des temps, bruit de fond.
static struct { double origin, window, last_t, sq; float last_a[3], max_a, max_jerk, max_rot; long samples; } backtap_noise;

static int env_sign(const char *name, int def) {
    const char *e = getenv(name);
    return !e || !*e ? def : atoi(e) > 0 ? 1 : atoi(e) < 0 ? -1 : 0;
}

static void backtap_log_report(const rt_backtap_report *r, double origin) {
    char touch[32], verdict[80];
    if (fabs(r->touch_dt) < 10) snprintf(touch, sizeof(touch), "%+.0f ms", r->touch_dt * 1000);
    else snprintf(touch, sizeof(touch), "aucun");
    if (r->reject) snprintf(verdict, sizeof(verdict), "rejet : %s", r->reject);
    else snprintf(verdict, sizeof(verdict), "%s (%s%s)", r->side < 0 ? "GAUCHE, portail bleu" : "DROITE, portail orange",
                  r->method, r->gyro ? ", gyroscope" : "");
    fprintf(stderr, "[ios] tape %.3f s : pic %.2f g (x %+.2f y %+.2f z %+.2f), secousse %.0f g/s, "
            "rotation x %+.2f y %+.2f z %+.2f rad/s, montée %.0f ms, durée %.0f ms, avant %.3f g, "
            "gravité %.2f g (x %+.2f y %+.2f z %+.2f), "
            "toucher %s, orientation %+d -> %s\n",
            r->t - origin, r->peak, r->acc[0], r->acc[1], r->acc[2], r->jerk, r->rot[0], r->rot[1], r->rot[2],
            r->rise * 1000, r->width * 1000, r->pre_rms, r->gravity, r->grav[0], r->grav[1], r->grav[2], touch,
            r->orient, verdict);
}

// Mode journal : chaque candidat jugé, et toutes les 5 s le bruit de fond
// (maxima et moyenne quadratique) pour placer les seuils au-dessus du jeu normal.
static void backtap_log_sample(const rt_backtap_sample *s, const rt_backtap_report *r) {
    typeof(backtap_noise) *n = &backtap_noise;
    if (!n->origin) { n->origin = n->window = s->t; fprintf(stderr, "[ios] tapes au dos : origine des temps %.3f s\n", s->t); }
    if (r) backtap_log_report(r, n->origin);
    float mag = sqrtf(s->a[0] * s->a[0] + s->a[1] * s->a[1] + s->a[2] * s->a[2]);
    if (n->samples && s->t > n->last_t) {
        float da[3] = {s->a[0] - n->last_a[0], s->a[1] - n->last_a[1], s->a[2] - n->last_a[2]};
        n->max_jerk = fmaxf(n->max_jerk, sqrtf(da[0] * da[0] + da[1] * da[1] + da[2] * da[2]) / (float)(s->t - n->last_t));
    }
    n->max_a = fmaxf(n->max_a, mag); n->max_rot = fmaxf(n->max_rot, fabsf(s->w[0])); n->sq += (double)mag * mag;
    memcpy(n->last_a, s->a, sizeof(n->last_a)); n->last_t = s->t; ++n->samples;
    if (s->t - n->window < 5) return;
    fprintf(stderr, "[ios] tapes au dos, bruit %.0f-%.0f s : %.0f Hz, acc max %.3f g (moy. quadr. %.3f), "
            "secousse max %.1f g/s, rotation x max %.2f rad/s, %s\n",
            n->window - n->origin, s->t - n->origin, n->samples / (s->t - n->window), n->max_a, sqrt(n->sq / n->samples),
            n->max_jerk, n->max_rot, atomic_load(&backtap_active) ? "en partie" : "menu");
    n->window = s->t; n->sq = 0; n->max_a = n->max_jerk = n->max_rot = 0; n->samples = 0;
}

// Démarre les capteurs (thread principal). Sans capteur (simulateur) : rien.
static void backtap_start(void) {
    const char *off = getenv("P2_BACKTAP");
    if (backtap_motion || (off && *off == '0')) return;
    CMMotionManager *motion = [CMMotionManager new];
    if (!motion.deviceMotionAvailable) {
        fprintf(stderr, "[ios] tapes au dos : pas de capteur de mouvement (simulateur ?)\n");
        return;
    }
    rt_backtap_params p;
    rt_backtap_defaults(&p);
    // Sensibilité (Réglages : 0,75 / 1 / 1,33) : seuils de détection divisés
    // d'autant ; les variables par seuil, ci-dessous, priment.
    float k = env_float("P2_BACKTAP_SENSITIVITY", 1, 0.1f);
    p.accel_min /= k; p.jerk_min /= k; p.gyro_accel_min /= k; p.gyro_rot_min /= k;
    p.accel_min = env_float("P2_BACKTAP_ACCEL", p.accel_min, 0.001f);
    p.jerk_min = env_float("P2_BACKTAP_JERK", p.jerk_min, 0);
    p.rot_min = env_float("P2_BACKTAP_ROT", p.rot_min, 0.001f);
    p.side_x_weight = env_float("P2_BACKTAP_SIDE_X", p.side_x_weight, 0);
    p.gyro_accel_min = env_float("P2_BACKTAP_GYRO_ACCEL", p.gyro_accel_min, 0.001f);
    p.gyro_rot_min = env_float("P2_BACKTAP_GYRO_ROT", p.gyro_rot_min, 0.001f);
    p.gyro_jerk_min = env_float("P2_BACKTAP_GYRO_JERK", p.gyro_jerk_min, 0);
    p.gyro_calm_max = env_float("P2_BACKTAP_GYRO_CALM", p.gyro_calm_max, 0);
    p.refractory = env_float("P2_BACKTAP_REFRACTORY", p.refractory, 0);
    p.touch_guard = env_float("P2_BACKTAP_TOUCH_GUARD", p.touch_guard, 0);
    p.max_width = env_float("P2_BACKTAP_WIDTH", p.max_width, 0.001f);
    p.flat_z = env_float("P2_BACKTAP_FLAT", p.flat_z, -2);
    p.pre_rms_max = env_float("P2_BACKTAP_AGITATION", p.pre_rms_max, 0.001f);
    p.gravity_max = env_float("P2_BACKTAP_GRAVITY", p.gravity_max, 0.001f);
    p.lateral_sign = env_sign("P2_BACKTAP_LATERAL", p.lateral_sign);
    p.z_sign = env_sign("P2_BACKTAP_ZSIGN", p.z_sign);
    p.invert = env_sign("P2_BACKTAP_INVERT", 0) > 0;
    backtap_log = getenv("P2_BACKTAP_LOG") && *getenv("P2_BACKTAP_LOG") != '0';
    backtap_hold = env_float("P2_BACKTAP_HOLD", 0.05f, 0);
    const char *raw = getenv("P2_BACKTAP_RAW");
    if (raw && *raw) {
        char path[1024];
        snprintf(path, sizeof(path), "%s%s%s", raw[0] == '/' ? "" : getenv("HOME"), raw[0] == '/' ? "" : "/", raw);
        backtap_raw = fopen(path, "w");
        fprintf(stderr, "[ios] tapes au dos : enregistrement brut %s%s\n", path, backtap_raw ? "" : " impossible");
        if (backtap_raw) setvbuf(backtap_raw, NULL, _IOLBF, 0);   // tout est écrit si le jeu est tué
        if (backtap_raw) fprintf(backtap_raw, "# m t ax ay az wx wy wz gx gy gz orient active | t t_toucher\n");
    }
    float hz = env_float("P2_BACKTAP_HZ", 200, 10);
    rt_backtap_init(&backtap_detector, &p);

    backtap_queue = [NSOperationQueue new];
    backtap_queue.name = @"p2.backtap";
    backtap_queue.maxConcurrentOperationCount = 1;
    backtap_queue.qualityOfService = NSQualityOfServiceUserInteractive;
    motion.deviceMotionUpdateInterval = 1.0 / hz;
    fprintf(stderr, "[ios] tapes au dos : %g Hz demandés ; seuils %.3g g, %.3g g/s, rotation %.3g rad/s ; "
            "gyroscope %.3g g, %.3g rad/s, %.3g rad/s² ; "
            "réfractaire %.0f ms, toucher ±%.0f ms, à plat sous %.2f g, durée %.0f ms, agitation %.3g g, gravité %.3g g ; "
            "latéral %+d, z %+d, inversé %d, appui %.0f ms%s\n",
            hz, p.accel_min, p.jerk_min, p.rot_min, p.gyro_accel_min, p.gyro_rot_min, p.gyro_jerk_min, p.refractory * 1e3, p.touch_guard * 1e3, p.flat_z, p.max_width * 1e3,
            p.pre_rms_max, p.gravity_max, p.lateral_sign, p.z_sign, p.invert, backtap_hold * 1e3,
            backtap_log ? ", journal" : "");
    [motion startDeviceMotionUpdatesToQueue:backtap_queue withHandler:^(CMDeviceMotion *m, NSError *error) {
        if (!m) { if (error) fprintf(stderr, "[ios] tapes au dos : %s\n", error.localizedDescription.UTF8String); return; }
        CMAcceleration a = m.userAcceleration, g = m.gravity;
        CMRotationRate w = m.rotationRate;
        rt_backtap_sample s = {m.timestamp, {(float)a.x, (float)a.y, (float)a.z},
                               {(float)w.x, (float)w.y, (float)w.z}, {(float)g.x, (float)g.y, (float)g.z}};
        rt_backtap_report r;
        os_unfair_lock_lock(&backtap_lock);
        if (backtap_raw)
            fprintf(backtap_raw, "m %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %d %d\n", s.t, s.a[0], s.a[1], s.a[2],
                    s.w[0], s.w[1], s.w[2], s.g[0], s.g[1], s.g[2], atomic_load(&backtap_orient), atomic_load(&backtap_active));
        int judged = rt_backtap_feed(&backtap_detector, &s, atomic_load(&backtap_orient), atomic_load(&backtap_active), &r);
        os_unfair_lock_unlock(&backtap_lock);
        if (judged && !r.reject) atomic_store(&backtap_pending, r.side);
        if (backtap_log) backtap_log_sample(&s, judged ? &r : NULL);
    }];
    backtap_motion = motion;
}
static void backtap_touch(NSSet<UITouch *> *touches) {
    if (!backtap_motion) return;
    os_unfair_lock_lock(&backtap_lock);
    for (UITouch *t in touches) {
        rt_backtap_touch(&backtap_detector, t.timestamp);
        if (backtap_raw) fprintf(backtap_raw, "t %.4f\n", t.timestamp);
    }
    os_unfair_lock_unlock(&backtap_lock);
}

@interface P2TouchControls : UIView
- (instancetype)initWithWindow:(SDL_Window *)window;
- (void)sendAction:(rt_touch_action)action down:(BOOL)down;
- (void)lookBy:(int)dx y:(int)dy;
- (void)updateMove;
- (void)lookModeChanged:(BOOL)trackpad;
@end

// Sorties du routeur, sur le thread principal (doigts, minuterie, notifications).
static void sink_action(void *ctx, rt_touch_action action, int down) {
    [(__bridge P2TouchControls *)ctx sendAction:action down:down != 0];
}
static void sink_look(void *ctx, int dx, int dy) { [(__bridge P2TouchControls *)ctx lookBy:dx y:dy]; }
static void sink_move(void *ctx, float x, float y) { (void)x; (void)y; [(__bridge P2TouchControls *)ctx updateMove]; }
static void sink_look_mode(void *ctx, int trackpad) { [(__bridge P2TouchControls *)ctx lookModeChanged:trackpad != 0]; }

@implementation P2TouchControls {
    SDL_Window *window;
    rt_touch_router router;   // doigts, disposition, état tenu (touch_router.c)
    BOOL wasd[4];             // W, A, S, D enfoncées
    BOOL devices;             // manette ou clavier présents (dernier état connu)
    NSTimer *tick;            // caméra : un pas par image tant que le stick est incliné
    BOOL physicalPad;         // vraie manette connectée
    BOOL isPad;               // iPad : boutons de portail par défaut
    int fps;                  // compteur d'images affiché (0 : rien à afficher)
    int fpsHidden;            // masqué : P2_SHOW_FPS=0 (Réglages) ou toucher du coin haut gauche
    unsigned long fpsFrames;  // images au dernier relevé
    CFTimeInterval fpsAt;     // instant du dernier relevé
    SDL_Joystick *pad;        // manette virtuelle du stick gauche (NULL : W/A/S/D)
    BOOL padRefused;          // création refusée : ne pas réessayer à chaque image
    Sint16 padAxes[2];        // dernières valeurs envoyées
    int padResponse;          // courbe du jeu pour ces valeurs (joy_response_move)
    CGFloat testMove;         // essai : inclinaison avant imposée (P2_TOUCH_TEST_MOVE)
    Uint64 testNext;          // essai : prochaine étape (ms de SDL)
    int testPhase;            // essai : étape en cours
    int backtapHeld;          // tape au dos : action tenue (rt_touch_action), -1 aucune
    CFTimeInterval backtapAt; // tape au dos : instant de l'appui
    unsigned long backtapFrames; // tape au dos : images présentées à l'appui
}

- (instancetype)initWithWindow:(SDL_Window *)sdlWindow {
    if ((self = [super initWithFrame:CGRectZero])) {
        window = sdlWindow;
        self.multipleTouchEnabled = YES; self.backgroundColor = UIColor.clearColor; self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
        isPad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
        rt_touch_tuning tuning = touch_tuning();
        rt_touch_sink sink = {(__bridge void *)self, sink_action, sink_look, sink_move, sink_look_mode};
        rt_touch_init(&router, &tuning, &sink, [NSUserDefaults.standardUserDefaults boolForKey:kTrackpadKey]);
        router.menu = rt_ios_game_ui_visible() != 0;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification,
                                          GCKeyboardDidConnectNotification, GCKeyboardDidDisconnectNotification])
            [center addObserver:self selector:@selector(devicesChanged) name:name object:nil];
        // Appel, Centre de contrôle, arrière-plan : rien ne reste tenu.
        for (NSNotificationName name in @[UIApplicationWillResignActiveNotification,
                                          UIApplicationDidEnterBackgroundNotification])
            [center addObserver:self selector:@selector(resignActive) name:name object:nil];
        [center addObserver:self selector:@selector(becomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        backtapHeld = -1;
        const char *show = getenv("P2_SHOW_FPS");   // posée par les Réglages (runtime/ios/settings.c)
        fpsHidden = show && !strcmp(show, "0");
        backtap_start();
        [self devicesChanged];
        __weak P2TouchControls *weakSelf = self;
        tick = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
            (void)timer; [weakSelf step];
        }];
    }
    return self;
}

- (void)devicesChanged {
    BOOL gamepad = NO;
    for (GCController *c in GCController.controllers) gamepad |= c.extendedGamepad != nil;
    // Manette que le jeu verra (sauf pilote MFi de SDL coupé, SDL_JOYSTICK_MFI=0).
    physicalPad = gamepad && SDL_GetHintBoolean(SDL_HINT_JOYSTICK_MFI, SDL_TRUE);
    BOOL any = gamepad || GCKeyboard.coalescedKeyboard != nil;
    const char *force = getenv("P2_TOUCH_CONTROLS");   // 1 : jamais cachée (essais sur simulateur)
    if (force && *force == '1') any = NO;
    if (any == devices) return;
    // Connexion : cachée, tout relâché (la manette prend la main). Déconnexion :
    // affichée, sans rien de tenu ; un toucher la rappelle aussi.
    devices = any;
    [self releaseAll];
    rt_touch_set_hidden(&router, any);
    redraw(self);
}
- (void)resignActive {
    rt_touch_set_active(&router, 0);
    [self backTapRelease:YES];
    redraw(self);
}
- (void)becomeActive {
    rt_touch_set_active(&router, 1);   // doigts neufs seulement
    redraw(self);
}

// Disposition dans la zone sûre de la vue (encoche, coins arrondis, indicateur).
- (CGRect)area { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (rt_touch_layout)currentLayout {
    CGRect b = self.bounds, a = self.area;
    rt_touch_layout l;
    rt_touch_layout_make(&l, (rt_touch_rect){(float)b.origin.x, (float)b.origin.y, (float)b.size.width, (float)b.size.height},
                         (rt_touch_rect){(float)a.origin.x, (float)a.origin.y, (float)a.size.width, (float)a.size.height},
                         rt_touch_portal_buttons(getenv("P2_PORTAL_BUTTONS"), isPad, backtap_motion != nil), isPad);
    return l;
}

// À chaque image : rester devant la vue OpenGL de SDL (ajoutée après la
// fenêtre), suivre la taille de la fenêtre, tourner la caméra.
- (void)step {
    UIView *host = self.superview;
    BOOL ui = rt_ios_game_ui_visible() != 0;
    if (ui != router.menu) {
        if (ui) [self backTapRelease:YES];
        rt_touch_set_menu(&router, ui);   // menu : tout relâché, doigts à SDL
        redraw(self);
    }
    [self updateFPS];
    [self syncPad];
    if (pad && rt_ios_move_response() != padResponse) { padResponse = rt_ios_move_response(); [self updateMove]; }
    [self testStep];
    [self backTapStep];
    if (host.subviews.lastObject != self) [host bringSubviewToFront:self];
    if (!CGRectEqualToRect(self.frame, host.bounds)) { self.frame = host.bounds; redraw(self); }
    rt_touch_layout layout = [self currentLayout];
    if (rt_touch_set_layout(&router, &layout)) { [self backTapRelease:YES]; redraw(self); }
    rt_touch_frame(&router);
}
// Mouvement de souris relatif (comptes entiers ; fractions reportées par le routeur).
- (void)lookBy:(int)dx y:(int)dy {
    SDL_Event e = {0};
    e.type = SDL_MOUSEMOTION; e.motion.windowID = SDL_GetWindowID(window);
    e.motion.xrel = dx; e.motion.yrel = dy;
    SDL_PushEvent(&e);
}
// Tape au dos acceptée : appui, puis relâchement après P2_BACKTAP_HOLD et au
// moins deux images (vgui ignore un clic dont l'appui et le relâchement
// tombent dans la même image). Passe par le routeur comme un appui tenu : si
// un doigt tient déjà ce portail, rien n'est renvoyé au jeu.
- (void)backTapStep {
    if (!backtap_motion) return;
    UIInterfaceOrientation o = self.window.windowScene.interfaceOrientation;
    atomic_store(&backtap_orient, o == UIInterfaceOrientationLandscapeLeft ? 1 : o == UIInterfaceOrientationLandscapeRight ? -1 : 0);
    BOOL live = !router.menu && !router.hidden && router.active;
    atomic_store(&backtap_active, live);
    int side = atomic_exchange(&backtap_pending, 0);
    if (side && live && backtapHeld < 0) {
        backtapHeld = side < 0 ? RT_TOUCH_FIRE_BLUE : RT_TOUCH_FIRE_ORANGE;
        backtapAt = CACurrentMediaTime(); backtapFrames = rt_ios_frames;
        rt_touch_external(&router, (rt_touch_action)backtapHeld, 1);
        redraw(self);   // le bouton du portail s'allume
    }
    [self backTapRelease:NO];
}
- (void)backTapRelease:(BOOL)now {
    if (backtapHeld < 0) return;
    if (!now && (CACurrentMediaTime() - backtapAt < backtap_hold || rt_ios_frames < backtapFrames + 2)) return;
    rt_touch_external(&router, (rt_touch_action)backtapHeld, 0);   // déjà relâché par une annulation : sans effet
    backtapHeld = -1;
    redraw(self);
}
- (void)lookModeChanged:(BOOL)trackpad {
    [NSUserDefaults.standardUserDefaults setBool:trackpad forKey:kTrackpadKey];
    redraw(self);
}

// Hors partie, les doigts passent à la vue de SDL (clics dans les menus).
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return rt_touch_takes_touches(&router) ? [super hitTest:point withEvent:event] : nil;
}
- (void)releaseAll {
    rt_touch_cancel_all(&router);
    [self backTapRelease:YES];
}

// ---- événements SDL ----
- (void)key:(SDL_Scancode)code down:(BOOL)down {
    SDL_Event e = {0};
    e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
    e.key.windowID = SDL_GetWindowID(window); e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
    e.key.keysym.scancode = code; e.key.keysym.sym = SDL_GetKeyFromScancode(code);
    SDL_PushEvent(&e);
}
// Position en points de la fenêtre SDL (sdl_ios.m la convertit en pixels).
- (void)mouseButton:(Uint8)button down:(BOOL)down at:(CGPoint)p {
    SDL_Event e = {0};
    e.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
    e.button.windowID = SDL_GetWindowID(window); e.button.button = button;
    e.button.state = down ? SDL_PRESSED : SDL_RELEASED; e.button.clicks = 1;
    e.button.x = (Sint32)p.x; e.button.y = (Sint32)p.y;
    SDL_PushEvent(&e);
}
// Transitions seulement (le routeur compte les doigts) : commandes par défaut
// du jeu, sans toucher aux liaisons du joueur.
- (void)sendAction:(rt_touch_action)action down:(BOOL)down {
    CGPoint centre = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    switch (action) {
    case RT_TOUCH_JUMP: [self key:SDL_SCANCODE_SPACE down:down]; break;
    case RT_TOUCH_CROUCH: [self key:SDL_SCANCODE_LCTRL down:down]; break;
    case RT_TOUCH_USE: [self key:SDL_SCANCODE_E down:down]; break;
    case RT_TOUCH_PAUSE: [self key:SDL_SCANCODE_ESCAPE down:down]; break;
    case RT_TOUCH_FIRE_BLUE: [self mouseButton:SDL_BUTTON_LEFT down:down at:centre]; break;
    case RT_TOUCH_FIRE_ORANGE: [self mouseButton:SDL_BUTTON_RIGHT down:down at:centre]; break;
    default: break;
    }
}
- (void)setDirections:(const BOOL *)wanted {
    static const SDL_Scancode codes[4] = {SDL_SCANCODE_W, SDL_SCANCODE_A, SDL_SCANCODE_S, SDL_SCANCODE_D};
    for (int i = 0; i < 4; ++i)
        if (wanted[i] != wasd[i]) { wasd[i] = wanted[i]; [self key:codes[i] down:wanted[i]]; }
}

// ---- déplacement ----
- (void)updateMove {
    CGFloat ax = router.move[0], ay = router.move[1];
    int keys[4];
    rt_touch_move_keys((float)ax, (float)ay, keys);
    BOOL wanted[4] = {keys[0] != 0, keys[1] != 0, keys[2] != 0, keys[3] != 0};
    if (testMove) {   // essai (testStep)
        static double angle = -1;
        if (angle < 0) { const char *e = getenv("P2_TOUCH_TEST_ANGLE"); angle = e ? atof(e) * M_PI / 180 : 0; }
        ax = testMove * sin(angle); ay = testMove * cos(angle);
        memset(wanted, 0, sizeof(wanted)); wanted[testMove > 0 ? 0 : 2] = YES;
    }
    if (pad) { [self padX:ax y:ay]; memset(wanted, 0, sizeof(wanted)); }
    [self setDirections:wanted];
}

// Mode d'essai, sans toucher l'écran (simulateur) : P2_TOUCH_TEST_MOVE="0.5,1"
// incline le stick de chaque valeur (négative : vers l'arrière) pendant
// P2_TOUCH_TEST_SECONDS (2 par défaut), après P2_TOUCH_TEST_DELAY secondes de
// partie (20 par défaut), trois secondes de repos entre deux ; direction
// P2_TOUCH_TEST_ANGLE (degrés, 0 vers l'avant, 90 à droite). La surcouche n'est
// alors pas dessinée. Vitesse lue à l'écran avec « +cl_showpos 1 » ; avec
// « +sv_cheats 1 +host_framerate 0.0166667 », la physique est celle de 60
// images/s malgré la lenteur du simulateur. P2_TOUCH_TEST_WASD=1 garde les
// touches W/A/S/D (témoin). Sur simulateur, SDL_JOYSTICK_MFI=0 écarte la
// manette MFi « Gamepad » qu'il expose et que le jeu prendrait avant celle-ci.
// P2_TOUCH_TEST_CLICK="s,x,y" : clic gauche (points de la fenêtre SDL) s secondes
// après le premier affichage d'un menu, pour ouvrir un écran sans toucher.
- (void)testClick {
    static double at = -1, x, y; static Uint64 when; static int step;
    if (at == -1) { const char *e = getenv("P2_TOUCH_TEST_CLICK");
        if (!e || sscanf(e, "%lf,%lf,%lf", &at, &x, &y) != 3 || at <= 0) at = -2; }
    if (at <= 0 || !router.menu) return;
    Uint64 now = SDL_GetTicks64();
    if (!when) { when = now + (Uint64)(at * 1000); return; }
    if (now < when) return;
    CGPoint p = CGPointMake(x, y);
    if (step == 0) {   // survol, puis appui et relâchement sur des images distinctes
        SDL_Event e = {0};
        e.type = SDL_MOUSEMOTION; e.motion.windowID = SDL_GetWindowID(window);
        e.motion.x = (Sint32)x; e.motion.y = (Sint32)y;
        SDL_PushEvent(&e);
    } else if (step == 1) [self mouseButton:SDL_BUTTON_LEFT down:YES at:p];
    else { [self mouseButton:SDL_BUTTON_LEFT down:NO at:p]; at = -2; }
    fprintf(stderr, "[ios] essai clic %d à (%.0f, %.0f), %llu ms\n", step, x, y, (unsigned long long)now);
    ++step; when = now + 300;
}
- (void)testStep {
    [self testClick];
    static const char *plan; static double seconds, delay; static int parsed;
    if (!parsed) {
        parsed = 1; plan = getenv("P2_TOUCH_TEST_MOVE");
        const char *e = getenv("P2_TOUCH_TEST_SECONDS"); seconds = e && atof(e) > 0 ? atof(e) : 2;
        e = getenv("P2_TOUCH_TEST_DELAY"); delay = e && atof(e) >= 0 ? atof(e) : 20;
    }
    if (!plan || !*plan) return;
    Uint64 now = SDL_GetTicks64();
    if (router.menu || (!pad && !padRefused)) { testNext = 0; return; }   // en partie, manette prête
    if (!testNext) { testNext = now + (Uint64)(delay * 1000); testPhase = 0; return; }
    if (now < testNext) return;
    // Étapes paires : début d'inclinaison ; impaires : fin et repos.
    const char *at = plan;
    for (int i = 0; i < testPhase / 2 && at; ++i) { at = strchr(at, ','); if (at) ++at; }
    if (!at || !*at) { if (testMove) { testMove = 0; [self updateMove]; } return; }
    BOOL start = testPhase % 2 == 0;
    testMove = start ? atof(at) : 0;
    fprintf(stderr, "[ios] essai stick : %s inclinaison %.2f à %llu ms\n", start ? "début" : "fin", atof(at),
            (unsigned long long)now);
    [self updateMove];
    testNext = now + (Uint64)((start ? seconds : 3.0) * 1000);
    ++testPhase;
}

// ---- manette virtuelle ----
// Présente tant qu'aucune vraie manette n'est connectée, une fois les manettes
// de SDL initialisées par le jeu (inputsystem) : elle lui arrive comme une
// manette branchée en cours de partie.
- (void)syncPad {
    if (getenv("P2_TOUCH_TEST_WASD")) padRefused = YES;   // essai témoin : touches W/A/S/D
    BOOL wanted = !physicalPad && !padRefused && SDL_WasInit(SDL_INIT_GAMECONTROLLER);
    if (wanted && !pad) {
        if (!(pad = virtual_pad())) padRefused = YES;
        rt_ios_move_response_linear(pad != NULL);
        padAxes[0] = padAxes[1] = 0;
        [self updateMove];
    } else if (!wanted && pad) {
        remove_virtual_pad(pad);
        pad = NULL;
        rt_ios_move_response_linear(0);
        [self updateMove];   // le stick repasse aux touches
    }
}
// Inclinaison (-1..1 après zone morte, y vers le haut) -> axe gauche de SDL
// (y vers le bas). Le jeu (in_joystick.cpp du client) calcule par axe
// t = (|axe| - 0,15) / 0,85 (seuils joy_forwardthreshold/joy_sidethreshold),
// applique la courbe joy_response_move puis avance de 175 × t unités/s
// (mesuré dans le simulateur). On inverse ce calcul pour que la vitesse suive
// l'inclinaison, de 40 à 175 unités/s : sous 40, le frottement du sol de
// Source l'emporte sur l'accélération (sv_friction × sv_stopspeed /
// sv_accelerate) et le joueur ne fait que glisser.
static const CGFloat kMinWalk = 40.0 / 175, kAxisThreshold = .15;
// Composante de vitesse voulue (-1..1, en vitesse de marche) -> axe SDL.
static Sint16 axis_value(CGFloat speed, int response) {
    CGFloat s = fmin(1, fabs(speed)), t = s;
    if (s < 1e-3) return 0;
    // Réponse 5 (si le passage en linéaire a échoué) : t réduit de moitié
    // jusqu'à 0,6 ; les vitesses entre 30 et 60 % sont inaccessibles, la plus
    // proche est prise.
    if (response != 0) t = s <= .3 ? 2 * s : s < .45 ? .6 : fmax(s, .601);
    return (Sint16)lround(copysign(kAxisThreshold + (1 - kAxisThreshold) * fmin(1, t), speed) * 32767);
}
- (void)padX:(CGFloat)x y:(CGFloat)y {
    CGFloat d = fmin(1, hypot(x, y)), m = d > 0 ? (kMinWalk + (1 - kMinWalk) * d) / d : 0;
    int response = rt_ios_move_response();
    Sint16 v[2] = {axis_value(x * m, response), axis_value(-y * m, response)};
    for (int i = 0; i < 2; ++i)
        if (v[i] != padAxes[i]) { padAxes[i] = v[i]; SDL_JoystickSetVirtualAxis(pad, i, v[i]); }
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    rt_touch_set_hidden(&router, 0);   // un toucher ramène la surcouche cachée pour une manette
    backtap_touch(touches);   // un toucher secoue le téléphone : pas de tape au dos autour
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        // Coin haut gauche : affiche ou masque le compteur d'images, choix gardé
        // dans les réglages (clé P2ShowFPS de la page Réglages).
        rt_touch_rect c = router.layout.fps_corner;
        if (CGRectContainsPoint(CGRectMake(c.x, c.y, c.w, c.h), p)) {
            fpsHidden = !fpsHidden;
            [NSUserDefaults.standardUserDefaults setBool:!fpsHidden forKey:@"P2ShowFPS"];
            fps = 0; fpsAt = 0;
            continue;
        }
        rt_touch_down(&router, (uintptr_t)(__bridge void *)t, (rt_touch_point){(float)p.x, (float)p.y}, t.timestamp);
    }
    redraw(self);
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        rt_touch_moved(&router, (uintptr_t)(__bridge void *)t, (rt_touch_point){(float)p.x, (float)p.y}, t.timestamp);
    }
    redraw(self);
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    backtap_touch(touches);
    for (UITouch *t in touches) rt_touch_up(&router, (uintptr_t)(__bridge void *)t);
    redraw(self);
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self touchesEnded:touches withEvent:event]; }
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; redraw(self); }   // disposition suivante : step

// ---- dessin ----
- (void)drawStick:(CGContextRef)c right:(BOOL)right ink:(UIColor *)ink {
    CGFloat r = router.layout.stick_radius;
    rt_touch_point rest = router.layout.rest[right ? 1 : 0], start = rest, at = rest;
    rt_touch_role_points(&router, right ? RT_TOUCH_LOOK : RT_TOUCH_MOVE, &start, &at);
    CGPoint origin = CGPointMake(start.x, start.y), knob = CGPointMake(at.x, at.y);
    CGFloat dx = knob.x - origin.x, dy = knob.y - origin.y, dist = hypot(dx, dy);
    if (dist > r) knob = CGPointMake(origin.x + dx * r / dist, origin.y + dy * r / dist);
    CGContextSetStrokeColorWithColor(c, ink.CGColor); CGContextSetFillColorWithColor(c, ink.CGColor);
    CGContextStrokeEllipseInRect(c, CGRectMake(origin.x - r, origin.y - r, 2 * r, 2 * r));
    CGContextFillEllipseInRect(c, CGRectMake(knob.x - kKnobSize / 2, knob.y - kKnobSize / 2, kKnobSize, kKnobSize));
}
// Compteur d'images, relevé deux fois par seconde (redessiner l'incrustation
// coûte : seulement quand la valeur change). P2_SHOW_FPS=0 (Réglages) le masque.
- (void)updateFPS {
    if (fpsHidden) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (!fpsAt) { fpsAt = now; fpsFrames = rt_ios_frames; return; }
    if (now - fpsAt < .5) return;
    int value = (int)lround((double)(rt_ios_frames - fpsFrames) / (now - fpsAt));
    fpsAt = now; fpsFrames = rt_ios_frames;
    if (value != fps) { fps = value; redraw(self); }
}
// Police pixel 5×7 du compteur : chiffres et « FPS », une ligne par octet
// (bit 4 : colonne de gauche), dessinée carré par carré sans lissage.
static const char kPixelChars[] = "0123456789FPS";
static const uint8_t kPixelGlyphs[][7] = {
    {0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E}, {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E},
    {0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F}, {0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E},
    {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02}, {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E},
    {0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E}, {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08},
    {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E}, {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C},
    {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10}, {0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10},
    {0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E},
};
static const CGFloat kPixel = 2;   // points par pixel de la police (6 pixels d'écran sur un iPhone ×3)
static void draw_pixel_text(CGContextRef c, const char *text, CGPoint at) {
    for (int i = 0; text[i]; ++i) {
        const char *glyph = strchr(kPixelChars, text[i]);
        if (!glyph || !text[i]) continue;   // espace
        const uint8_t *rows = kPixelGlyphs[glyph - kPixelChars];
        for (int y = 0; y < 7; ++y)
            for (int x = 0; x < 5; ++x)
                if (rows[y] & (0x10 >> x)) CGContextFillRect(c, CGRectMake(at.x + (i * 6 + x) * kPixel, at.y + y * kPixel, kPixel, kPixel));
    }
}
// En haut à gauche, dans la zone sûre (hors de l'arrondi et de l'encoche).
- (CGRect)fpsBox:(NSString *)text {
    CGRect a = self.area;
    CGFloat margin = 2 * kPixel;
    return CGRectMake(round(CGRectGetMinX(a) + 8), round(CGRectGetMinY(a) + 8),
                      (text.length * 6 - 1) * kPixel + 2 * margin, 7 * kPixel + 2 * margin);
}
- (void)drawFPS {
    if (fps <= 0) return;
    NSString *text = [NSString stringWithFormat:@"%d FPS", fps];
    CGRect box = [self fpsBox:text];
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSaveGState(c);
    CGContextSetShouldAntialias(c, NO);
    CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:0 alpha:.5].CGColor);
    CGContextFillRect(c, box);
    // Vert au-dessus de 55 i/s, jaune au-dessus de 30, rouge en dessous.
    UIColor *ink = fps >= 55 ? [UIColor colorWithRed:.45 green:1 blue:.35 alpha:1]
                 : fps >= 30 ? [UIColor colorWithRed:1 green:.85 blue:.2 alpha:1]
                             : [UIColor colorWithRed:1 green:.35 blue:.3 alpha:1];
    CGPoint at = CGPointMake(box.origin.x + 2 * kPixel, box.origin.y + 2 * kPixel);
    CGContextSetFillColorWithColor(c, UIColor.blackColor.CGColor);   // ombre d'un pixel
    draw_pixel_text(c, text.UTF8String, CGPointMake(at.x + kPixel / 3, at.y + kPixel / 3));
    CGContextSetFillColorWithColor(c, ink.CGColor);
    draw_pixel_text(c, text.UTF8String, at);
    CGContextRestoreGState(c);
}
- (void)drawRect:(CGRect)rect {
    (void)rect;
    if (!router.hidden) [self drawFPS];   // aussi dans les menus
    if (router.hidden || router.menu || getenv("P2_TOUCH_TEST_MOVE")) return;   // essai : écran dégagé
    CGContextRef c = UIGraphicsGetCurrentContext();
    UIColor *ink = [UIColor colorWithWhite:1 alpha:.3], *line = [UIColor colorWithWhite:1 alpha:.45];
    UIColor *blue = [UIColor colorWithRed:.16 green:.55 blue:1 alpha:.6], *orange = [UIColor colorWithRed:1 green:.55 blue:.05 alpha:.6];
    UIColor *shade = [UIColor colorWithWhite:0 alpha:.35];   // fond sombre : icônes lisibles sur un mur clair
    CGContextSetLineWidth(c, 2);
    [self drawStick:c right:NO ink:ink];
    if (!router.trackpad) [self drawStick:c right:YES ink:ink];
    for (int i = 0; i < router.layout.count; ++i) {
        const rt_touch_button *b = &router.layout.buttons[i];
        NSString *symbol = nil; UIColor *color = shade, *glow = UIColor.whiteColor;
        switch (b->action) {
        case RT_TOUCH_FIRE_BLUE: color = glow = blue; break;
        case RT_TOUCH_FIRE_ORANGE: color = glow = orange; break;
        case RT_TOUCH_JUMP: symbol = @"arrow.up"; break;
        case RT_TOUCH_CROUCH: symbol = @"arrow.down"; break;
        case RT_TOUCH_USE: symbol = @"hand.point.up.left.fill"; break;
        case RT_TOUCH_PAUSE: symbol = @"pause.fill"; break;
        // L'icône montre le mode actuel de la caméra.
        case RT_TOUCH_LOOK_MODE: symbol = router.trackpad ? @"hand.draw.fill" : @"r.joystick.fill"; break;
        default: break;
        }
        // Ellipse du routeur : ovale horizontal pour un portail, cercle sinon.
        CGRect box = CGRectMake(b->at.x - b->w / 2, b->at.y - b->h / 2, b->w, b->h);
        // Tenu (doigt, tape au dos) : fond presque opaque. Sur iPad, où le pouce
        // couvre le bouton, s'y ajoutent un contour blanc épais et un halo de
        // la couleur du bouton qui dépasse du pouce ; le téléphone garde son dessin.
        BOOL held = rt_touch_held(&router, b->action) != 0, bold = held && router.layout.pad;
        UIColor *fill = held ? [color colorWithAlphaComponent:.9] : color;
        CGContextSetFillColorWithColor(c, fill.CGColor); CGContextFillEllipseInRect(c, box);
        CGContextSetLineWidth(c, bold ? 3 : 2);
        CGContextSetStrokeColorWithColor(c, (bold ? [UIColor colorWithWhite:1 alpha:.95] : line).CGColor);
        CGContextStrokeEllipseInRect(c, box);
        if (bold) {
            CGContextSetStrokeColorWithColor(c, [glow colorWithAlphaComponent:.55].CGColor);
            CGContextStrokeEllipseInRect(c, CGRectInset(box, -5, -5));
        }
        if (!symbol) continue;
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:b->h * .38
                                                                                             weight:UIImageSymbolWeightBold];
        UIImage *icon = [[UIImage systemImageNamed:symbol withConfiguration:config]
                         imageWithTintColor:[UIColor colorWithWhite:1 alpha:.85] renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGSize z = icon.size;
        [icon drawInRect:CGRectMake(b->at.x - z.width / 2, b->at.y - z.height / 2, z.width, z.height)];
    }
}
@end

static P2TouchControls *controls;

// Appelé à la création de la fenêtre du jeu (sdl_ios.m), sur le thread principal.
void rt_ios_touch_controls_attach(SDL_Window *window) {
    const char *off = getenv("P2_TOUCH_CONTROLS");
    if (controls || !window || (off && *off == '0')) return;
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_UIKIT) {
        fprintf(stderr, "[ios] commandes tactiles : fenêtre UIKit introuvable (%s)\n", SDL_GetError());
        return;
    }
    // Sur la fenêtre elle-même : SDL remplace la vue de son contrôleur par la vue
    // OpenGL à la création du contexte, ce qui retirerait une sous-vue posée là.
    UIView *host = info.info.uikit.window;
    if (!host) return;
    controls = [[P2TouchControls alloc] initWithWindow:window];
    controls.frame = host.bounds;
    [host addSubview:controls];
}
#endif
