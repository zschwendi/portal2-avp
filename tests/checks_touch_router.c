// Commandes tactiles iOS (runtime/ios/touch_router.c, C portable, testé ici
// sur l'hôte) : propriété des doigts, relâchements (annulation, menu, manette,
// arrière-plan, rotation) et disposition sur des écrans de téléphone et d'iPad
// (celle du téléphone inchangée, celle de l'iPad en bas contre les coins).
// La surcouche UIKit elle-même (touch_controls.m) n'est pas exercée ici.
#include "checks.h"
#include <math.h>
#include <string.h>
#include "../runtime/ios/touch_router.c"

typedef struct {
    int down[RT_TOUCH_ACTION_COUNT], up[RT_TOUCH_ACTION_COUNT];
    int looks, look_x, look_y, modes, trackpad;
    float mx, my; int moves;
} Log;
static void log_action(void *ctx, rt_touch_action a, int down) {
    Log *l = ctx;
    if (down) ++l->down[a]; else ++l->up[a];
}
static void log_look(void *ctx, int dx, int dy) { Log *l = ctx; ++l->looks; l->look_x += dx; l->look_y += dy; }
static void log_move(void *ctx, float x, float y) { Log *l = ctx; l->mx = x; l->my = y; ++l->moves; }
static void log_mode(void *ctx, int trackpad) { Log *l = ctx; ++l->modes; l->trackpad = trackpad; }

static rt_touch_point pt(float x, float y) { return (rt_touch_point){x, y}; }

// iPhone 15 en paysage : 852×393, encoche à gauche (59 pt), indicateur en bas (21 pt).
static const rt_touch_rect kPhone = {0, 0, 852, 393}, kPhoneSafe = {59, 0, 734, 372};
static const rt_touch_rect kPhoneFlippedSafe = {59, 0, 734, 372 - 1};   // autre côté : zone sûre différente

static void setup(rt_touch_router *r, Log *log, int portals) {
    memset(log, 0, sizeof(*log));
    rt_touch_sink sink = {log, log_action, log_look, log_move, log_mode};
    rt_touch_init(r, NULL, &sink, 0);
    rt_touch_layout l;
    rt_touch_layout_make(&l, kPhone, kPhoneSafe, portals, 0);
    rt_touch_set_layout(r, &l);
}
static rt_touch_point center(const rt_touch_router *r, rt_touch_action a) {
    for (int i = 0; i < r->layout.count; ++i) if (r->layout.buttons[i].action == a) return r->layout.buttons[i].at;
    assert(!"bouton absent");
    return pt(0, 0);
}
static int all_released(const rt_touch_router *r, const Log *l) {
    for (int a = 0; a < RT_TOUCH_ACTION_COUNT; ++a) {
        if (r->emitted[a]) return 0;
        if (a != RT_TOUCH_LOOK_MODE && l->down[a] != l->up[a]) return 0;
    }
    return r->move[0] == 0 && r->move[1] == 0 && l->mx == 0 && l->my == 0;
}

// Géométrie des boutons : ellipses dessinées, agrandies de `grow` pt.
static int inside(const rt_touch_button *b, rt_touch_point p, float grow) {
    float dx = (p.x - b->at.x) / (b->w / 2 + grow), dy = (p.y - b->at.y) / (b->h / 2 + grow);
    return dx * dx + dy * dy < 1;
}
static rt_touch_point on_outline(const rt_touch_button *b, float grow, int step, int steps) {
    float t = (float)step * (2 * (float)M_PI / (float)steps);
    return pt(b->at.x + (b->w / 2 + grow) * cosf(t), b->at.y + (b->h / 2 + grow) * sinf(t));
}
// Deux formes agrandies sans point commun (contours échantillonnés tous les 2°).
static int apart(const rt_touch_button *a, float grow_a, const rt_touch_button *b, float grow_b) {
    if (inside(b, a->at, grow_b) || inside(a, b->at, grow_a)) return 0;
    for (int i = 0; i < 180; ++i)
        if (inside(b, on_outline(a, grow_a, i, 180), grow_b) || inside(a, on_outline(b, grow_b, i, 180), grow_a)) return 0;
    return 1;
}
// Bouton de cette action dans la moitié gauche (side < 0) ou droite (side > 0), sinon NULL.
static const rt_touch_button *side_button(const rt_touch_layout *l, rt_touch_action a, int side) {
    float mid = l->bounds.x + l->bounds.w / 2;
    for (int i = 0; i < l->count; ++i)
        if (l->buttons[i].action == a && (l->buttons[i].at.x > mid) == (side > 0)) return &l->buttons[i];
    return NULL;
}

