#include "p2_xr.h"
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t active_session, next_session;
static uint64_t last_sequence;
static double last_presentation_time;
static P2XRFrame latest_frame;
static P2XRInput latest_input;
static int window_session;
// Right Sense controller tracking loss in an immersive session: actions held
// at that moment are released at once (GameController may send no new event)
// and stay released until that control is let go. Sticks and every other
// control keep flowing, so an occluded or left-only Sense pair (which owns
// input on the Swift side) is never dead. Only the tracked aim is gated on
// right-controller tracking (p2_xr_aim_fresh); shots fall back to the head.
#define P2_XR_TRIGGER_RELEASE 0.1f
static uint32_t held_buttons;
static int held_blue, held_orange;
static void forget_held(void) { held_buttons = 0; held_blue = held_orange = 0; }
static void release_held(void) {
    held_buttons |= latest_input.buttons;
    held_blue |= latest_input.blue_trigger > P2_XR_TRIGGER_RELEASE;
    held_orange |= latest_input.orange_trigger > P2_XR_TRIGGER_RELEASE;
    latest_input.buttons = 0;
    latest_input.blue_trigger = latest_input.orange_trigger = 0;
}
static void mask_held(void) {
    held_buttons &= latest_input.buttons; // a control let go is usable again
    latest_input.buttons &= ~held_buttons;
    if (held_blue && latest_input.blue_trigger <= P2_XR_TRIGGER_RELEASE) held_blue = 0;
    if (held_orange && latest_input.orange_trigger <= P2_XR_TRIGGER_RELEASE) held_orange = 0;
    if (held_blue) latest_input.blue_trigger = 0;
    if (held_orange) latest_input.orange_trigger = 0;
}
uint32_t p2_xr_abi_version(void) { return P2_XR_ABI_VERSION; }

