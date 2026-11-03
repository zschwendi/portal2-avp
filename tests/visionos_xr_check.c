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
static void spatial_controller_tracking(void) {
    uint64_t session = p2_xr_begin_session();
    P2XRFrame f = frame(), snapshot;
    P2XRInput input = {.connected=1,.spatial=1,.orange_trigger=1,.buttons=P2_XR_USE}, read;
    f.controllers[1].tracked = 1;
    f.controllers[1].tracking_from_aim = matrix_identity_float4x4;
    f.controllers[1].tracking_from_aim.columns[3] = (vector_float4){2.2f,1.3f,2.6f,1};
    f.controllers[1].tracking_from_grip = f.controllers[1].tracking_from_aim;
    assert(p2_xr_publish_frame(session,&f));
    assert(p2_xr_publish_input(session,&input));
    assert(p2_xr_read_latest(&snapshot,&read) == session);
    assert(read.orange_trigger == 1 && read.buttons == P2_XR_USE);
    matrix_float4x4 alignment;
    assert(p2_xr_align(&snapshot,(vector_float3){100,200,64},0,P2_XR_UNITS_PER_METER,&alignment));
    P2XRSourceView aim;
    assert(p2_xr_source_controller(&snapshot,1,alignment,&aim));
    near(aim.origin.x,100 + 0.4f * P2_XR_UNITS_PER_METER);
    near(aim.origin.y,200 - 0.2f * P2_XR_UNITS_PER_METER);
    near(aim.origin.z,64 - 0.3f * P2_XR_UNITS_PER_METER);
    assert(!p2_xr_source_controller(&snapshot,0,alignment,&aim));
    matrix_float4x4 portal = {{{0,1,0,0}, {-1,0,0,0}, {0,0,1,0}, {10,20,30,1}}};
    assert(p2_xr_cross_portal(portal,&alignment));
    assert(p2_xr_source_controller(&snapshot,1,alignment,&aim));
    near(aim.angles.y,90);
    // Losing the right controller's tracking while holding fire/grab releases
    // those actions at once, even if GameController sends no new button event,
    // and keeps them released until let go. The pair stays connected and its
    // sticks and other controls keep working (aim falls back to the head).
    f.sequence = 2; f.presentation_time = 2; f.controllers[1].tracked = 0;
    assert(p2_xr_publish_frame(session,&f));
    assert(p2_xr_read_latest(&snapshot,&read) == session);
    assert(read.connected && !read.buttons && !read.orange_trigger);
    input.move_x = 0.5f; input.buttons = P2_XR_USE | P2_XR_JUMP;
    p2_xr_publish_input(session,&input); // still held, plus a new press
    p2_xr_read_latest(&snapshot,&read);
    assert(read.connected && read.buttons == P2_XR_JUMP && !read.orange_trigger); near(read.move_x,0.5f);
    input.orange_trigger = 0.05f; input.buttons = P2_XR_USE; // trigger let go, grab still held
    p2_xr_publish_input(session,&input);
    input.orange_trigger = 1;
    p2_xr_publish_input(session,&input);
    p2_xr_read_latest(&snapshot,&read); assert(read.orange_trigger == 1 && !read.buttons);
    input.buttons = 0; p2_xr_publish_input(session,&input);
    input.buttons = P2_XR_USE; p2_xr_publish_input(session,&input);
    p2_xr_read_latest(&snapshot,&read); assert(read.buttons == P2_XR_USE);
    // Staying untracked does not release again; only a new loss does.
    f.sequence = 3; f.presentation_time = 3;
    assert(p2_xr_publish_frame(session,&f));
    p2_xr_read_latest(&snapshot,&read); assert(read.buttons == P2_XR_USE && read.orange_trigger == 1);
    input.spatial = 0; // ordinary DualSense needs no spatial accessory pose
    p2_xr_publish_input(session,&input);
    p2_xr_read_latest(&snapshot,&read); assert(read.orange_trigger == 1);
    input.spatial = 1;
    f.sequence = 4; f.presentation_time = 4; f.controllers[1].tracked = 1;
    f.controllers[1].tracking_from_aim.columns[0].x = NAN;
    assert(!p2_xr_publish_frame(session,&f));
    assert(!p2_xr_read_latest(&snapshot,&read));
    assert(!read.connected && !read.buttons);
    p2_xr_end_session(session);
    // A Sense pair whose right controller is never tracked (left-only,
    // occluded from the start) still drives the game.
    session = p2_xr_begin_session();
    f = frame();
    assert(p2_xr_publish_frame(session,&f));
    input = (P2XRInput){.connected=1,.spatial=1,.move_y=1,.blue_trigger=1,.buttons=P2_XR_JUMP};
    assert(p2_xr_publish_input(session,&input));
    assert(p2_xr_read_controls(&read) == session);
    assert(read.connected && read.buttons == P2_XR_JUMP && read.blue_trigger == 1); near(read.move_y,1);
    // A held mask survives a sample rejected while the head is lost.
    f = frame();
    f.sequence = 2; f.presentation_time = 2;
    f.controllers[1] = (P2XRControllerPose){.tracked=1,.tracking_from_aim=matrix_identity_float4x4,.tracking_from_grip=matrix_identity_float4x4};
    assert(p2_xr_publish_frame(session,&f));
    f.sequence = 3; f.presentation_time = 3; f.controllers[1].tracked = 0;
    assert(p2_xr_publish_frame(session,&f));          // loss: jump and blue released
    f.tracked = 0; assert(!p2_xr_publish_frame(session,&f)); // head lost too
    p2_xr_publish_input(session,&input);               // rejected: no tracked head
    f = frame(); f.sequence = 4; f.presentation_time = 4;
    assert(p2_xr_publish_frame(session,&f));
    p2_xr_publish_input(session,&input);               // still held: still released
    p2_xr_read_controls(&read); assert(read.connected && !read.buttons && !read.blue_trigger);
    p2_xr_end_session(session);
}
static void window_controls(void) {
    uint64_t window = p2_xr_begin_window_session();
    P2XRInput in = {.connected=1,.spatial=1,.blue_trigger=1,.buttons=P2_XR_JUMP}, out;
    assert(p2_xr_publish_input(window,&in));
    assert(p2_xr_read_controls(&out) == window && out.blue_trigger == 1);
    P2XRFrame fake = frame(), read;
    assert(!p2_xr_publish_frame(window,&fake)); // window mode invents no head pose
    assert(!p2_xr_read_latest(&read,NULL) && !read.tracked);
    uint64_t immersive = p2_xr_begin_session();
    assert(!p2_xr_read_controls(&out) && !out.connected);
    assert(!p2_xr_publish_input(window,&in));
    assert(p2_xr_publish_input(immersive,&in));
    assert(!p2_xr_read_controls(&out) && !out.blue_trigger);
    assert(p2_xr_publish_frame(immersive,&fake));
    p2_xr_read_controls(&out); assert(!out.connected);
    p2_xr_end_session(immersive);
}
// Compositor-style rightUpBack projection from tangent extents, Metal reverse
// depth (near 1, far 0); far = INFINITY gives an infinite far plane.
static matrix_float4x4 frustum(float l, float r, float b, float t, float n, float f) {
    matrix_float4x4 m = {0};
    m.columns[0].x = 2 / (r - l); m.columns[1].y = 2 / (t - b);
    m.columns[2] = (vector_float4){(r + l) / (r - l), (t + b) / (t - b), isinf(f) ? 0 : n / (f - n), -1};
    m.columns[3].z = isinf(f) ? n : f * n / (f - n);
    return m;
}
static vector_float2 ndc(matrix_float4x4 p, vector_float3 direction) {
    vector_float4 clip = simd_mul(p, (vector_float4){direction.x, direction.y, direction.z, 1});
    return clip.xy / clip.w;
}
static void symmetric_cover(void) {
    // CViewSetup fov is horizontal over the full width, widened from 4:3 by
    // the engine: the logged 93.695 (aspect 1.422, 1024x720) and the first
    // frame's 73.740 (aspect 1.000) both equal ScaleFOVByWidthRatio(90).
    near(2 * atanf(1.0f * (1024.0f / 720) / (4.0f / 3)) * 180 / (float)M_PI, 93.695f);
    near(2 * atanf(1.0f * 1.0f / (4.0f / 3)) * 180 / (float)M_PI, 73.740f);
    const float tangents[2][4] = {{-1.25f, 0.95f, -1.15f, 0.9f}, {-0.95f, 1.25f, -1.15f, 0.9f}};
    const float aspects[] = {1280.0f / 720, 1024.0f / 720, 1, 0.8f};
    for (unsigned depth = 0; depth < 2; ++depth)
    for (unsigned eye = 0; eye < 2; ++eye)
    for (unsigned a = 0; a < sizeof(aspects) / sizeof(aspects[0]); ++a) {
        const float *e = tangents[eye], aspect = aspects[a];
        matrix_float4x4 current = frustum(e[0], e[1], e[2], e[3], 0.1f, depth ? INFINITY : 100), cover;
        float fov;
        assert(p2_xr_cover_projection(current, aspect, &cover, &fov));
        // Symmetric, at the render aspect, same depth/w rows.
        assert(cover.columns[2].x == 0 && cover.columns[2].y == 0);
        near(cover.columns[1].y / cover.columns[0].x, aspect);
        assert(cover.columns[2].z == current.columns[2].z && cover.columns[2].w == -1 &&
               cover.columns[3].z == current.columns[3].z);
        // What Source builds from (fov, aspect): x = 1/tan(fov/2), y = aspect*x.
        float x = 1 / tanf(fov * (float)M_PI / 360);
        assert(fabsf(x - cover.columns[0].x) < 1e-4f && fabsf(aspect * x - cover.columns[1].y) < 1e-4f);
        // Every edge of the asymmetric eye is inside the cover; one side is tight.
        float widest = 0;
        for (unsigned corner = 0; corner < 4; ++corner) {
            vector_float2 p = ndc(cover, (vector_float3){e[corner & 1], e[2 + (corner >> 1)], -1});
            assert(fabsf(p.x) <= 1 + 1e-5f && fabsf(p.y) <= 1 + 1e-5f);
            widest = fmaxf(widest, fmaxf(fabsf(p.x), fabsf(p.y)));
        }
        near(widest, 1);
        // Shader crop: sourceClip = cover * inverse(current) * (ndc, 0, 1).
        matrix_float4x4 crop = simd_mul(cover, simd_inverse(current));
        for (int i = 0; i <= 8; ++i)
            for (int j = 0; j <= 8; ++j) {
                vector_float4 clip = simd_mul(crop, (vector_float4){i / 4.0f - 1, j / 4.0f - 1, 0, 1});
                vector_float2 uv = clip.xy / clip.w * 0.5f + 0.5f;
                assert(clip.w > 0 && uv.x >= -1e-5f && uv.x <= 1 + 1e-5f && uv.y >= -1e-5f && uv.y <= 1 + 1e-5f);
            }
        // Round trip: a ray lands on the same source pixel either way.
        for (int i = 0; i < 25; ++i) {
            vector_float3 ray = {e[0] + (e[1] - e[0]) * (i % 5) / 4, e[2] + (e[3] - e[2]) * (i / 5) / 4.0f, -1};
            vector_float2 on_current = ndc(current, ray), expected = ndc(cover, ray);
            vector_float4 clip = simd_mul(crop, (vector_float4){on_current.x, on_current.y, 0, 1});
            assert(simd_distance(clip.xy / clip.w, expected) < 1e-4f);
        }
    }
    matrix_float4x4 current = frustum(-1, 1, -1, 1, 0.1f, 100), cover = matrix_identity_float4x4, bad = current;
    assert(!p2_xr_cover_projection(matrix_identity_float4x4, 1, &cover, NULL)); // not a perspective
    bad.columns[1].x = 0.1f; assert(!p2_xr_cover_projection(bad, 1, &cover, NULL)); // skewed
    bad = current; bad.columns[0].x = -1; assert(!p2_xr_cover_projection(bad, 1, &cover, NULL));
    bad = current; bad.columns[2].x = NAN; assert(!p2_xr_cover_projection(bad, 1, &cover, NULL));
    assert(!p2_xr_cover_projection(current, 0, &cover, NULL));
    assert(!p2_xr_cover_projection(frustum(-200, 200, -1, 1, 0.1f, 100), 1, &cover, NULL)); // ~180 degrees
    assert(!memcmp(&cover, &matrix_identity_float4x4, sizeof(cover)));
}
// Apple head pose: yaw about +Y (+ is left), pitch about +X (+ is up).
static P2XRFrame head(float yaw, float pitch, vector_float3 position) {
    P2XRFrame f = frame();
    float y = yaw * (float)M_PI / 180, p = pitch * (float)M_PI / 180;
    matrix_float4x4 turn = {{{cosf(y),0,-sinf(y),0},{0,1,0,0},{sinf(y),0,cosf(y),0},{0,0,0,1}}};
    matrix_float4x4 tilt = {{{1,0,0,0},{0,cosf(p),sinf(p),0},{0,-sinf(p),cosf(p),0},{0,0,0,1}}};
    f.tracking_from_head = simd_mul(turn, tilt);
    f.tracking_from_head.columns[3] = (vector_float4){position.x, position.y, position.z, 1};
    return f;
}
static vector_float3 head_origin(const P2XRBody *body, const P2XRFrame *f) {
    return simd_mul(body->source_from_tracking, f->tracking_from_head.columns[3]).xyz;
}
static void same_matrix(matrix_float4x4 a, matrix_float4x4 b) {
    for (int c = 0; c < 4; ++c) assert(simd_distance(a.columns[c], b.columns[c]) < 1e-3f);
}
static void head_aim_body(void) {
    vector_float3 seat = {0, 1.2f, 0}, origin = {100, 200, 64};
    P2XRFrame f = head(0, 0, seat);
    P2XRBody body = {0};
    vector_float3 aim;
    assert(!p2_xr_body_aim(&body, &f, &aim) && !p2_xr_body_turn(&body, 10)); // not aligned
    assert(p2_xr_body_align(&body, &f, origin, 30, P2_XR_UNITS_PER_METER));
    assert(p2_xr_body_aim(&body, &f, &aim));
    near(aim.x, 0); near(aim.y, 30); near(aim.z, 0);
    // Head yaw/pitch drive the aim but never turn the body.
    matrix_float4x4 still = body.source_from_tracking;
    f = head(40, 30, seat);
    assert(p2_xr_body_aim(&body, &f, &aim));
    near(aim.x, -30); near(aim.y, 70); near(aim.z, 0);
    near(p2_xr_body_observe(&body, 70), 0);
    assert(p2_xr_body_follow(&body, origin));
    assert(!memcmp(&still, &body.source_from_tracking, sizeof(still)));
    // An engine yaw change we did not write re-bases the body exactly once.
    near(p2_xr_body_observe(&body, 95), 25);
    near(p2_xr_body_observe(&body, 95), 0);
    assert(p2_xr_body_aim(&body, &f, &aim)); near(aim.y, 95);
    // The engine stores [-180,180]: wrapping is not a turn.
    assert(p2_xr_body_turn(&body, 100)); assert(p2_xr_body_aim(&body, &f, &aim));
    near(remainderf(aim.y - 195, 360), 0);
    near(p2_xr_body_observe(&body, aim.y + 360), 0);
    // Snap turn pivots on the engine eye origin: a head at the seat stays put.
    f = head(0, 0, seat);
    assert(p2_xr_body_align(&body, &f, origin, 0, P2_XR_UNITS_PER_METER));
    assert(p2_xr_body_turn(&body, -45));
    assert(simd_distance(head_origin(&body, &f), origin) < 1e-3f);
    assert(p2_xr_body_aim(&body, &f, &aim)); near(aim.y, -45);
    // Pitch is clamped to the engine limit; straight up has no yaw to keep.
    f = head(0, 89.5f, seat); assert(p2_xr_body_aim(&body, &f, &aim)); near(aim.x, -P2_XR_PITCH_LIMIT);
    f = head(0, -89.5f, seat); assert(p2_xr_body_aim(&body, &f, &aim)); near(aim.x, P2_XR_PITCH_LIMIT);
    f = head(0, 90, seat); float before = body.engine_yaw;
    assert(!p2_xr_body_aim(&body, &f, &aim)); near(body.engine_yaw, before);
    assert(!p2_xr_body_follow(&body, (vector_float3){NAN, 0, 0}));
    near(p2_xr_body_observe(&body, NAN), 0);
}
static void portal_crossing(void) {
    // Leaning 0.1 m right of the seat, then crossing a portal that moves the
    // eye origin and adds 90 degrees of engine yaw within one frame.
    vector_float3 seat = {0, 1.2f, 0}, origin = {100, 200, 64}, exit = {500, -300, 128};
    P2XRFrame f = head(0, 0, seat);
    P2XRBody a = {0};
    assert(p2_xr_body_align(&a, &f, origin, 0, P2_XR_UNITS_PER_METER));
    f = head(0, 0, (vector_float3){0.1f, 1.2f, 0});
    vector_float3 aim, offset = head_origin(&a, &f) - origin;
    near(offset.y, -0.1f * P2_XR_UNITS_PER_METER);
    assert(p2_xr_body_aim(&a, &f, &aim));
    P2XRBody b = a;
    // Render order (observe, then follow) and poll order (follow at render,
    // observe next poll) give the same body.
    near(p2_xr_body_observe(&a, 90), 90); assert(p2_xr_body_follow(&a, exit));
    assert(p2_xr_body_follow(&b, exit)); near(p2_xr_body_observe(&b, 90), 90);
    same_matrix(a.source_from_tracking, b.source_from_tracking);
    // The lean is carried through the portal rotated with the yaw.
    vector_float3 moved = head_origin(&a, &f) - exit;
    near(moved.x, -offset.y); near(moved.y, offset.x); near(moved.z, offset.z);
    assert(p2_xr_body_aim(&a, &f, &aim)); near(aim.y, 90);
    // Seeing the same angles/origin again applies nothing twice.
    matrix_float4x4 once = a.source_from_tracking;
    near(p2_xr_body_observe(&a, 90), 0); assert(p2_xr_body_follow(&a, exit));
    assert(!memcmp(&once, &a.source_from_tracking, sizeof(once)));
    // Walking afterwards only translates.
    assert(p2_xr_body_follow(&a, exit + (vector_float3){10, 0, 0}));
    near((head_origin(&a, &f) - exit).x, moved.x + 10);
}
// Right Sense controller pose (Apple tracking): yaw about +Y (+ is left),
// then roll about its forward axis (- is clockwise, right side down).
static P2XRFrame controller(P2XRFrame f, vector_float3 position, float yaw, float roll) {
    float y = yaw * (float)M_PI / 180, r = roll * (float)M_PI / 180;
    matrix_float4x4 turn = {{{cosf(y),0,-sinf(y),0},{0,1,0,0},{sinf(y),0,cosf(y),0},{0,0,0,1}}};
    matrix_float4x4 twist = {{{cosf(r),sinf(r),0,0},{-sinf(r),cosf(r),0,0},{0,0,1,0},{0,0,0,1}}};
    f.controllers[1].tracked = 1;
    f.controllers[1].tracking_from_aim = simd_mul(turn, twist);
    f.controllers[1].tracking_from_aim.columns[3] = (vector_float4){position.x, position.y, position.z, 1};
    f.controllers[1].tracking_from_grip = f.controllers[1].tracking_from_aim;
    return f;
}
static void near3(vector_float3 a, vector_float3 b) { assert(simd_distance(a, b) < 0.01f); }
static void controller_aim(void) {
    const float m = P2_XR_UNITS_PER_METER;
    vector_float3 seat = {0, 1.2f, 0}, eye = {100, 200, 64};
    // Controller 0.2 m ahead, 0.3 m right and 0.3 m below the head, aiming
    // 30 degrees left of where the head looks.
    P2XRFrame f = controller(head(0, 0, seat), (vector_float3){0.3f, 0.9f, -0.2f}, 30, 0);
    P2XRBody body = {0};
    P2XRAimBasis basis, untouched = {0};
    vector_float3 angles, offset, direction, start, ray;
    assert(!p2_xr_aim_basis(&basis, 7, 1, 10, &body, (vector_float3){0, 0, 0})); // not aligned
    assert(p2_xr_body_align(&body, &f, eye, 0, m) && p2_xr_body_aim(&body, &f, &angles));
    assert(!p2_xr_aim_basis(&basis, 0, 1, 10, &body, angles));
    assert(!p2_xr_aim_basis(&basis, 7, 1, NAN, &body, angles));
    assert(!p2_xr_aim_basis(&basis, 7, 1, 10, &body, (vector_float3){NAN, 0, 0}));
    assert(p2_xr_aim_basis(&basis, 7, 1, 10, &body, angles));
    near3(basis.head, (vector_float3){1, 0, 0}); near3(basis.eye, eye);
    // Freshness: same tracked session, recent pose and time, controller tracked.
    assert(p2_xr_aim_fresh(&basis, 7, &f, 10.1));
    assert(!p2_xr_aim_fresh(&basis, 8, &f, 10.1));                 // another session
    assert(!p2_xr_aim_fresh(&basis, 7, &f, 10 + P2_XR_AIM_MAX_AGE + 0.01)); // head aim stopped
    assert(!p2_xr_aim_fresh(&basis, 7, &f, 9.9) && !p2_xr_aim_fresh(&basis, 7, &f, NAN));
    assert(!p2_xr_aim_fresh(&untouched, 0, &f, 10) && !p2_xr_aim_fresh(&basis, 7, NULL, 10));
    P2XRFrame later = f;
    later.sequence = 1 + P2_XR_AIM_MAX_FRAMES; assert(p2_xr_aim_fresh(&basis, 7, &later, 10.1));
    later.sequence = 2 + P2_XR_AIM_MAX_FRAMES; assert(!p2_xr_aim_fresh(&basis, 7, &later, 10.1));
    later = f; basis.sequence = 2; assert(!p2_xr_aim_fresh(&basis, 7, &later, 10.1)); // pose older than the basis
    basis.sequence = 1;
    later.controllers[1].tracked = 0; assert(!p2_xr_aim_fresh(&basis, 7, &later, 10.1));
    later = f; later.tracked = 0; assert(!p2_xr_aim_fresh(&basis, 7, &later, 10.1));
    // The controller ray in Source units/axes, relative to the engine eye.
    assert(p2_xr_aim_controller(&basis, &f, &offset, &direction));
    near3(offset, (vector_float3){0.2f * m, -0.3f * m, -0.3f * m});
    near3(direction, (vector_float3){cosf((float)M_PI / 6), sinf((float)M_PI / 6), 0});
    assert(!p2_xr_aim_controller(&basis, &later, &offset, &direction));
    // A shot along the head aim becomes the controller ray from the hand.
    assert(p2_xr_aim_ray(&basis, &f, eye, basis.head, &start, &ray));
    near3(start, eye + (vector_float3){0.2f * m, -0.3f * m, -0.3f * m}); near3(ray, direction);
    // Small head motion between the engine's command and the basis is fine.
    float a = 10 * (float)M_PI / 180;
    assert(p2_xr_aim_ray(&basis, &f, eye, (vector_float3){cosf(a), sinf(a), 0}, &start, &ray));
    // A direction the head did not write (a portal the player stands in turned
    // it, a scripted shot) or a malformed one keeps the engine's ray.
    start = ray = (vector_float3){42, 42, 42};
    a = 15 * (float)M_PI / 180;
    assert(!p2_xr_aim_ray(&basis, &f, eye, (vector_float3){cosf(a), sinf(a), 0}, &start, &ray));
    assert(!p2_xr_aim_ray(&basis, &f, eye, (vector_float3){0, 1, 0}, &start, &ray));
    assert(!p2_xr_aim_ray(&basis, &f, eye, (vector_float3){2, 0, 0}, &start, &ray));
    assert(!p2_xr_aim_ray(&basis, &f, eye, (vector_float3){NAN, 0, 0}, &start, &ray));
    assert(!p2_xr_aim_ray(&basis, &later, eye, basis.head, &start, &ray)); // controller lost
    near3(start, (vector_float3){42, 42, 42}); near3(ray, (vector_float3){42, 42, 42});
    // An engine start translated away from the eye (portal straddle, minimum
    // range) is kept, with the controller direction.
    vector_float3 translated = eye + (vector_float3){0, 64, 0};
    assert(p2_xr_aim_ray(&basis, &f, translated, basis.head, &start, &ray));
    near3(start, translated); near3(ray, direction);
    // Trace starts stay inside the player's hull around the eye: a hand
    // reaching through a wall cannot start the trace behind it.
    assert(p2_xr_aim_start(eye, (vector_float3){30, 0, 0}, &start) == 1); near3(start, eye + (vector_float3){15, 0, 0});
    assert(p2_xr_aim_start(eye, (vector_float3){10, -20, -30}, &start) == 1); near3(start, eye + (vector_float3){10, -15, -26});
    assert(p2_xr_aim_start(eye, (vector_float3){0, 0, 10}, &start) == 1); near3(start, eye + (vector_float3){0, 0, 6});
    assert(p2_xr_aim_start(eye, (vector_float3){0, 0, -P2_XR_AIM_REACH - 1}, &start) == 2); near3(start, eye);
    assert(!p2_xr_aim_start(eye, (vector_float3){NAN, 0, 0}, &start));
    // Beyond reach (tracking and body disagree): engine start, controller direction.
    P2XRFrame far = controller(head(0, 0, seat), (vector_float3){0, 1.2f, -1.5f}, 30, 0);
    assert(p2_xr_aim_ray(&basis, &far, eye, basis.head, &start, &ray)); near3(start, eye); near3(ray, direction);
    // A turned body (snap turn or portal re-base) turns the ray with it.
    P2XRBody turned = {0};
    assert(p2_xr_body_align(&turned, &f, eye, 90, m) && p2_xr_body_aim(&turned, &f, &angles));
    near(angles.y, 90);
    assert(p2_xr_aim_basis(&basis, 7, 1, 10, &turned, angles));
    assert(p2_xr_aim_ray(&basis, &f, eye, (vector_float3){0, 1, 0}, &start, &ray));
    near3(ray, (vector_float3){-sinf((float)M_PI / 6), cosf((float)M_PI / 6), 0});
    near3(start, eye + (vector_float3){0.3f * m, 0.2f * m, -0.3f * m});
    // Viewmodel: at the grip plus the offset in the controller frame, with the
    // controller's angles, carried to the current engine eye.
    assert(p2_xr_aim_basis(&basis, 7, 1, 10, &body, (vector_float3){0, 0, 0}));
    P2XRSourceView gun;
    vector_float3 moved = eye + (vector_float3){10, 0, 0}, grip = {-5, 5, 9};
    vector_float3 forward = {cosf((float)M_PI / 6), sinf((float)M_PI / 6), 0}, left = {-sinf((float)M_PI / 6), cosf((float)M_PI / 6), 0};
    assert(p2_xr_aim_viewmodel(&basis, &f, moved, grip, &gun));
    near3(gun.origin, moved + (vector_float3){0.2f * m, -0.3f * m, -0.3f * m} + forward * -5 + left * 5 + (vector_float3){0, 0, 9});
    near(gun.angles.x, 0); near(gun.angles.y, 30); near(gun.angles.z, 0);
    P2XRFrame rolled = controller(head(0, 0, seat), (vector_float3){0.3f, 0.9f, -0.2f}, 30, -20);
    assert(p2_xr_aim_viewmodel(&basis, &rolled, moved, (vector_float3){0, 0, 0}, &gun));
    near(gun.angles.y, 30); near(gun.angles.z, 20); // right side down: positive Source roll
    assert(!p2_xr_aim_viewmodel(&basis, &later, moved, grip, &gun));
    assert(!p2_xr_aim_viewmodel(&basis, &f, (vector_float3){NAN, 0, 0}, grip, &gun));
}
static void turning_and_settings(void) {
    P2XRSnapTurn s = {0};
    near(p2_xr_snap_turn(&s, 0.5f, 45), 0);
    near(p2_xr_snap_turn(&s, 0.7f, 45), 0);    // engage needs more than 0.7
    near(p2_xr_snap_turn(&s, 0.71f, 45), -45); // right turns right (negative yaw)
    near(p2_xr_snap_turn(&s, 1, 45), 0);       // held: one turn per push
    near(p2_xr_snap_turn(&s, 0.5f, 45), 0);
    near(p2_xr_snap_turn(&s, 0.75f, 45), 0);   // not re-armed above 0.3
    near(p2_xr_snap_turn(&s, 0.29f, 45), 0);
    near(p2_xr_snap_turn(&s, -0.8f, 30), 30);
    near(p2_xr_snap_turn(&s, 0.8f, 30), 0);    // no centre sample: still latched
    near(p2_xr_snap_turn(&s, NAN, 30), 0); assert(!s.latched);
    near(p2_xr_snap_turn(&s, -0.9f, 30), 30);
    near(p2_xr_snap_turn(NULL, 1, 30), 0);
    near(p2_xr_smooth_turn(1, 90, 0.05f), -4.5f);
    near(p2_xr_smooth_turn(-1, 90, 5), 9);     // a stall is capped at 0.1 s
    near(p2_xr_smooth_turn(0.15f, 90, 0.05f), 0);
    near(p2_xr_smooth_turn(NAN, 90, 0.05f), 0);
    near(p2_xr_smooth_turn(1, 90, -1), 0);
    float v;
    assert(p2_xr_setting(NULL, P2_XR_UNITS_PER_METER, 10, 100, &v) == 0); near(v, P2_XR_UNITS_PER_METER);
    assert(p2_xr_setting("", 45, 5, 180, &v) == 0); near(v, 45);
    assert(p2_xr_setting("43.2", P2_XR_UNITS_PER_METER, 10, 100, &v) == 1); near(v, 43.2f);
    const char *bad[] = {"abc", "43.2x", "1e9", "nan", "inf", "-40", "9.99"};
    for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i) {
        assert(p2_xr_setting(bad[i], P2_XR_UNITS_PER_METER, 10, 100, &v) == -1);
        near(v, P2_XR_UNITS_PER_METER);
    }
    // The scale setting reaches the eye separation and head translation.
    P2XRFrame f = frame();
    P2XRBody body = {0};
    P2XRSourceView left, right;
    assert(p2_xr_body_align(&body, &f, (vector_float3){0, 0, 64}, 0, 43.2f));
    assert(p2_xr_source_view(&f, 0, body.source_from_tracking, &left));
    assert(p2_xr_source_view(&f, 1, body.source_from_tracking, &right));
    near(simd_distance(left.origin, right.origin), 0.064f * 43.2f);
    assert(!p2_xr_body_align(&body, &f, (vector_float3){0, 0, 64}, 0, 0));
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
    views_and_portals(); session_and_input(); spatial_controller_tracking(); window_controls(); concurrent_publication();
    symmetric_cover(); head_aim_body(); portal_crossing(); turning_and_settings(); controller_aim();
    puts("XR contract passed: stereo, scale, recenter, full portal rotation, tracking loss, input release, session isolation, concurrent publication, "
         "symmetric eye cover/crop, head aim body re-base, yaw-only portal crossing, snap/smooth turn, settings, "
         "controller portal aim (freshness, hull clamp, head-direction guard, viewmodel pose)");
    return 0;
}