// Quatre doigts à la fois : déplacement, caméra, saut, portail bleu ; chacun
// garde son rôle et se relâche seul, dans n'importe quel ordre.
RT_CHECK(touch_router_multi_finger_release) {
    rt_touch_router r; Log l; setup(&r, &l, 1);
    rt_touch_point stick = pt(200, 250), cam = pt(560, 300);
    rt_touch_down(&r, 1, stick, 0);
    rt_touch_down(&r, 2, cam, 0);
    rt_touch_down(&r, 3, center(&r, RT_TOUCH_JUMP), 0);
    rt_touch_down(&r, 4, center(&r, RT_TOUCH_FIRE_BLUE), 0);
    assert(rt_touch_finger_count(&r) == 4);
    rt_touch_moved(&r, 1, pt(200, 250 - 60), .01);   // vers l'avant
    assert(l.my > .5f && fabsf(l.mx) < 1e-3f);
    assert(l.down[RT_TOUCH_JUMP] == 1 && l.down[RT_TOUCH_FIRE_BLUE] == 1);
    rt_touch_moved(&r, 2, pt(560 + 60, 300), .01);
    rt_touch_frame(&r);
    assert(l.looks == 1 && l.look_x > 0 && l.look_y == 0);
    // Un doigt qui glisse hors de son bouton le garde tenu (pas de saut répété).
    rt_touch_moved(&r, 3, pt(400, 200), .02);
    assert(rt_touch_held(&r, RT_TOUCH_JUMP) && l.down[RT_TOUCH_JUMP] == 1);
    rt_touch_up(&r, 4);
    assert(l.up[RT_TOUCH_FIRE_BLUE] == 1 && rt_touch_held(&r, RT_TOUCH_JUMP));
    rt_touch_up(&r, 1);
    assert(l.mx == 0 && l.my == 0 && rt_touch_held(&r, RT_TOUCH_JUMP));
    rt_touch_up(&r, 3);
    assert(l.up[RT_TOUCH_JUMP] == 1);
    rt_touch_up(&r, 2);
    int looks = l.looks; rt_touch_frame(&r);
    assert(l.looks == looks && all_released(&r, &l));
    // Deux doigts sur le même bouton : un seul appui, relâché au dernier.
    rt_touch_down(&r, 5, center(&r, RT_TOUCH_CROUCH), 1);
    rt_touch_down(&r, 6, center(&r, RT_TOUCH_CROUCH), 1);
    rt_touch_up(&r, 5);
    assert(l.down[RT_TOUCH_CROUCH] == 1 && l.up[RT_TOUCH_CROUCH] == 0);
    rt_touch_up(&r, 6);
    assert(l.up[RT_TOUCH_CROUCH] == 1);
    // Second doigt sur un stick déjà tenu : ignoré, sans voler le premier.
    rt_touch_down(&r, 7, pt(150, 250), 2);
    rt_touch_down(&r, 8, pt(250, 300), 2);
    assert(rt_touch_finger_count(&r) == 1);
    rt_touch_up(&r, 8);
    rt_touch_moved(&r, 7, pt(150 + 60, 250), 2.1);
    assert(l.mx > .5f);
    rt_touch_up(&r, 7);
    // Identifiant réutilisé sans fin reçue : l'ancien rôle s'arrête, pas de double appui.
    rt_touch_down(&r, 9, center(&r, RT_TOUCH_USE), 3);
    rt_touch_down(&r, 9, center(&r, RT_TOUCH_USE), 3);
    assert(l.down[RT_TOUCH_USE] == 1 && rt_touch_finger_count(&r) == 1);
    rt_touch_up(&r, 9);
    assert(all_released(&r, &l));
    // Plus de doigts que la table n'en suit : rien ne casse, tout se relâche.
    for (uintptr_t id = 100; id < 100 + RT_TOUCH_MAX_FINGERS + 4; ++id)
        rt_touch_down(&r, id, center(&r, RT_TOUCH_JUMP), 4);
    for (uintptr_t id = 100; id < 100 + RT_TOUCH_MAX_FINGERS + 4; ++id) rt_touch_up(&r, id);
    assert(all_released(&r, &l) && rt_touch_finger_count(&r) == 0);
}

// Annulation par UIKit d'un doigt, puis de tous (appel, Centre de contrôle) :
// tout ce qui était tenu est relâché une fois ; les doigts oubliés qui
// continuent de bouger ou se lèvent ensuite ne renvoient rien.
RT_CHECK(touch_router_cancel_releases_and_forgets) {
    rt_touch_router r; Log l; setup(&r, &l, 1);
    rt_touch_down(&r, 1, pt(200, 250), 0);
    rt_touch_moved(&r, 1, pt(140, 250), .01);
    rt_touch_down(&r, 2, center(&r, RT_TOUCH_FIRE_ORANGE), 0);
    rt_touch_down(&r, 3, center(&r, RT_TOUCH_CROUCH), 0);
    rt_touch_up(&r, 3);   // touchesCancelled d'un seul doigt
    assert(l.up[RT_TOUCH_CROUCH] == 1 && rt_touch_held(&r, RT_TOUCH_FIRE_ORANGE));
    rt_touch_cancel_all(&r);
    assert(all_released(&r, &l) && l.up[RT_TOUCH_FIRE_ORANGE] == 1);
    rt_touch_cancel_all(&r);   // deuxième annulation : rien de plus
    assert(l.up[RT_TOUCH_FIRE_ORANGE] == 1);
    int moves = l.moves;
    rt_touch_moved(&r, 1, pt(100, 250), .02);
    rt_touch_moved(&r, 2, center(&r, RT_TOUCH_FIRE_ORANGE), .02);
    rt_touch_up(&r, 2); rt_touch_up(&r, 1);
    assert(l.moves == moves && l.down[RT_TOUCH_FIRE_ORANGE] == 1 && all_released(&r, &l));
}