static int finite_matrix(matrix_float4x4 m) {
    for (int c = 0; c < 4; ++c)
        for (int r = 0; r < 4; ++r)
            if (!isfinite(m.columns[c][r])) return 0;
    return 1;
}
static int finite_vector(vector_float3 v) {
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z);
}
static int valid_pose(matrix_float4x4 m) {
    if (!finite_matrix(m) || fabsf(m.columns[3].w - 1) > 1e-4f) return 0;
    for (int c = 0; c < 3; ++c) {
        if (fabsf(m.columns[c].w) > 1e-4f) return 0;
        vector_float3 a = m.columns[c].xyz;
        if (fabsf(simd_length_squared(a) - 1) > 1e-3f) return 0;
        for (int b = 0; b < c; ++b)
            if (fabsf(simd_dot(a, m.columns[b].xyz)) > 1e-3f) return 0;
    }
    return simd_dot(simd_cross(m.columns[0].xyz, m.columns[1].xyz), m.columns[2].xyz) > 0.999f;
}
static int valid_frame(const P2XRFrame *f) {
    if (!f || !f->tracked || !f->sequence || f->eye_count != P2_XR_EYE_COUNT ||
        !isfinite(f->presentation_time) || f->presentation_time <= 0 ||
        !valid_pose(f->tracking_from_head)) return 0;
    for (unsigned e = 0; e < P2_XR_EYE_COUNT; ++e)
        if (!valid_pose(f->eyes[e].head_from_eye) || !finite_matrix(f->eyes[e].projection) ||
            fabsf(simd_determinant(f->eyes[e].projection)) < 1e-8f) return 0;
    for (unsigned hand = 0; hand < 2; ++hand)
        if (f->controllers[hand].tracked &&
            (!valid_pose(f->controllers[hand].tracking_from_aim) ||
             !valid_pose(f->controllers[hand].tracking_from_grip))) return 0;
    return 1;
}
static uint64_t begin_session(int windowed) {
    pthread_mutex_lock(&state_lock);
    active_session = ++next_session;
    window_session = windowed;
    last_sequence = 0;
    last_presentation_time = 0;
    memset(&latest_frame, 0, sizeof(latest_frame));
    memset(&latest_input, 0, sizeof(latest_input));
    forget_held();
    uint64_t session = active_session;
    pthread_mutex_unlock(&state_lock);
    return session;
}
uint64_t p2_xr_begin_session(void) { return begin_session(0); }
uint64_t p2_xr_begin_window_session(void) { return begin_session(1); }
int p2_xr_session_active(uint64_t session) {
    pthread_mutex_lock(&state_lock);
    int active = session && session == active_session;
    pthread_mutex_unlock(&state_lock);
    return active;
}
void p2_xr_end_session(uint64_t session) {
    pthread_mutex_lock(&state_lock);
    if (session && session == active_session) {
        active_session = 0;
        memset(&latest_frame, 0, sizeof(latest_frame));
        memset(&latest_input, 0, sizeof(latest_input));
        forget_held();
    }
    pthread_mutex_unlock(&state_lock);
}
int p2_xr_publish_frame(uint64_t session, const P2XRFrame *frame) {
    pthread_mutex_lock(&state_lock);
    int accepted = session && session == active_session && !window_session;
    if (accepted) {
        if (!valid_frame(frame)) {
            memset(&latest_frame, 0, sizeof(latest_frame));
            memset(&latest_input, 0, sizeof(latest_input));
            accepted = 0;
        } else if (frame->sequence <= last_sequence ||
                   frame->presentation_time < last_presentation_time) accepted = 0;
        else {
            int lost = latest_frame.tracked && latest_frame.controllers[1].tracked && !frame->controllers[1].tracked;
            latest_frame = *frame;
            if (lost && latest_input.spatial) release_held();
            last_sequence = frame->sequence;
            last_presentation_time = frame->presentation_time;
        }
    }
    pthread_mutex_unlock(&state_lock);
    return accepted;
}
static float axis(float value, float low) { return fmaxf(low, fminf(1, value)); }
int p2_xr_publish_input(uint64_t session, const P2XRInput *input) {
    pthread_mutex_lock(&state_lock);
    int accepted = session && session == active_session && input;
    if (accepted) {
        memset(&latest_input, 0, sizeof(latest_input));
        if ((window_session || latest_frame.tracked) && input->connected &&
            isfinite(input->move_x) && isfinite(input->move_y) && isfinite(input->turn_x) &&
            isfinite(input->look_y) && isfinite(input->blue_trigger) && isfinite(input->orange_trigger)) {
            latest_input = *input;
            latest_input.move_x = axis(input->move_x, -1);
            latest_input.move_y = axis(input->move_y, -1);
            latest_input.turn_x = axis(input->turn_x, -1);
            latest_input.look_y = axis(input->look_y, -1);
            latest_input.blue_trigger = axis(input->blue_trigger, 0);
            latest_input.orange_trigger = axis(input->orange_trigger, 0);
            latest_input.buttons &= P2_XR_JUMP | P2_XR_CROUCH | P2_XR_USE | P2_XR_PAUSE | P2_XR_RECENTER | P2_XR_WINDOW;
        }
        // A held mask survives a rejected sample (no head frame yet, NaN);
        // another device, a disconnect or the window forgets it.
        if (window_session || !input->spatial || !input->connected) forget_held();
        else if (latest_input.spatial) mask_held();
    }
    pthread_mutex_unlock(&state_lock);
    return accepted;
}
int p2_xr_read(uint64_t session, P2XRFrame *frame, P2XRInput *input) {
    pthread_mutex_lock(&state_lock);
    int valid = session && session == active_session && latest_frame.tracked;
    if (frame) { memset(frame, 0, sizeof(*frame)); if (valid) *frame = latest_frame; }
    if (input) { memset(input, 0, sizeof(*input)); if (valid) *input = latest_input; }
    pthread_mutex_unlock(&state_lock);
    return valid;
}
uint64_t p2_xr_read_latest(P2XRFrame *frame, P2XRInput *input) {
    pthread_mutex_lock(&state_lock);
    uint64_t session = latest_frame.tracked ? active_session : 0;
    if (frame) { memset(frame, 0, sizeof(*frame)); if (session) *frame = latest_frame; }
    if (input) { memset(input, 0, sizeof(*input)); if (session) *input = latest_input; }
    pthread_mutex_unlock(&state_lock);
    return session;
}
uint64_t p2_xr_read_controls(P2XRInput *input) {
    pthread_mutex_lock(&state_lock);
    uint64_t session = (window_session || latest_frame.tracked) ? active_session : 0;
    if (input) { memset(input,0,sizeof(*input)); if (session) *input = latest_input; }
    pthread_mutex_unlock(&state_lock);
    return session;
}
void p2_xr_release_input(uint64_t session) {
    pthread_mutex_lock(&state_lock);
    if (session && session == active_session) memset(&latest_input, 0, sizeof(latest_input));
    pthread_mutex_unlock(&state_lock);
}
int p2_xr_align(const P2XRFrame *frame, vector_float3 origin, float yaw,
                float scale, matrix_float4x4 *out) {
    if (!out || !valid_frame(frame) || !finite_vector(origin) || !isfinite(yaw) ||
        !isfinite(scale) || scale <= 0) return 0;
    vector_float3 forward = -frame->tracking_from_head.columns[2].xyz;
    // Yaw has no stable definition when looking straight up/down. Preserve
    // the previous alignment instead of changing it discontinuously.
    if (hypotf(forward.x, forward.z) < 1e-4f) return 0;
    float offset = yaw * (float)M_PI / 180 - atan2f(-forward.x, -forward.z);
    float c = cosf(offset), s = sinf(offset);
    matrix_float4x4 m = {{
        {s * scale, -c * scale, 0, 0},
        {0, 0, scale, 0},
        {-c * scale, -s * scale, 0, 0},
        {0, 0, 0, 1}
    }};
    vector_float3 translation = origin - simd_mul(m, frame->tracking_from_head.columns[3]).xyz;
    m.columns[3] = (vector_float4){translation.x, translation.y, translation.z, 1};
    *out = m;
    return 1;
}
static void source_pose(matrix_float4x4 pose, P2XRSourceView *out) {
    vector_float3 forward = simd_normalize(-pose.columns[2].xyz);
    vector_float3 right = simd_normalize(pose.columns[0].xyz), up = simd_normalize(pose.columns[1].xyz);
    float degrees = 180 / (float)M_PI;
    out->origin = pose.columns[3].xyz;
    out->angles = (vector_float3){atan2f(-forward.z, hypotf(forward.x, forward.y)) * degrees,
        atan2f(forward.y, forward.x) * degrees, atan2f(-right.z, up.z) * degrees};
}
int p2_xr_source_view(const P2XRFrame *frame, uint32_t eye,
                      matrix_float4x4 transform, P2XRSourceView *out) {
    if (!out || eye >= P2_XR_EYE_COUNT || !valid_frame(frame) || !finite_matrix(transform) ||
        fabsf(simd_determinant(transform)) < 1e-8f) return 0;
    source_pose(simd_mul(transform, simd_mul(frame->tracking_from_head, frame->eyes[eye].head_from_eye)), out);
    out->projection = frame->eyes[eye].projection;
    return 1;
}
int p2_xr_source_controller(const P2XRFrame *frame, uint32_t hand,
                           matrix_float4x4 transform, P2XRSourceView *out) {
    if (!out || hand >= 2 || !valid_frame(frame) || !frame->controllers[hand].tracked ||
        !finite_matrix(transform) || fabsf(simd_determinant(transform)) < 1e-8f) return 0;
    source_pose(simd_mul(transform, frame->controllers[hand].tracking_from_aim), out);
    out->projection = matrix_identity_float4x4;
    return 1;
}
int p2_xr_cross_portal(matrix_float4x4 portal, matrix_float4x4 *transform) {
    if (!transform || !valid_pose(portal) || !finite_matrix(*transform)) return 0;
    *transform = simd_mul(portal, *transform);
    return 1;
}

