// Commandes tactiles : rôles des doigts, disposition et état émis (voir
// touch_router.h). C portable, sans UIKit ni SDL.
#include "touch_router.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static const float kButtonSize = 54, kPortalSize = 60, kSmallSize = 54 * .75f;
static const float kHitScale = .62f;     // zone de toucher : un peu plus large que le cercle dessiné
static const float kPortalGap = 60 * 1.15f;
static const float kStickLook = 90;      // comptes de souris par image, stick à fond (≈ 360°/s à la sensibilité 3 du jeu)
static const float kTrackpadLook = 3.5f; // comptes de souris par point de glissement

void rt_touch_tuning_defaults(rt_touch_tuning *t) {
    t->look_speed = 1;
    t->accel_max = 2.5f; t->accel_low = 300; t->accel_high = 1500; t->accel_smooth = .5f;
    t->log = 0;
}

// Gain 1 sous accel_low pt/s (visée fine inchangée), puis montée en douceur
// (smoothstep) jusqu'à accel_max à accel_high pt/s.
float rt_touch_trackpad_gain(const rt_touch_tuning *t, double speed) {
    double span = t->accel_high > t->accel_low ? t->accel_high - t->accel_low : 1;
    double k = fmin(1, fmax(0, (speed - t->accel_low) / span));
    return 1 + (t->accel_max - 1) * (float)(k * k * (3 - 2 * k));
}

int rt_touch_portal_buttons(const char *setting, int is_pad, int back_taps) {
    if (setting && *setting == '1') return 1;
    if (setting && *setting == '0') return 0;
    return is_pad || !back_taps;
}

// ---- disposition ----
static void add_button(rt_touch_layout *l, rt_touch_action action, float x, float y, float size) {
    if (l->count < RT_TOUCH_MAX_BUTTONS) l->buttons[l->count++] = (rt_touch_button){action, {x, y}, size};
}

void rt_touch_layout_make(rt_touch_layout *l, rt_touch_rect bounds, rt_touch_rect safe, int portal_buttons) {
    memset(l, 0, sizeof(*l));
    l->bounds = bounds; l->safe = safe; l->portal_buttons = !!portal_buttons;
    float x = safe.x, y = safe.y, w = safe.w, h = safe.h;
    // Compteur d'images « 000 FPS » (police 5×7 de 2 pt, marge 4) à 8 pt du coin
    // de la zone sûre ; zone de bascule un peu plus grande (doigt imprécis).
    l->fps_corner = (rt_touch_rect){0, 0, roundf(x + 8) + 90 + 20, roundf(y + 8) + 22 + 20};
    l->stick_radius = fminf(66, h * .15f);
    l->rest[0] = (rt_touch_point){x + w * .16f, y + h * .72f};
    l->rest[1] = (rt_touch_point){x + w * .80f, y + h * .72f};
    // Pause dans le coin haut droit, mode de la caméra dans le coin bas gauche.
    rt_touch_point pause = {x + w - kButtonSize * .45f, y + kButtonSize * .45f};
    // Portails en miroir (bleu à l'extérieur, orange à l'intérieur, des deux
    // côtés), sous le compteur d'images et sous Pause, même sur un écran bas.
    float top = fmaxf(y + h * .19f, fmaxf(pause.y + kSmallSize / 2 + kPortalSize / 2 + 8,
                                           l->fps_corner.h + kPortalSize / 2 + 8));
    float crouch = y + h * .40f;
    if (portal_buttons) {
        add_button(l, RT_TOUCH_FIRE_BLUE, x + w * .06f, top, kPortalSize);
        add_button(l, RT_TOUCH_FIRE_ORANGE, x + w * .06f + kPortalGap, top, kPortalSize);
        add_button(l, RT_TOUCH_FIRE_BLUE, x + w * .94f, top, kPortalSize);
        add_button(l, RT_TOUCH_FIRE_ORANGE, x + w * .94f - kPortalGap, top, kPortalSize);
        crouch = fmaxf(crouch, top + kPortalSize / 2 + kButtonSize / 2 + 8);
    }
    add_button(l, RT_TOUCH_JUMP, x + w * .94f, y + h * .50f, kButtonSize);
    add_button(l, RT_TOUCH_CROUCH, x + w * .80f, crouch, kButtonSize);
    add_button(l, RT_TOUCH_USE, x + w * .94f, y + h * .80f, kButtonSize);
    add_button(l, RT_TOUCH_PAUSE, pause.x, pause.y, kSmallSize);
    add_button(l, RT_TOUCH_LOOK_MODE, x + kButtonSize * .45f, y + h - kButtonSize * .45f, kSmallSize);
}