// Menu ou pause ouverts : la surcouche rend les doigts à SDL (clics de menu),
// relâche tout, et le doigt resté sur le bouton de tir ne retire pas au retour.
RT_CHECK(touch_router_menu_vs_game_route) {
    rt_touch_router r; Log l; setup(&r, &l, 1);
    assert(rt_touch_takes_touches(&r));
    rt_touch_down(&r, 1, center(&r, RT_TOUCH_FIRE_BLUE), 0);
    rt_touch_down(&r, 2, center(&r, RT_TOUCH_PAUSE), 0);
    rt_touch_down(&r, 3, pt(200, 250), 0);
    rt_touch_moved(&r, 3, pt(200, 190), .01);
    assert(l.down[RT_TOUCH_PAUSE] == 1 && l.my > 0);
    rt_touch_set_menu(&r, 1);   // le jeu affiche son menu (game_state.c)
    assert(!rt_touch_takes_touches(&r) && all_released(&r, &l));
    rt_touch_down(&r, 4, center(&r, RT_TOUCH_JUMP), .1);   // au menu : rien
    assert(l.down[RT_TOUCH_JUMP] == 0 && rt_touch_finger_count(&r) == 0);
    rt_touch_set_menu(&r, 0);   // retour en partie, doigts encore posés
    assert(rt_touch_takes_touches(&r));
    rt_touch_moved(&r, 1, center(&r, RT_TOUCH_FIRE_BLUE), .2);
    rt_touch_moved(&r, 3, pt(200, 150), .2);
    rt_touch_frame(&r);
    assert(l.down[RT_TOUCH_FIRE_BLUE] == 1 && all_released(&r, &l));
    rt_touch_up(&r, 1); rt_touch_up(&r, 2); rt_touch_up(&r, 3);
    rt_touch_down(&r, 5, center(&r, RT_TOUCH_FIRE_BLUE), .3);   // nouvel appui : nouveau tir
    assert(l.down[RT_TOUCH_FIRE_BLUE] == 2);
    rt_touch_up(&r, 5);
    assert(all_released(&r, &l));
}

// Rotation (paysage gauche/droite : l'encoche change de côté) ou nouvelle zone
// sûre : les boutons bougent sous les doigts, tout est relâché ; une
// disposition identique ne relâche rien.
RT_CHECK(touch_router_rotation_releases) {
    rt_touch_router r; Log l; setup(&r, &l, 1);
    rt_touch_down(&r, 1, center(&r, RT_TOUCH_CROUCH), 0);
    rt_touch_down(&r, 2, pt(200, 250), 0);
    rt_touch_moved(&r, 2, pt(260, 250), .01);
    rt_touch_layout same;
    rt_touch_layout_make(&same, kPhone, kPhoneSafe, 1, 0);
    assert(rt_touch_set_layout(&r, &same) == 0 && rt_touch_held(&r, RT_TOUCH_CROUCH) && l.mx > 0);
    rt_touch_layout flipped;
    rt_touch_layout_make(&flipped, kPhone, kPhoneFlippedSafe, 1, 0);
    assert(rt_touch_set_layout(&r, &flipped) == 1 && all_released(&r, &l));
    rt_touch_moved(&r, 2, pt(300, 250), .02);
    assert(l.mx == 0);
    // Changer l'affichage des boutons de portail aussi.
    rt_touch_down(&r, 3, center(&r, RT_TOUCH_JUMP), .1);
    rt_touch_layout without;
    rt_touch_layout_make(&without, kPhone, kPhoneFlippedSafe, 0, 0);
    assert(rt_touch_set_layout(&r, &without) == 1 && all_released(&r, &l));
    assert(rt_touch_button_at(&r.layout, center(&r, RT_TOUCH_JUMP)) == RT_TOUCH_JUMP);
}