int p2_xr_cover_projection(matrix_float4x4 p, float aspect, matrix_float4x4 *cover, float *fov) {
    if (!cover || !finite_matrix(p) || !isfinite(aspect) || aspect < 0.1f || aspect > 10) return 0;
    // Only a plain perspective (clip w = -z, no skew/rotation) has tangent
    // extents: x = (2X + (R+L)Z)/(R-L) etc. Anything else stays mono.
    float off = fabsf(p.columns[0].y) + fabsf(p.columns[0].z) + fabsf(p.columns[0].w) +
        fabsf(p.columns[1].x) + fabsf(p.columns[1].z) + fabsf(p.columns[1].w) +
        fabsf(p.columns[3].x) + fabsf(p.columns[3].y) + fabsf(p.columns[3].w);
    float sx = p.columns[0].x, sy = p.columns[1].y;
    if (!(sx > 0 && sy > 0) || off > 1e-5f || fabsf(p.columns[2].w + 1) > 1e-5f) return 0;
    float right = (1 + fabsf(p.columns[2].x)) / sx, up = (1 + fabsf(p.columns[2].y)) / sy;
    float half_x = fmaxf(right, up * aspect), half_y = half_x / aspect;
    float degrees = 2 * atanf(half_x) * 180 / (float)M_PI;
    if (!(degrees > 1 && degrees < 170)) return 0;
    p.columns[0].x = 1 / half_x; p.columns[1].y = 1 / half_y;
    p.columns[2].x = 0; p.columns[2].y = 0;  // depth (z) and w rows unchanged
    *cover = p;
    if (fov) *fov = degrees;
    return 1;
}

