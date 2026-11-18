// Commandes tactiles de Portal 2 : logique sans UIKit, en C portable
// (runtime/ios/touch_router.c), testée sur l'hôte par tests/checks_touch_router.c
// et utilisée par la surcouche UIKit (touch_controls.m).
//
// Le routeur possède les doigts : chacun garde son rôle (déplacement, caméra,
// bouton) de l'appui au relâchement. L'état émis vers le jeu (touches et clics
// tenus, inclinaison du stick) est recalculé à partir des doigts encore
// suivis, puis comparé à ce qui a déjà été envoyé : seules les transitions
// sont émises, et tout retour au repos (annulation, menu, manette, arrière-plan,
// nouvelle disposition) relâche exactement ce qui était tenu. Un doigt oublié
// par une annulation reste ignoré jusqu'à ce qu'il se lève : aucun tir ne
// reprend tout seul après un menu ou une reconnexion.
//
// Coordonnées en points de la vue, y vers le bas. Un seul thread (le principal).
#pragma once
#include <stdint.h>

typedef enum {
    RT_TOUCH_JUMP,          // espace
    RT_TOUCH_CROUCH,        // Ctrl gauche (tenu)
    RT_TOUCH_USE,           // E
    RT_TOUCH_PAUSE,         // Échap
    RT_TOUCH_FIRE_BLUE,     // clic gauche : portail bleu
    RT_TOUCH_FIRE_ORANGE,   // clic droit : portail orange
    RT_TOUCH_LOOK_MODE,     // bascule stick / trackpad de la caméra (rien n'est émis au jeu)
    RT_TOUCH_ACTION_COUNT
} rt_touch_action;

typedef enum { RT_TOUCH_NONE, RT_TOUCH_MOVE, RT_TOUCH_LOOK, RT_TOUCH_BUTTON } rt_touch_role;

enum { RT_TOUCH_MAX_FINGERS = 16, RT_TOUCH_MAX_BUTTONS = 10 };

typedef struct { float x, y; } rt_touch_point;
typedef struct { float x, y, w, h; } rt_touch_rect;
// Bouton : ellipse dessinée de w × h pt autour de `at` (cercle si w == h ; les
// portails de l'iPad sont des ovales horizontaux, w > h).
typedef struct { rt_touch_action action; rt_touch_point at; float w, h; } rt_touch_button;

typedef struct {
    rt_touch_rect bounds, safe;
    rt_touch_rect fps_corner;     // bascule du compteur d'images (coin haut gauche)
    int portal_buttons;
    int pad;                      // disposition de l'iPad (actions en bas, contre les coins)
    int count;
    rt_touch_button buttons[RT_TOUCH_MAX_BUTTONS];
    float stick_radius;
    rt_touch_point rest[2];       // sticks au repos : 0 déplacement, 1 caméra
} rt_touch_layout;

typedef struct {
    uintptr_t id;                 // 0 : libre
    rt_touch_role role;
    rt_touch_action action;
    rt_touch_point start, at;
    double stamp, speed;          // trackpad : horodatage, vitesse lissée (pt/s)
} rt_touch_finger;

typedef struct {
    float look_speed;             // P2_TOUCH_LOOK
    float accel_max, accel_low, accel_high, accel_smooth;   // P2_TOUCH_ACCEL*
    int log;                      // P2_TOUCH_ACCEL_LOG : vitesse et gain de chaque glissement
} rt_touch_tuning;

// Sorties, appelées seulement aux transitions.
typedef struct {
    void *ctx;
    void (*action)(void *ctx, rt_touch_action action, int down);
    void (*look)(void *ctx, int dx, int dy);          // comptes de souris relatifs
    void (*move)(void *ctx, float x, float y);        // -1..1, y vers l'avant
    void (*look_mode)(void *ctx, int trackpad);       // choix à mémoriser
} rt_touch_sink;

typedef struct {
    rt_touch_layout layout;
    rt_touch_tuning tuning;
    rt_touch_sink sink;
    rt_touch_finger fingers[RT_TOUCH_MAX_FINGERS];
    int external[RT_TOUCH_ACTION_COUNT];   // appuis hors doigts (tapes au dos)
    int emitted[RT_TOUCH_ACTION_COUNT];    // état tenu déjà envoyé au jeu
    float move[2], carry[2];
    int trackpad;
    int menu;      // interface du jeu affichée : les doigts vont à SDL (clics)
    int hidden;    // cachée pour une manette ou un clavier : un toucher la rappelle
    int active;    // application au premier plan
} rt_touch_router;