// Manette ou clavier connectés : surcouche cachée, tout relâché, tapes au dos
// sans effet ; un toucher la rappelle. Arrière-plan : tout relâché, rien accepté.
RT_CHECK(touch_router_controller_handoff_and_background) {
    rt_touch_router r; Log l; setup(&r, &l, 0);
    rt_touch_down(&r, 1, center(&r, RT_TOUCH_JUMP), 0);
    rt_touch_external(&r, RT_TOUCH_FIRE_ORANGE, 1);   // tape au dos
    assert(l.down[RT_TOUCH_FIRE_ORANGE] == 1);
    rt_touch_set_hidden(&r, 1);   // DualSense connectée
    assert(all_released(&r, &l));
    rt_touch_external(&r, RT_TOUCH_FIRE_ORANGE, 0);   // relâchement tardif de la tape : sans effet
    rt_touch_external(&r, RT_TOUCH_FIRE_BLUE, 1);     // tape cachée : ignorée
    assert(l.down[RT_TOUCH_FIRE_BLUE] == 0 && all_released(&r, &l));
    rt_touch_up(&r, 1);
    assert(rt_touch_takes_touches(&r));   // cachée : un toucher la rappelle
    rt_touch_down(&r, 2, center(&r, RT_TOUCH_USE), 1);
    assert(!r.hidden && l.down[RT_TOUCH_USE] == 1);
    // Une tape au dos et un doigt sur la même action : tenue jusqu'au dernier.
    rt_touch_external(&r, RT_TOUCH_USE, 1);
    rt_touch_up(&r, 2);
    assert(rt_touch_held(&r, RT_TOUCH_USE) && l.up[RT_TOUCH_USE] == 0);
    rt_touch_external(&r, RT_TOUCH_USE, 0);
    assert(l.up[RT_TOUCH_USE] == 1);
    // Arrière-plan avec des doigts posés.
    rt_touch_down(&r, 3, pt(200, 250), 2);
    rt_touch_moved(&r, 3, pt(200, 200), 2.01);
    rt_touch_down(&r, 4, center(&r, RT_TOUCH_CROUCH), 2);
    rt_touch_external(&r, RT_TOUCH_FIRE_BLUE, 1);
    rt_touch_set_active(&r, 0);
    assert(!rt_touch_takes_touches(&r) && all_released(&r, &l));
    rt_touch_down(&r, 5, center(&r, RT_TOUCH_JUMP), 3);
    rt_touch_external(&r, RT_TOUCH_FIRE_BLUE, 1);
    assert(l.down[RT_TOUCH_JUMP] == 1 && l.down[RT_TOUCH_FIRE_BLUE] == 1);
    rt_touch_set_active(&r, 1);
    rt_touch_moved(&r, 4, center(&r, RT_TOUCH_CROUCH), 4);
    rt_touch_up(&r, 4); rt_touch_up(&r, 3);
    assert(all_released(&r, &l) && l.down[RT_TOUCH_CROUCH] == 1);
}

// Caméra : stick (une poussée par image, quadratique) ou trackpad (glissement,
// accéléré) ; la bascule oublie le doigt de caméra en cours.
RT_CHECK(touch_router_look_modes) {
    rt_touch_router r; Log l; setup(&r, &l, 0);
    rt_touch_down(&r, 1, pt(600, 250), 0);
    rt_touch_moved(&r, 1, pt(600, 250 - 66), .01);   // stick vers le haut, à fond
    rt_touch_frame(&r);
    assert(l.look_y == -90 && l.look_x == 0);
    rt_touch_moved(&r, 1, pt(600 + 15, 250), .02);   // petite inclinaison : fractions reportées
    for (int i = 0; i < 10; ++i) rt_touch_frame(&r);
    assert(l.look_x > 0 && l.look_x < 30);
    rt_touch_down(&r, 2, center(&r, RT_TOUCH_LOOK_MODE), .1);   // passe en trackpad
    assert(l.modes == 1 && l.trackpad == 1 && r.trackpad && rt_touch_held(&r, RT_TOUCH_LOOK_MODE));
    assert(!rt_touch_role_points(&r, RT_TOUCH_LOOK, NULL, NULL));
    int looks = l.looks;
    rt_touch_moved(&r, 1, pt(700, 250), .2); rt_touch_frame(&r);
    assert(l.looks == looks);   // ancien doigt de caméra oublié
    rt_touch_up(&r, 1); rt_touch_up(&r, 2);
    for (int a = 0; a < RT_TOUCH_ACTION_COUNT; ++a) assert(l.down[a] == 0);   // la bascule n'émet rien au jeu
    l.look_x = l.look_y = 0;
    rt_touch_down(&r, 3, pt(600, 250), 1);
    rt_touch_moved(&r, 3, pt(610, 250), 1.1);   // lent : gain 1
    assert(l.look_x == 35);
    rt_touch_frame(&r);
    assert(l.look_x == 35);   // pas de poussée par image en trackpad
    for (int i = 1; i <= 5; ++i) rt_touch_moved(&r, 3, pt(610 + 40 * (float)i, 250), 1.1 + i * .01);   // 4000 pt/s
    assert(l.look_x > 35 + 5 * 40 * 3.5f * 1.5f);   // accélération
    rt_touch_up(&r, 3);
    assert(rt_touch_trackpad_gain(&r.tuning, 100) == 1);
    assert(fabsf(rt_touch_trackpad_gain(&r.tuning, 3000) - 2.5f) < 1e-5f);
}