static int turn_about(matrix_float4x4 *transform, vector_float3 pivot, float degrees) {
    if (!finite_matrix(*transform) || !finite_vector(pivot) || !isfinite(degrees)) return 0;
    float r = degrees * (float)M_PI / 180, c = cosf(r), s = sinf(r);
    matrix_float4x4 turn = {{{c,s,0,0},{-s,c,0,0},{0,0,1,0},{0,0,0,1}}};
    vector_float3 shift = pivot - simd_mul(turn, (vector_float4){pivot.x,pivot.y,pivot.z,1}).xyz;
    turn.columns[3] = (vector_float4){shift.x,shift.y,shift.z,1};
    *transform = simd_mul(turn, *transform);
    return 1;
}
int p2_xr_body_align(P2XRBody *body, const P2XRFrame *frame, vector_float3 origin,
                     float yaw, float scale) {
    matrix_float4x4 transform;
    if (!body || !p2_xr_align(frame, origin, yaw, scale, &transform)) return 0;
    *body = (P2XRBody){.source_from_tracking=transform,.origin=origin,.engine_yaw=yaw,.aligned=1};
    return 1;
}
float p2_xr_body_observe(P2XRBody *body, float yaw) {
    if (!body || !isfinite(yaw)) return 0;
    float turn = body->aligned && isfinite(body->engine_yaw) ? remainderf(yaw - body->engine_yaw, 360) : 0;
    body->engine_yaw = yaw;
    // The engine normalizes stored angles to [-180,180]; ignore rounding.
    if (fabsf(turn) <= 1e-3f || !turn_about(&body->source_from_tracking, body->origin, turn)) return 0;
    return turn;
}
int p2_xr_body_turn(P2XRBody *body, float degrees) {
    return body && body->aligned && turn_about(&body->source_from_tracking, body->origin, degrees);
}
int p2_xr_body_follow(P2XRBody *body, vector_float3 origin) {
    if (!body || !body->aligned || !finite_vector(origin)) return 0;
    vector_float3 shift = origin - body->origin;
    if (simd_any(shift != 0)) {
        matrix_float4x4 move = matrix_identity_float4x4;
        move.columns[3] = (vector_float4){shift.x,shift.y,shift.z,1};
        body->source_from_tracking = simd_mul(move, body->source_from_tracking);
    }
    body->origin = origin;
    return 1;
}
int p2_xr_body_aim(P2XRBody *body, const P2XRFrame *frame, vector_float3 *angles) {
    if (!body || !body->aligned || !angles || !valid_frame(frame) ||
        !finite_matrix(body->source_from_tracking) ||
        fabsf(simd_determinant(body->source_from_tracking)) < 1e-8f) return 0;
    matrix_float4x4 head = simd_mul(body->source_from_tracking, frame->tracking_from_head);
    vector_float3 forward = simd_normalize(-head.columns[2].xyz);
    // Straight up/down has no stable yaw: keep the last engine angles.
    if (hypotf(forward.x, forward.y) < 1e-3f) return 0;
    P2XRSourceView view;
    source_pose(head, &view);
    *angles = (vector_float3){fmaxf(-P2_XR_PITCH_LIMIT, fminf(P2_XR_PITCH_LIMIT, view.angles.x)), view.angles.y, 0};
    body->engine_yaw = angles->y;
    return 1;
}

