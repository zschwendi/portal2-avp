#include "p2_xr.h"
#include <math.h>
#include <pthread.h>
#include <string.h>

static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t active_session, next_session;
static uint64_t last_sequence;
static double last_presentation_time;
static P2XRFrame latest_frame;
static P2XRInput latest_input;

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
    return 1;
}
uint64_t p2_xr_begin_session(void) {
    pthread_mutex_lock(&state_lock);
    active_session = ++next_session;
    last_sequence = 0;
    last_presentation_time = 0;
    memset(&latest_frame, 0, sizeof(latest_frame));
    memset(&latest_input, 0, sizeof(latest_input));
    uint64_t session = active_session;
    pthread_mutex_unlock(&state_lock);
    return session;
}
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
    }
    pthread_mutex_unlock(&state_lock);
}
int p2_xr_publish_frame(uint64_t session, const P2XRFrame *frame) {
    pthread_mutex_lock(&state_lock);
    int accepted = session && session == active_session;
    if (accepted) {
        if (!valid_frame(frame)) {
            memset(&latest_frame, 0, sizeof(latest_frame));
            memset(&latest_input, 0, sizeof(latest_input));
            accepted = 0;
        } else if (frame->sequence <= last_sequence ||
                   frame->presentation_time < last_presentation_time) accepted = 0;
        else {
            latest_frame = *frame;
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
        if (latest_frame.tracked && input->connected &&
            isfinite(input->move_x) && isfinite(input->move_y) && isfinite(input->turn_x) &&
            isfinite(input->blue_trigger) && isfinite(input->orange_trigger)) {
            latest_input = *input;
            latest_input.move_x = axis(input->move_x, -1);
            latest_input.move_y = axis(input->move_y, -1);
            latest_input.turn_x = axis(input->turn_x, -1);
            latest_input.blue_trigger = axis(input->blue_trigger, 0);
            latest_input.orange_trigger = axis(input->orange_trigger, 0);
            latest_input.buttons &= P2_XR_JUMP | P2_XR_CROUCH | P2_XR_USE | P2_XR_PAUSE | P2_XR_RECENTER;
        }
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
int p2_xr_source_view(const P2XRFrame *frame, uint32_t eye,
                      matrix_float4x4 transform, P2XRSourceView *out) {
    if (!out || eye >= P2_XR_EYE_COUNT || !valid_frame(frame) || !finite_matrix(transform) ||
        fabsf(simd_determinant(transform)) < 1e-8f) return 0;
    matrix_float4x4 pose = simd_mul(transform, simd_mul(frame->tracking_from_head, frame->eyes[eye].head_from_eye));
    vector_float3 forward = simd_normalize(-pose.columns[2].xyz);
    vector_float3 right = simd_normalize(pose.columns[0].xyz), up = simd_normalize(pose.columns[1].xyz);
    float degrees = 180 / (float)M_PI;
    out->origin = pose.columns[3].xyz;
    out->angles = (vector_float3){atan2f(-forward.z, hypotf(forward.x, forward.y)) * degrees,
        atan2f(forward.y, forward.x) * degrees, atan2f(-right.z, up.z) * degrees};
    out->projection = frame->eyes[eye].projection;
    return 1;
}
int p2_xr_cross_portal(matrix_float4x4 portal, matrix_float4x4 *transform) {
    if (!transform || !valid_pose(portal) || !finite_matrix(*transform)) return 0;
    *transform = simd_mul(portal, *transform);
    return 1;
}
