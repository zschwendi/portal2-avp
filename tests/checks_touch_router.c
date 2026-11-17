// Commandes tactiles iOS (runtime/ios/touch_router.c, C portable, testé ici
// sur l'hôte) : propriété des doigts, relâchements (annulation, menu, manette,
// arrière-plan, rotation) et disposition sur des écrans de téléphone et d'iPad.
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
    rt_touch_layout_make(&l, kPhone, kPhoneSafe, portals);
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
    rt_touch_layout_make(&same, kPhone, kPhoneSafe, 1);
    assert(rt_touch_set_layout(&r, &same) == 0 && rt_touch_held(&r, RT_TOUCH_CROUCH) && l.mx > 0);
    rt_touch_layout flipped;
    rt_touch_layout_make(&flipped, kPhone, kPhoneFlippedSafe, 1);
    assert(rt_touch_set_layout(&r, &flipped) == 1 && all_released(&r, &l));
    rt_touch_moved(&r, 2, pt(300, 250), .02);
    assert(l.mx == 0);
    // Changer l'affichage des boutons de portail aussi.
    rt_touch_down(&r, 3, center(&r, RT_TOUCH_JUMP), .1);
    rt_touch_layout without;
    rt_touch_layout_make(&without, kPhone, kPhoneFlippedSafe, 0);
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
// sur téléphone (petit et grand, encoche de chaque côté) et iPad.
RT_CHECK(touch_router_layout_fits) {
    static const struct { rt_touch_rect bounds, safe; } screens[] = {
        {{0, 0, 667, 375}, {0, 0, 667, 375}},              // iPhone SE
        {{0, 0, 852, 393}, {59, 0, 734, 372}},             // iPhone 15, encoche à gauche
        {{0, 0, 852, 393}, {59, 0, 734, 372}},
        {{0, 0, 956, 440}, {62, 0, 832, 419}},             // iPhone 16 Pro Max
        {{0, 0, 812, 375}, {44, 0, 724, 354}},             // iPhone mini
        {{0, 0, 1194, 834}, {0, 24, 1194, 790}},           // iPad Pro 11"
        {{0, 0, 1366, 1024}, {0, 24, 1366, 980}},          // iPad Pro 12,9"
        {{0, 0, 1133, 744}, {0, 24, 1133, 700}},           // iPad mini
        {{0, 0, 568, 320}, {0, 0, 568, 320}},              // plus petit écran paysage
    };
    for (size_t s = 0; s < sizeof(screens) / sizeof(*screens); ++s)
        for (int portals = 0; portals < 2; ++portals) {
            rt_touch_layout l;
            rt_touch_layout_make(&l, screens[s].bounds, screens[s].safe, portals);
            rt_touch_rect a = l.safe, c = l.fps_corner;
            int fire = 0;
            for (int i = 0; i < l.count; ++i) {
                const rt_touch_button *b = &l.buttons[i];
                float rad = b->size / 2;
                fire += b->action == RT_TOUCH_FIRE_BLUE || b->action == RT_TOUCH_FIRE_ORANGE;
                assert(b->size * kHitScale * 2 >= 44);
                assert(b->at.x - rad >= a.x && b->at.x + rad <= a.x + a.w);
                assert(b->at.y - rad >= a.y && b->at.y + rad <= a.y + a.h);
                assert(b->at.x - rad >= c.x + c.w || b->at.y - rad >= c.y + c.h);
                assert(rt_touch_button_at(&l, b->at) == (int)b->action);
                for (int j = i + 1; j < l.count; ++j) {
                    const rt_touch_button *o = &l.buttons[j];
                    assert(hypotf(b->at.x - o->at.x, b->at.y - o->at.y) >= rad + o->size / 2 + 4);
                }
            }
            assert(fire == (portals ? 4 : 0) && l.count == (portals ? 9 : 5));
            assert(l.stick_radius >= 44 && l.stick_radius <= 66);
        }
    // Hors de tout bouton : rien.
    rt_touch_layout l;
    rt_touch_layout_make(&l, kPhone, kPhoneSafe, 1);
    assert(rt_touch_button_at(&l, pt(400, 200)) == -1);
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