float p2_xr_snap_turn(P2XRSnapTurn *state, float x, float step) {
    if (!state) return 0;
    if (!isfinite(x) || !isfinite(step)) { state->latched = 0; return 0; }
    if (state->latched) {
        if (fabsf(x) < P2_XR_SNAP_RELEASE) state->latched = 0;
        return 0;
    }
    if (fabsf(x) <= P2_XR_SNAP_ENGAGE) return 0;
    state->latched = 1;
    return x > 0 ? -step : step;
}
float p2_xr_smooth_turn(float x, float rate, float seconds) {
    const float dead = 0.15f;
    if (!isfinite(x) || !isfinite(rate) || !isfinite(seconds) || fabsf(x) <= dead) return 0;
    float amount = (fminf(fabsf(x), 1) - dead) / (1 - dead);
    // A stalled frame must not become one large turn.
    return (x > 0 ? -amount : amount) * rate * fmaxf(0, fminf(seconds, 0.1f));
}
int p2_xr_setting(const char *text, float fallback, float low, float high, float *value) {
    if (value) *value = fallback;
    if (!text || !*text) return 0;
    char *end;
    float parsed = strtof(text, &end);
    if (end == text || *end || !isfinite(parsed) || parsed < low || parsed > high) return -1;
    if (value) *value = parsed;
    return 1;
}