int rt_touch_button_at(const rt_touch_layout *l, rt_touch_point p) {
    int best = -1; float best_d = 0;
    for (int i = 0; i < l->count; ++i) {
        const rt_touch_button *b = &l->buttons[i];
        float d = hypotf(p.x - b->at.x, p.y - b->at.y);
        if (d < b->size * kHitScale && (best < 0 || d < best_d)) { best = (int)b->action; best_d = d; }
    }
    return best;
}

// ---- état émis ----
static void publish(rt_touch_router *r) {
    int want[RT_TOUCH_ACTION_COUNT] = {0};
    const rt_touch_finger *move = NULL;
    for (int i = 0; i < RT_TOUCH_MAX_FINGERS; ++i) {
        const rt_touch_finger *f = &r->fingers[i];
        if (!f->id) continue;
        if (f->role == RT_TOUCH_BUTTON) want[f->action] = 1;
        else if (f->role == RT_TOUCH_MOVE) move = f;
    }
    // Relâchements d'abord : un doigt qui passe d'un bouton à l'autre ne tient jamais deux actions.
    for (int pass = 0; pass < 2; ++pass)
        for (int a = 0; a < RT_TOUCH_ACTION_COUNT; ++a) {
            if (a == RT_TOUCH_LOOK_MODE) continue;
            int down = want[a] || r->external[a] > 0;
            if (down == r->emitted[a] || down != pass) continue;
            r->emitted[a] = down;
            if (r->sink.action) r->sink.action(r->sink.ctx, (rt_touch_action)a, down);
        }
    float x = 0, y = 0;
    if (move) rt_touch_deflection(r->layout.stick_radius, move->start, move->at, &x, &y);
    if (x != r->move[0] || y != r->move[1]) {
        r->move[0] = x; r->move[1] = y;
        if (r->sink.move) r->sink.move(r->sink.ctx, x, y);
    }
}

static void look_by(rt_touch_router *r, float x, float y) {
    if (!isfinite(x) || !isfinite(y)) return;
    r->carry[0] += x; r->carry[1] += y;
    int dx = (int)r->carry[0], dy = (int)r->carry[1];
    r->carry[0] -= (float)dx; r->carry[1] -= (float)dy;
    if ((dx || dy) && r->sink.look) r->sink.look(r->sink.ctx, dx, dy);
}

void rt_touch_init(rt_touch_router *r, const rt_touch_tuning *tuning, const rt_touch_sink *sink, int trackpad) {
    memset(r, 0, sizeof(*r));
    if (tuning) r->tuning = *tuning; else rt_touch_tuning_defaults(&r->tuning);
    if (sink) r->sink = *sink;
    r->trackpad = !!trackpad; r->active = 1;
}

void rt_touch_cancel_all(rt_touch_router *r) {
    memset(r->fingers, 0, sizeof(r->fingers));
    memset(r->external, 0, sizeof(r->external));
    r->carry[0] = r->carry[1] = 0;
    publish(r);
}

int rt_touch_set_layout(rt_touch_router *r, const rt_touch_layout *l) {
    const rt_touch_layout *o = &r->layout;
    if (!memcmp(&o->bounds, &l->bounds, sizeof(l->bounds)) && !memcmp(&o->safe, &l->safe, sizeof(l->safe)) &&
        o->portal_buttons == l->portal_buttons && o->count == l->count)
        return 0;
    // Rotation ou nouvelle zone sûre : les boutons ont bougé sous les doigts.
    rt_touch_cancel_all(r);
    r->layout = *l;
    return 1;
}