// Disposition : boutons visibles sans chevauchement, zones de toucher d'au
// moins 44 pt, tout dans la zone sûre et hors du coin du compteur d'images,
// sur téléphone (petit et grand, encoche de chaque côté) et iPad, avec et
// sans boutons de portail : quatre sur téléphone (deux paires en miroir),
// exactement deux sur iPad.
RT_CHECK(touch_router_layout_fits) {
    static const struct { rt_touch_rect bounds, safe; int pad; } screens[] = {
        {{0, 0, 667, 375}, {0, 0, 667, 375}, 0},           // iPhone SE
        {{0, 0, 852, 393}, {59, 0, 734, 372}, 0},          // iPhone 15, encoche à gauche
        {{0, 0, 852, 393}, {59, 0, 734, 372}, 0},
        {{0, 0, 956, 440}, {62, 0, 832, 419}, 0},          // iPhone 16 Pro Max
        {{0, 0, 812, 375}, {44, 0, 724, 354}, 0},          // iPhone mini
        {{0, 0, 1194, 834}, {0, 24, 1194, 790}, 1},        // iPad Pro 11"
        {{0, 0, 1366, 1024}, {0, 24, 1366, 980}, 1},       // iPad Pro 12,9"
        {{0, 0, 1133, 744}, {0, 24, 1133, 700}, 1},        // iPad mini
        {{0, 0, 568, 320}, {0, 0, 568, 320}, 0},           // plus petit écran paysage
    };
    for (size_t s = 0; s < sizeof(screens) / sizeof(*screens); ++s)
        for (int portals = 0; portals < 2; ++portals) {
            rt_touch_layout l;
            rt_touch_layout_make(&l, screens[s].bounds, screens[s].safe, portals, screens[s].pad);
            rt_touch_rect a = l.safe, c = l.fps_corner;
            int fire = 0, want = portals ? screens[s].pad ? 2 : 4 : 0;
            for (int i = 0; i < l.count; ++i) {
                const rt_touch_button *b = &l.buttons[i];
                fire += b->action == RT_TOUCH_FIRE_BLUE || b->action == RT_TOUCH_FIRE_ORANGE;
                assert(fminf(b->w, b->h) + 2 * hit_slack(b) >= 44);
                assert(b->at.x - b->w / 2 >= a.x && b->at.x + b->w / 2 <= a.x + a.w);
                assert(b->at.y - b->h / 2 >= a.y && b->at.y + b->h / 2 <= a.y + a.h);
                assert(b->at.x - b->w / 2 >= c.x + c.w || b->at.y - b->h / 2 >= c.y + c.h);
                assert(rt_touch_button_at(&l, b->at) == (int)b->action);
                for (int j = i + 1; j < l.count; ++j) assert(apart(b, 2, &l.buttons[j], 2));   // 4 pt d'écart
            }
            assert(fire == want && l.count == want + 5);
            assert(l.stick_radius >= 44 && l.stick_radius <= 66);
        }
    // Hors de tout bouton : rien.
    rt_touch_layout l;
    rt_touch_layout_make(&l, kPhone, kPhoneSafe, 1, 0);
    assert(rt_touch_button_at(&l, pt(400, 200)) == -1);
}

// Téléphone : la disposition d'origine ne bouge pas, au point près, ni avec
// les tapes au dos (pas de boutons de portail) ni avec les boutons de portail
// facultatifs (deux paires de cercles en miroir dans les coins du haut).
RT_CHECK(touch_router_phone_layout_unchanged) {
    const float x = kPhoneSafe.x, y = kPhoneSafe.y, w = kPhoneSafe.w, h = kPhoneSafe.h;
    for (int portals = 0; portals < 2; ++portals) {
        // Paires sous le compteur d'images (50 pt) : centre à 50 + 30 + 8 ;
        // s'accroupir repoussé dessous (88 + 30 + 27 + 8), sinon à 40 % de la hauteur.
        const struct { rt_touch_action action; float x, y, size; } want[] = {
            {RT_TOUCH_FIRE_BLUE, x + w * .06f, 88, 60},
            {RT_TOUCH_FIRE_ORANGE, x + w * .06f + 69, 88, 60},
            {RT_TOUCH_FIRE_BLUE, x + w * .94f, 88, 60},
            {RT_TOUCH_FIRE_ORANGE, x + w * .94f - 69, 88, 60},
            {RT_TOUCH_JUMP, x + w * .94f, y + h * .50f, 54},
            {RT_TOUCH_CROUCH, x + w * .80f, portals ? 153 : y + h * .40f, 54},
            {RT_TOUCH_USE, x + w * .94f, y + h * .80f, 54},
            {RT_TOUCH_PAUSE, x + w - 54 * .45f, y + 54 * .45f, 54 * .75f},
            {RT_TOUCH_LOOK_MODE, x + 54 * .45f, y + h - 54 * .45f, 54 * .75f},
        };
        int skip = portals ? 0 : 4;
        rt_touch_layout l;
        rt_touch_layout_make(&l, kPhone, kPhoneSafe, portals, 0);
        assert(l.count == 9 - skip && !l.pad);
        for (int i = 0; i < l.count; ++i) {
            const rt_touch_button *b = &l.buttons[i];
            assert(b->action == want[i + skip].action && b->w == want[i + skip].size && b->h == want[i + skip].size);
            assert(fabsf(b->at.x - want[i + skip].x) < 1e-3f && fabsf(b->at.y - want[i + skip].y) < 1e-3f);
            // Zone de toucher d'origine : un cercle de 62 % du diamètre.
            assert(rt_touch_button_at(&l, pt(b->at.x, b->at.y + b->w * .61f)) == (int)b->action);
            assert(rt_touch_button_at(&l, pt(b->at.x, b->at.y + b->w * .63f)) != (int)b->action);
        }
        assert(fabsf(l.rest[0].x - (x + w * .16f)) < 1e-3f && fabsf(l.rest[0].y - (y + h * .72f)) < 1e-3f);
        assert(fabsf(l.rest[1].x - (x + w * .80f)) < 1e-3f && fabsf(l.rest[1].y - (y + h * .72f)) < 1e-3f);
    }
}

