#include "p2_xr.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static void near(float actual, float expected) { assert(fabsf(actual - expected) < 0.001f); }
static P2XRFrame frame(void) {
    P2XRFrame f = {.sequence = 1, .presentation_time = 1, .tracked = 1, .eye_count = 2,
                   .tracking_from_head = matrix_identity_float4x4};
    f.tracking_from_head.columns[3] = (vector_float4){2, 1.6f, 3, 1};
    for (unsigned e = 0; e < 2; ++e) {
        f.eyes[e].head_from_eye = matrix_identity_float4x4;
        f.eyes[e].head_from_eye.columns[3].x = e ? 0.032f : -0.032f;
        f.eyes[e].projection = matrix_identity_float4x4;
    }
    return f;
}
static void views_and_portals(void) {
    P2XRFrame f = frame();
    matrix_float4x4 alignment;
    vector_float3 origin = {100, 200, 64};
    assert(p2_xr_align(&f, origin, 0, P2_XR_UNITS_PER_METER, &alignment));
    P2XRSourceView left, right;
    assert(p2_xr_source_view(&f, 0, alignment, &left));
    assert(p2_xr_source_view(&f, 1, alignment, &right));
    near(left.origin.x, 100); near(left.origin.z, 64);
    near((left.origin.y + right.origin.y) / 2, 200);
    near(left.origin.y - right.origin.y, 0.064f * P2_XR_UNITS_PER_METER);
    near(left.angles.x, 0); near(left.angles.y, 0); near(left.angles.z, 0);
    // Leaning right moves right in Source, without accumulating an offset.
    f.tracking_from_head.columns[3].x += 0.1f;
    assert(p2_xr_source_view(&f, 0, alignment, &left));
    near(left.origin.y, 200 + (0.032f - 0.1f) * P2_XR_UNITS_PER_METER);
    f = frame();
    // A 90-degree yaw portal: rotate the whole tracking origin once.
    matrix_float4x4 portal = {{{0,1,0,0}, {-1,0,0,0}, {0,0,1,0}, {10,20,30,1}}};
    assert(p2_xr_cross_portal(portal, &alignment));
    assert(p2_xr_source_view(&f, 0, alignment, &left));
    assert(p2_xr_source_view(&f, 1, alignment, &right));
    near(left.angles.y, 90);
    near(simd_distance(left.origin, right.origin), 0.064f * P2_XR_UNITS_PER_METER);
    near((left.origin.x + right.origin.x) / 2, -190);
    near((left.origin.y + right.origin.y) / 2, 120);
    near(left.origin.z, 94);
    // A wall-to-floor portal rotates pitch too, not just yaw.
    matrix_float4x4 tilt = {{{0,0,1,0}, {0,1,0,0}, {-1,0,0,0}, {0,0,0,1}}};
    assert(p2_xr_align(&f, origin, 0, P2_XR_UNITS_PER_METER, &alignment));
    assert(p2_xr_cross_portal(tilt, &alignment));
    assert(p2_xr_source_view(&f, 0, alignment, &left));
    near(left.angles.x, -90);
    // Recenter aligns current yaw to the player's body, retaining head pitch.
    float a = (float)M_PI / 6;
    f.tracking_from_head.columns[1] = (vector_float4){0,cosf(a),sinf(a),0};
    f.tracking_from_head.columns[2] = (vector_float4){0,-sinf(a),cosf(a),0};
    assert(p2_xr_align(&f, origin, 45, P2_XR_UNITS_PER_METER, &alignment));
    assert(p2_xr_source_view(&f, 0, alignment, &left));
    near(left.angles.x, -30); near(left.angles.y, 45);
    matrix_float4x4 before = alignment;
    portal.columns[0].x = NAN;
    assert(!p2_xr_cross_portal(portal, &alignment));
    assert(!memcmp(&before, &alignment, sizeof(before)));
    assert(!p2_xr_source_view(&f, 2, alignment, &left));
    assert(!p2_xr_align(&f, origin, 0, 0, &alignment));
    f.eyes[0].projection = (matrix_float4x4){0};
    assert(!p2_xr_align(&f, origin, 0, 1, &alignment));
}
static void session_and_input(void) {
    uint64_t old = p2_xr_begin_session();
    P2XRFrame f = frame(), read;
    P2XRInput in = {.move_x=2, .blue_trigger=1, .buttons=P2_XR_JUMP, .connected=1}, out;
    assert(p2_xr_publish_frame(old, &f));
    assert(p2_xr_publish_input(old, &in));
    assert(p2_xr_read(old, &read, &out));
    near(out.move_x, 1); near(out.blue_trigger, 1); assert(out.buttons == P2_XR_JUMP);
    // Duplicate/out-of-order poses must never rewind the camera.
    assert(!p2_xr_publish_frame(old, &f));
    f.sequence = 2; f.presentation_time = 0.5;
    assert(!p2_xr_publish_frame(old, &f));
    f.presentation_time = 2; f.tracked = 0;
    assert(!p2_xr_publish_frame(old, &f));
    assert(!p2_xr_read(old, &read, &out));
    assert(out.blue_trigger == 0 && out.buttons == 0);
    f = frame(); assert(!p2_xr_publish_frame(old, &f));
    f.sequence = 3; f.presentation_time = 3;
    assert(p2_xr_publish_frame(old, &f));
    in.move_x = NAN;
    p2_xr_publish_input(old, &in);
    assert(p2_xr_read(old, &read, &out)); assert(out.connected == 0);
    in.move_x = 0; in.connected = 0;
    p2_xr_publish_input(old, &in);
    p2_xr_read(old, &read, &out); assert(out.buttons == 0 && out.blue_trigger == 0);
    in.connected = 1;
    p2_xr_publish_input(old, &in); p2_xr_release_input(old);
    p2_xr_read(old, &read, &out); assert(out.buttons == 0);
    uint64_t current = p2_xr_begin_session();
    assert(current != old && !p2_xr_session_active(old));
    assert(!p2_xr_publish_frame(old, &f));
    assert(!p2_xr_publish_input(old, &in));
    p2_xr_end_session(old);
    assert(p2_xr_session_active(current));
    assert(p2_xr_publish_frame(current, &f));
    assert(p2_xr_publish_input(current, &in));
    p2_xr_release_input(old);
    assert(p2_xr_read(current, &read, &out)); assert(out.blue_trigger == 1);
    p2_xr_end_session(current);
    assert(!p2_xr_read(current, &read, &out));
    assert(!out.connected && !read.tracked);
}
static void *reader(void *arg) {
    uint64_t session = *(uint64_t *)arg;
    for (int i = 0; i < 10000; ++i) {
        P2XRFrame f; P2XRInput in;
        if (p2_xr_read(session, &f, &in)) {
            // All three fields are a single coherent publication.
            assert(f.tracking_from_head.columns[3].x == (float)f.sequence);
            assert(f.presentation_time == (double)f.sequence);
        }
    }
    return NULL;
}
static void concurrent_publication(void) {
    uint64_t session = p2_xr_begin_session();
    pthread_t thread; assert(!pthread_create(&thread, NULL, reader, &session));
    P2XRFrame f = frame();
    for (uint64_t n = 1; n <= 10000; ++n) {
        f.sequence = n; f.presentation_time = (double)n;
        f.tracking_from_head.columns[3].x = (float)n;
        assert(p2_xr_publish_frame(session, &f));
    }
    assert(!pthread_join(thread, NULL));
    p2_xr_end_session(session);
}
int main(void) {
    views_and_portals(); session_and_input(); concurrent_publication();
    puts("XR contract passed: stereo, scale, recenter, full portal rotation, tracking loss, input release, session isolation, concurrent publication");
    return 0;
}