// ---- Tracked controller (Sense) portal aim ---------------------------------
static vector_float3 angle_forward(vector_float3 angles) {
    float pitch = angles.x * (float)M_PI / 180, yaw = angles.y * (float)M_PI / 180;
    return (vector_float3){cosf(pitch) * cosf(yaw), cosf(pitch) * sinf(yaw), -sinf(pitch)};
}
static int invertible(matrix_float4x4 m) {
    return finite_matrix(m) && fabsf(simd_determinant(m)) > 1e-8f;
}
int p2_xr_aim_basis(P2XRAimBasis *basis, uint64_t session, uint64_t sequence, double stamp,
                    const P2XRBody *body, vector_float3 head_angles) {
    if (!basis || !session || !sequence || !isfinite(stamp) || !body || !body->aligned ||
        !invertible(body->source_from_tracking) || !finite_vector(body->origin) || !finite_vector(head_angles)) return 0;
    *basis = (P2XRAimBasis){.session=session,.sequence=sequence,.stamp=stamp,
        .source_from_tracking=body->source_from_tracking,.eye=body->origin,.head=angle_forward(head_angles)};
    return 1;
}
int p2_xr_aim_fresh(const P2XRAimBasis *basis, uint64_t session, const P2XRFrame *latest, double now) {
    return basis && basis->session && session == basis->session && valid_frame(latest) &&
        latest->controllers[P2_XR_AIM_HAND].tracked &&
        latest->sequence >= basis->sequence && latest->sequence - basis->sequence <= P2_XR_AIM_MAX_FRAMES &&
        isfinite(now) && now >= basis->stamp && now - basis->stamp <= P2_XR_AIM_MAX_AGE;
}
int p2_xr_aim_controller(const P2XRAimBasis *basis, const P2XRFrame *latest,
                         vector_float3 *offset, vector_float3 *direction) {
    if (!basis || !offset || !direction || !valid_frame(latest) || !latest->controllers[P2_XR_AIM_HAND].tracked ||
        !invertible(basis->source_from_tracking) || !finite_vector(basis->eye)) return 0;
    matrix_float4x4 aim = simd_mul(basis->source_from_tracking, latest->controllers[P2_XR_AIM_HAND].tracking_from_aim);
    vector_float3 forward = -aim.columns[2].xyz, from = aim.columns[3].xyz - basis->eye;
    if (!finite_vector(forward) || !finite_vector(from) || simd_length(forward) < 1e-6f) return 0;
    *offset = from;
    *direction = simd_normalize(forward);
    return 1;
}
int p2_xr_aim_start(vector_float3 engine_start, vector_float3 offset, vector_float3 *start) {
    if (!start || !finite_vector(engine_start) || !finite_vector(offset)) return 0;
    if (simd_length(offset) > P2_XR_AIM_REACH) { *start = engine_start; return 2; }
    vector_float3 low = {-P2_XR_AIM_HALF_WIDTH, -P2_XR_AIM_HALF_WIDTH, -P2_XR_AIM_BELOW};
    vector_float3 high = {P2_XR_AIM_HALF_WIDTH, P2_XR_AIM_HALF_WIDTH, P2_XR_AIM_ABOVE};
    *start = engine_start + simd_clamp(offset, low, high);
    return 1;
}
int p2_xr_aim_ray(const P2XRAimBasis *basis, const P2XRFrame *latest,
                  vector_float3 engine_start, vector_float3 engine_direction,
                  vector_float3 *start, vector_float3 *direction) {
    if (!basis || !start || !direction || !finite_vector(engine_direction) || !finite_vector(basis->head)) return 0;
    // The engine builds the direction with AngleVectors: a unit vector.
    float length = simd_length(engine_direction);
    if (fabsf(length - 1) > 0.02f) return 0;
    float agreement = simd_dot(engine_direction / length, simd_normalize(basis->head));
    if (!(agreement >= cosf(P2_XR_AIM_HEAD_TOLERANCE * (float)M_PI / 180))) return 0;
    vector_float3 offset, aim, from;
    if (!p2_xr_aim_controller(basis, latest, &offset, &aim) || !finite_vector(engine_start)) return 0;
    // A start far from the eye the body wrote was moved by the engine (the
    // player straddles a portal, or the gun's minimum range): keep it, with
    // the controller direction, so no plane between eye and start is skipped.
    if (simd_distance(engine_start, basis->eye) > P2_XR_AIM_REACH) from = engine_start;
    else if (!p2_xr_aim_start(engine_start, offset, &from)) return 0;
    *start = from;
    *direction = aim;
    return 1;
}
int p2_xr_aim_viewmodel(const P2XRAimBasis *basis, const P2XRFrame *latest, vector_float3 eye,
                        vector_float3 grip_offset, P2XRSourceView *pose) {
    if (!basis || !pose || !finite_vector(eye) || !finite_vector(grip_offset) || !valid_frame(latest) ||
        !latest->controllers[P2_XR_AIM_HAND].tracked || !invertible(basis->source_from_tracking) ||
        !finite_vector(basis->eye)) return 0;
    const P2XRControllerPose *hand = &latest->controllers[P2_XR_AIM_HAND];
    matrix_float4x4 aim = simd_mul(basis->source_from_tracking, hand->tracking_from_aim);
    vector_float3 grip = simd_mul(basis->source_from_tracking, hand->tracking_from_grip.columns[3]).xyz;
    // Apple -Z forward, -X left (Source +Y), +Y up, scaled to Source units.
    vector_float3 forward = simd_normalize(-aim.columns[2].xyz), left = simd_normalize(-aim.columns[0].xyz),
        up = simd_normalize(aim.columns[1].xyz);
    P2XRSourceView view;
    source_pose(aim, &view);
    // The basis follows the eye of the last render; carry it to this eye.
    view.origin = eye + (grip - basis->eye) + forward * grip_offset.x + left * grip_offset.y + up * grip_offset.z;
    if (!finite_vector(view.origin) || !finite_vector(view.angles)) return 0;
    view.projection = matrix_identity_float4x4;
    *pose = view;
    return 1;
}