// iPad plein écran et fenêtres étroites : actions en bas contre les coins ;
// exactement un ovale bleu et un ovale orange, en quinconce sous le pouce
// droit ; sauter et utiliser de part et d'autre ; Pause isolée ; zones de
// toucher disjointes ; moitié droite libre pour la caméra ; à gauche, rien que
// le mode de caméra dans le coin et le stick juste au-dessus.
RT_CHECK(touch_router_pad_corner_layout) {
    static const struct { rt_touch_rect bounds, safe; int full; } screens[] = {
        {{0, 0, 1194, 834}, {0, 24, 1194, 790}, 1},     // iPad Pro 11"
        {{0, 0, 1366, 1024}, {0, 24, 1366, 980}, 1},    // iPad Pro 12,9"
        {{0, 0, 1133, 744}, {0, 24, 1133, 700}, 1},     // iPad mini
        {{0, 0, 1080, 810}, {0, 24, 1080, 766}, 1},     // iPad 10,2"
        {{0, 0, 1024, 768}, {0, 0, 1024, 768}, 1},      // iPad 9,7", barre d'état masquée
        {{0, 0, 1194, 834}, {44, 24, 1106, 778}, 1},    // zone sûre dissymétrique
        {{0, 0, 981, 1024}, {0, 24, 981, 980}, 0},      // Split View 2/3 (12,9")
        {{0, 0, 809, 834}, {0, 24, 809, 790}, 0},       // Split View 2/3 (11")
        {{0, 0, 678, 1024}, {0, 24, 678, 980}, 0},      // Split View 1/2 (12,9")
        {{0, 0, 590, 834}, {0, 24, 590, 790}, 0},       // Split View 1/2 (11")
        {{0, 0, 507, 834}, {0, 24, 507, 790}, 0},       // fenêtre étroite
        {{0, 0, 375, 834}, {0, 24, 375, 790}, 0},       // Split View 1/3, Slide Over
        {{0, 0, 320, 768}, {0, 20, 320, 748}, 0},       // Slide Over, petit iPad
    };
    for (size_t s = 0; s < sizeof(screens) / sizeof(*screens); ++s)
        for (int portals = 0; portals < 2; ++portals) {
            rt_touch_layout l;
            rt_touch_layout_make(&l, screens[s].bounds, screens[s].safe, portals, 1);
            rt_touch_rect a = l.safe;
            float right = a.x + a.w, bottom = a.y + a.h, mid = l.bounds.x + l.bounds.w / 2;
            const rt_touch_button *jump = side_button(&l, RT_TOUCH_JUMP, 1), *use = side_button(&l, RT_TOUCH_USE, 1);
            const rt_touch_button *crouch = side_button(&l, RT_TOUCH_CROUCH, 1), *pause = side_button(&l, RT_TOUCH_PAUSE, 1);
            const rt_touch_button *mode = side_button(&l, RT_TOUCH_LOOK_MODE, -1);
            assert(l.pad && jump && use && crouch && pause && mode);
            assert(jump->w == jump->h && use->w == use->h && crouch->w == crouch->h);

            // Exactement un bleu et un orange, tous deux à droite ; aucun à gauche.
            int blues = 0, oranges = 0;
            for (int i = 0; i < l.count; ++i) {
                blues += l.buttons[i].action == RT_TOUCH_FIRE_BLUE;
                oranges += l.buttons[i].action == RT_TOUCH_FIRE_ORANGE;
            }
            assert(blues == portals && oranges == portals && l.count == 5 + 2 * portals);
            assert(!side_button(&l, RT_TOUCH_FIRE_BLUE, -1) && !side_button(&l, RT_TOUCH_FIRE_ORANGE, -1));
            const rt_touch_button *blue = side_button(&l, RT_TOUCH_FIRE_BLUE, 1), *orange = side_button(&l, RT_TOUCH_FIRE_ORANGE, 1);
            assert(!blue == !portals && !orange == !portals);

            // Sauter dans le coin bas droit, avec ou sans ovales.
            assert(right - (jump->at.x + jump->w / 2) < jump->w && bottom - (jump->at.y + jump->h / 2) < jump->h);
            if (portals) {
                // Deux ovales horizontaux identiques, en quinconce : orange une
                // rangée au-dessus du bleu, décalé d'au moins une demi-largeur
                // vers le bord, sans être simplement posé à côté.
                assert(blue->w == orange->w && blue->h == orange->h && blue->w >= 1.5f * blue->h);
                assert(orange->at.y + orange->h / 2 < blue->at.y - blue->h / 2);
                assert(orange->at.x - blue->at.x >= blue->w / 2 && orange->at.x - blue->at.x < blue->w);
                assert(blue->w >= 1.5f * jump->w);   // nettement plus larges que les boutons ronds
                // Sauter à droite du bleu, sous l'orange ; utiliser dans l'autre
                // creux (à gauche de l'orange, au-dessus du bleu) ; s'accroupir
                // au-dessus de l'orange, contre le bord.
                assert(jump->at.x - jump->w / 2 > blue->at.x + blue->w / 2 && jump->at.y - jump->h / 2 > orange->at.y + orange->h / 2);
                assert(use->at.x + use->w / 2 < orange->at.x - orange->w / 2 && use->at.y + use->h / 2 < blue->at.y - blue->h / 2);
                assert(crouch->at.y + crouch->h / 2 < orange->at.y - orange->h / 2 && crouch->at.x > orange->at.x - orange->w / 2);
            } else {
                // Sans boutons de portail, le groupe reste dans le coin : utiliser
                // à côté de sauter, s'accroupir juste au-dessus.
                assert(use->at.y == jump->at.y && use->at.x + use->w / 2 < jump->at.x - jump->w / 2);
                assert(crouch->at.x == jump->at.x && crouch->at.y + crouch->h / 2 < jump->at.y - jump->h / 2);
                assert(jump->at.x - use->at.x < 2 * jump->w && jump->at.y - crouch->at.y < 2 * jump->h);
            }

            for (int i = 0; i < l.count; ++i) {
                const rt_touch_button *b = &l.buttons[i];
                assert(b->at.x - b->w / 2 >= a.x && b->at.x + b->w / 2 <= right);
                assert(b->at.y - b->h / 2 >= a.y && b->at.y + b->h / 2 <= bottom);
                // Zones de toucher disjointes : chaque point d'un bouton dessiné est à lui.
                for (int j = i + 1; j < l.count; ++j) assert(apart(b, hit_slack(b), &l.buttons[j], hit_slack(&l.buttons[j])));
                for (int t = 0; t < 72; ++t) assert(rt_touch_button_at(&l, on_outline(b, -.5f, t, 72)) == (int)b->action);
                if (b == pause) continue;
                assert(apart(pause, 60, b, 0));   // Pause isolée : rien à moins de 60 pt
                // Les actions sont basses et, en plein écran, serrées contre un bord latéral.
                assert(b->at.y > a.y + a.h * .45f);
                if (!screens[s].full) continue;
                assert(b->at.y > a.y + a.h * .62f);
                assert(b->at.x + b->w / 2 < a.x + a.w * .24f || b->at.x - b->w / 2 > a.x + a.w * .76f);
            }
            assert(pause->at.x + pause->w > right && pause->at.y - pause->h < a.y);   // coin haut droit
            assert(mode->at.x - a.x < 2 * mode->w && bottom - mode->at.y < 2 * mode->h);   // coin bas gauche

            // Caméra : au moins 70 % de la moitié droite sans bouton (85 % en plein
            // écran), et rien entre le milieu de l'écran et le groupe du coin.
            long total = 0, clear = 0;
            for (float py = a.y + 2; py < bottom; py += 4)
                for (float px = mid + 2; px < right; px += 4) { ++total; clear += rt_touch_button_at(&l, pt(px, py)) == -1; }
            assert(total > 0 && clear * 100 >= total * (screens[s].full ? 85 : 70));
            if (screens[s].full)
                for (float py = a.y + 2; py < bottom; py += 4)
                    for (float px = mid; px < a.x + a.w * .74f; px += 4) assert(rt_touch_button_at(&l, pt(px, py)) == -1);

            // Sticks au repos : anneau entier dans sa moitié et dans la zone sûre,
            // dégagé des boutons (un pouce posé là déplace ou vise, il ne tire pas).
            assert(l.rest[0].x + l.stick_radius <= mid && l.rest[1].x - l.stick_radius >= mid);
            for (int k = 0; k < 2; ++k) {
                rt_touch_button ring = {RT_TOUCH_ACTION_COUNT, l.rest[k], 2 * l.stick_radius, 2 * l.stick_radius};
                assert(ring.at.x - ring.w / 2 >= a.x && ring.at.x + ring.w / 2 <= right);
                assert(ring.at.y - ring.h / 2 >= a.y && ring.at.y + ring.h / 2 <= bottom);
                assert(rt_touch_button_at(&l, ring.at) == -1);
                for (int i = 0; i < l.count; ++i) assert(apart(&ring, 2, &l.buttons[i], 2));
            }
            // Stick gauche bas, dans le coin libéré, juste au-dessus du mode de caméra.
            assert(l.rest[0].y > a.y + a.h * .62f && l.rest[0].x - a.x < 2.2f * l.stick_radius);
            assert(hypotf(l.rest[0].x - mode->at.x, l.rest[0].y - mode->at.y) < 2 * l.stick_radius);
            if (screens[s].full) assert(l.rest[0].x - a.x < a.w * .16f && l.rest[0].y == l.rest[1].y);

            // Zone sûre déplacée (barre d'état, indicateur, fenêtre) : toute la
            // disposition suit, à l'identique.
            rt_touch_rect moved = {a.x + 31, a.y + 7, a.w, a.h};
            rt_touch_layout m;
            rt_touch_layout_make(&m, screens[s].bounds, moved, portals, 1);
            assert(m.count == l.count && m.stick_radius == l.stick_radius);
            for (int i = 0; i < l.count; ++i) {
                assert(m.buttons[i].action == l.buttons[i].action && m.buttons[i].w == l.buttons[i].w);
                assert(fabsf(m.buttons[i].at.x - l.buttons[i].at.x - 31) < 1e-2f && fabsf(m.buttons[i].at.y - l.buttons[i].at.y - 7) < 1e-2f);
            }
            for (int k = 0; k < 2; ++k)
                assert(fabsf(m.rest[k].x - l.rest[k].x - 31) < 1e-2f && fabsf(m.rest[k].y - l.rest[k].y - 7) < 1e-2f);
        }
}