void rt_touch_set_menu(rt_touch_router *r, int menu) {
    if (!!menu == r->menu) return;
    r->menu = !!menu;
    if (r->menu) rt_touch_cancel_all(r);
}
void rt_touch_set_hidden(rt_touch_router *r, int hidden) {
    if (!!hidden == r->hidden) return;
    r->hidden = !!hidden;
    if (r->hidden) rt_touch_cancel_all(r);
}
void rt_touch_set_active(rt_touch_router *r, int active) {
    if (!!active == r->active) return;
    r->active = !!active;
    if (!r->active) rt_touch_cancel_all(r);
}
int rt_touch_takes_touches(const rt_touch_router *r) { return r->active && !r->menu; }

static rt_touch_finger *finger_of(rt_touch_router *r, uintptr_t id) {
    if (!id) return NULL;
    for (int i = 0; i < RT_TOUCH_MAX_FINGERS; ++i) if (r->fingers[i].id == id) return &r->fingers[i];
    return NULL;
}
static int role_taken(const rt_touch_router *r, rt_touch_role role) {
    for (int i = 0; i < RT_TOUCH_MAX_FINGERS; ++i) if (r->fingers[i].id && r->fingers[i].role == role) return 1;
    return 0;
}

void rt_touch_set_trackpad(rt_touch_router *r, int trackpad) {
    if (!!trackpad == r->trackpad) return;
    r->trackpad = !!trackpad;
    // Le doigt de la caméra change de sens : il est oublié jusqu'à son relâchement.
    for (int i = 0; i < RT_TOUCH_MAX_FINGERS; ++i)
        if (r->fingers[i].role == RT_TOUCH_LOOK) memset(&r->fingers[i], 0, sizeof(r->fingers[i]));
    r->carry[0] = r->carry[1] = 0;
    if (r->sink.look_mode) r->sink.look_mode(r->sink.ctx, r->trackpad);
}

void rt_touch_down(rt_touch_router *r, uintptr_t id, rt_touch_point p, double t) {
    if (!id || !rt_touch_takes_touches(r)) return;
    rt_touch_rect b = r->layout.bounds;
    if (p.x < b.x || p.y < b.y || p.x >= b.x + b.w || p.y >= b.y + b.h) return;
    r->hidden = 0;   // un toucher ramène la surcouche cachée pour une manette
    rt_touch_finger *f = finger_of(r, id);
    if (f) memset(f, 0, sizeof(*f));   // identifiant réutilisé : l'ancien rôle s'arrête
    for (int i = 0; i < RT_TOUCH_MAX_FINGERS && !f; ++i) if (!r->fingers[i].id) f = &r->fingers[i];
    if (!f) { publish(r); return; }
    (void)t;   // la vitesse du trackpad part du premier mouvement
    rt_touch_finger next = {.id = id, .start = p, .at = p};
    int button = rt_touch_button_at(&r->layout, p);
    int left = p.x < b.x + b.w / 2;
    if (button >= 0) { next.role = RT_TOUCH_BUTTON; next.action = (rt_touch_action)button; }
    else if (left && !role_taken(r, RT_TOUCH_MOVE)) next.role = RT_TOUCH_MOVE;
    else if (!left && !role_taken(r, RT_TOUCH_LOOK)) next.role = RT_TOUCH_LOOK;
    else { publish(r); return; }   // second doigt sur un stick déjà tenu : ignoré
    *f = next;
    if (button == RT_TOUCH_LOOK_MODE) rt_touch_set_trackpad(r, !r->trackpad);
    publish(r);
}

void rt_touch_moved(rt_touch_router *r, uintptr_t id, rt_touch_point p, double t) {
    rt_touch_finger *f = finger_of(r, id);
    if (!f) return;
    if (f->role == RT_TOUCH_LOOK && r->trackpad) {
        const rt_touch_tuning *k = &r->tuning;
        double dx = p.x - f->at.x, dy = p.y - f->at.y, dt = t - f->stamp;
        // dt borné : premier mouvement (stamp nul) ou doigt resté immobile longtemps.
        if (f->stamp > 0 && dt > 1e-4)
            f->speed += k->accel_smooth * (fmin(hypot(dx, dy) / fmin(dt, .1), 1e4) - f->speed);
        f->stamp = t;
        float gain = kTrackpadLook * k->look_speed * rt_touch_trackpad_gain(k, f->speed);
        if (k->log) fprintf(stderr, "[ios] trackpad %.0f pt/s gain %.2f\n", f->speed, rt_touch_trackpad_gain(k, f->speed));
        look_by(r, (float)dx * gain, (float)dy * gain);
    }
    f->at = p;
    publish(r);
}