void rt_touch_tuning_defaults(rt_touch_tuning *tuning);
float rt_touch_trackpad_gain(const rt_touch_tuning *tuning, double speed);

// Boutons de portail : P2_PORTAL_BUTTONS (« 1 », « 0 », sinon automatique).
// Automatique : toujours sur iPad (on ne tape pas au dos d'une tablette), et
// sur téléphone seulement sans tapes au dos.
int rt_touch_portal_buttons(const char *setting, int is_pad, int back_taps);

// Deux dispositions, toutes deux relatives à la zone sûre :
// - téléphone (pad = 0) : sauter, s'accroupir et utiliser le long du bord
//   droit ; les boutons de portail facultatifs sont deux paires de cercles en
//   miroir dans les coins du haut ;
// - iPad (pad = 1) : tout sauf Pause en bas, contre les coins, sous les pouces.
//   À droite, exactement deux boutons de portail, des ovales horizontaux en
//   quinconce (bleu en bas vers l'intérieur, orange plus haut contre le bord),
//   sauter dans le coin, utiliser côté caméra, s'accroupir au-dessus ; sans
//   boutons de portail, ces trois-là restent groupés dans le coin. À gauche,
//   le stick déplace ; à droite, le glissement vise. Tailles et marges vont
//   de « compact » (fenêtre étroite) à « large » (plein écran).
// Pause reste seule dans le coin haut droit.
void rt_touch_layout_make(rt_touch_layout *layout, rt_touch_rect bounds, rt_touch_rect safe, int portal_buttons, int pad);
// Bouton sous le point (le plus proche dont la zone le contient), sinon -1.
// La zone de toucher est la forme dessinée, élargie de la même marge partout.
int rt_touch_button_at(const rt_touch_layout *layout, rt_touch_point p);

void rt_touch_init(rt_touch_router *r, const rt_touch_tuning *tuning, const rt_touch_sink *sink, int trackpad);
// Nouvelle disposition (taille, zone sûre, rotation, boutons de portail, iPad) :
// tout est relâché si elle diffère. Rend 1 dans ce cas.
int rt_touch_set_layout(rt_touch_router *r, const rt_touch_layout *layout);
void rt_touch_set_menu(rt_touch_router *r, int menu);
void rt_touch_set_hidden(rt_touch_router *r, int hidden);
void rt_touch_set_active(rt_touch_router *r, int active);
// La surcouche prend les doigts (sinon : vue de SDL, clics de menu).
int rt_touch_takes_touches(const rt_touch_router *r);

void rt_touch_down(rt_touch_router *r, uintptr_t id, rt_touch_point p, double t);
void rt_touch_moved(rt_touch_router *r, uintptr_t id, rt_touch_point p, double t);
void rt_touch_up(rt_touch_router *r, uintptr_t id);   // fin ou annulation de ce doigt
void rt_touch_cancel_all(rt_touch_router *r);
// Appui tenu par une autre source que les doigts (tape au dos), relâché aussi par cancel_all.
void rt_touch_external(rt_touch_router *r, rt_touch_action action, int down);
// Une fois par image : caméra au stick.
void rt_touch_frame(rt_touch_router *r);
void rt_touch_set_trackpad(rt_touch_router *r, int trackpad);

int rt_touch_held(const rt_touch_router *r, rt_touch_action action);
// Doigt tenant ce rôle (dessin des sticks) : 1 et ses points, sinon 0.
int rt_touch_role_points(const rt_touch_router *r, rt_touch_role role, rt_touch_point *start, rt_touch_point *at);
int rt_touch_finger_count(const rt_touch_router *r);
// Inclinaison d'un stick, -1..1 par axe (y vers le haut), zone morte retranchée.
void rt_touch_deflection(float radius, rt_touch_point start, rt_touch_point at, float *x, float *y);
// Repli sans manette virtuelle : W, A, S, D voulues pour cette inclinaison (secteurs de 45°).
void rt_touch_move_keys(float x, float y, int wanted[4]);