// iPad : l'ovale se touche sur toute sa largeur (pas seulement un cercle au
// centre), chaque ovale tient son clic, le coin gauche libéré déplace au lieu
// de tirer, et passer de téléphone à iPad relâche tout.
RT_CHECK(touch_router_pad_ovals_route) {
    rt_touch_router r; Log l; setup(&r, &l, 1);
    rt_touch_down(&r, 9, center(&r, RT_TOUCH_FIRE_BLUE), 0);
    rt_touch_layout pad;
    rt_touch_layout_make(&pad, (rt_touch_rect){0, 0, 1194, 834}, (rt_touch_rect){0, 24, 1194, 790}, 1, 1);
    assert(rt_touch_set_layout(&r, &pad) == 1 && all_released(&r, &l) && l.down[RT_TOUCH_FIRE_BLUE] == 1);
    rt_touch_up(&r, 9);
    const rt_touch_button *blue = side_button(&r.layout, RT_TOUCH_FIRE_BLUE, 1), *orange = side_button(&r.layout, RT_TOUCH_FIRE_ORANGE, 1);
    assert(blue && orange);
    assert(rt_touch_button_at(&r.layout, pt(blue->at.x - blue->w * .45f, blue->at.y)) == RT_TOUCH_FIRE_BLUE);
    assert(rt_touch_button_at(&r.layout, pt(blue->at.x, blue->at.y - blue->w * .45f)) != RT_TOUCH_FIRE_BLUE);
    // Bouts des deux ovales les plus proches l'un de l'autre : chacun son clic.
    rt_touch_down(&r, 1, pt(blue->at.x + blue->w * .45f, blue->at.y), 0);
    rt_touch_down(&r, 2, pt(orange->at.x - orange->w * .45f, orange->at.y), 0);
    assert(l.down[RT_TOUCH_FIRE_BLUE] == 2 && l.down[RT_TOUCH_FIRE_ORANGE] == 1);
    rt_touch_up(&r, 1);
    assert(l.up[RT_TOUCH_FIRE_BLUE] == 2 && rt_touch_held(&r, RT_TOUCH_FIRE_ORANGE));
    rt_touch_up(&r, 2);
    assert(l.up[RT_TOUCH_FIRE_ORANGE] == 1);
    // Coin gauche, là où serait une paire en miroir : le stick, aucun tir.
    rt_touch_point twin = pt(r.layout.safe.x + (r.layout.safe.x + r.layout.safe.w - blue->at.x), blue->at.y);
    rt_touch_down(&r, 3, twin, 1);
    rt_touch_moved(&r, 3, pt(twin.x, twin.y - 60), 1.01);
    assert(l.my > .5f && l.down[RT_TOUCH_FIRE_BLUE] == 2 && l.down[RT_TOUCH_FIRE_ORANGE] == 1);
    rt_touch_up(&r, 3);
    // Sticks au repos : déplacement et caméra.
    rt_touch_down(&r, 4, r.layout.rest[0], 2);
    rt_touch_down(&r, 5, r.layout.rest[1], 2);
    assert(rt_touch_role_points(&r, RT_TOUCH_MOVE, NULL, NULL) && rt_touch_role_points(&r, RT_TOUCH_LOOK, NULL, NULL));
    rt_touch_up(&r, 4); rt_touch_up(&r, 5);
    assert(all_released(&r, &l) && l.down[RT_TOUCH_USE] == 0 && l.modes == 0);
}