void rt_touch_up(rt_touch_router *r, uintptr_t id) {
    rt_touch_finger *f = finger_of(r, id);
    if (!f) return;
    memset(f, 0, sizeof(*f));
    publish(r);
}

void rt_touch_external(rt_touch_router *r, rt_touch_action action, int down) {
    if ((int)action < 0 || action >= RT_TOUCH_ACTION_COUNT || action == RT_TOUCH_LOOK_MODE) return;
    if (down) { if (r->active && !r->menu && !r->hidden) ++r->external[action]; }
    else if (r->external[action] > 0) --r->external[action];
    publish(r);
}

void rt_touch_frame(rt_touch_router *r) {
    if (r->trackpad || !rt_touch_takes_touches(r)) return;   // trackpad : mouvements au glissement
    for (int i = 0; i < RT_TOUCH_MAX_FINGERS; ++i) {
        const rt_touch_finger *f = &r->fingers[i];
        if (!f->id || f->role != RT_TOUCH_LOOK) continue;
        float x, y, scale = kStickLook * r->tuning.look_speed;   // quadratique : lent près du centre pour viser
        rt_touch_deflection(r->layout.stick_radius, f->start, f->at, &x, &y);
        look_by(r, x * fabsf(x) * scale, -y * fabsf(y) * scale);
    }
}

int rt_touch_held(const rt_touch_router *r, rt_touch_action action) {
    if ((int)action < 0 || action >= RT_TOUCH_ACTION_COUNT) return 0;
    if (action != RT_TOUCH_LOOK_MODE) return r->emitted[action];
    for (int i = 0; i < RT_TOUCH_MAX_FINGERS; ++i)
        if (r->fingers[i].id && r->fingers[i].role == RT_TOUCH_BUTTON && r->fingers[i].action == action) return 1;
    return 0;
}

int rt_touch_role_points(const rt_touch_router *r, rt_touch_role role, rt_touch_point *start, rt_touch_point *at) {
    for (int i = 0; i < RT_TOUCH_MAX_FINGERS; ++i) {
        const rt_touch_finger *f = &r->fingers[i];
        if (!f->id || f->role != role) continue;
        if (start) *start = f->start;
        if (at) *at = f->at;
        return 1;
    }
    return 0;
}

int rt_touch_finger_count(const rt_touch_router *r) {
    int n = 0;
    for (int i = 0; i < RT_TOUCH_MAX_FINGERS; ++i) n += r->fingers[i].id != 0;
    return n;
}

void rt_touch_deflection(float radius, rt_touch_point start, rt_touch_point at, float *x, float *y) {
    float dx = at.x - start.x, dy = start.y - at.y, dist = hypotf(dx, dy);
    *x = *y = 0;
    if (!(radius > 0) || !isfinite(dist)) return;
    if (dist > radius) { dx *= radius / dist; dy *= radius / dist; dist = radius; }
    float dead = radius * .15f;
    if (dist < dead) return;
    float k = (dist - dead) / (radius - dead) / dist;
    *x = dx * k; *y = dy * k;
}

void rt_touch_move_keys(float x, float y, int wanted[4]) {
    wanted[0] = wanted[1] = wanted[2] = wanted[3] = 0;   // W, A, S, D
    if (hypotf(x, y) < .2f) return;
    float angle = atan2f(y, x);   // secteurs de 45° : les diagonales enfoncent deux touches
    const float pi = (float)M_PI;
    wanted[0] = angle > pi / 8 && angle < pi - pi / 8;
    wanted[2] = angle < -pi / 8 && angle > -pi + pi / 8;
    wanted[3] = fabsf(angle) < 3 * pi / 8;
    wanted[1] = fabsf(angle) > 5 * pi / 8;
}