RT_CHECK(touch_router_policy_and_sticks) {
    assert(rt_touch_portal_buttons("1", 0, 1) == 1);
    assert(rt_touch_portal_buttons("0", 1, 0) == 0);
    assert(rt_touch_portal_buttons(NULL, 1, 1) == 1);     // iPad : boutons
    assert(rt_touch_portal_buttons("auto", 0, 1) == 0);   // téléphone avec tapes au dos
    assert(rt_touch_portal_buttons(NULL, 0, 0) == 1);     // téléphone sans capteur (simulateur)
    float x, y;
    rt_touch_deflection(60, pt(0, 0), pt(5, 0), &x, &y);   // zone morte
    assert(x == 0 && y == 0);
    rt_touch_deflection(60, pt(0, 0), pt(0, -200), &x, &y);   // au-delà du rayon : 1
    assert(fabsf(y - 1) < 1e-5f && x == 0);
    rt_touch_deflection(0, pt(0, 0), pt(10, 10), &x, &y);
    assert(x == 0 && y == 0);
    int k[4];
    rt_touch_move_keys(0, 1, k); assert(k[0] && !k[1] && !k[2] && !k[3]);
    rt_touch_move_keys(.7f, .7f, k); assert(k[0] && k[3] && !k[1] && !k[2]);
    rt_touch_move_keys(-1, 0, k); assert(k[1] && !k[0] && !k[2] && !k[3]);
    rt_touch_move_keys(0, -1, k); assert(k[2] && !k[0]);
    rt_touch_move_keys(.1f, .1f, k); assert(!k[0] && !k[1] && !k[2] && !k[3]);
}
