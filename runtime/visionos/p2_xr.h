// Native XR boundary. No guest addresses, Windows hooks, or game data cross it.
#pragma once
#include <simd/simd.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define P2_XR_EYE_COUNT 2u
#define P2_XR_ABI_VERSION 4u
#define P2_XR_UNITS_PER_METER 39.37007874015748f

enum P2XRButtons {
    P2_XR_JUMP = 1u << 0, P2_XR_CROUCH = 1u << 1,
    P2_XR_USE = 1u << 2, P2_XR_PAUSE = 1u << 3,
    P2_XR_RECENTER = 1u << 4, P2_XR_WINDOW = 1u << 5
};

typedef struct {
    matrix_float4x4 head_from_eye;
    // CompositorServices rightUpBack projection, Metal [0,1] reverse depth.
    // A GL backend must explicitly convert its clip convention.
    matrix_float4x4 projection;
} P2XREye;

typedef struct {
    // Only complete position AND orientation tracking is accepted. The
    // orientation-only fallback is not a six-degree-of-freedom controller.
    uint32_t tracked;
    matrix_float4x4 tracking_from_aim;
    matrix_float4x4 tracking_from_grip;
} P2XRControllerPose;

typedef struct {
    uint64_t sequence;
    double presentation_time;
    uint32_t tracked;
    uint32_t eye_count;
    matrix_float4x4 tracking_from_head;
    P2XREye eyes[P2_XR_EYE_COUNT];
    P2XRControllerPose controllers[2]; // fixed hardware left, right
} P2XRFrame;

typedef struct {
    float move_x, move_y, turn_x, look_y;
    float blue_trigger, orange_trigger;
    uint32_t buttons;
    uint32_t connected;
    uint32_t spatial; // two Sense devices, rather than one standard gamepad
} P2XRInput;

typedef struct {
    vector_float3 origin;
    // Source QAngle: pitch, yaw, roll in degrees.
    vector_float3 angles;
    matrix_float4x4 projection;
} P2XRSourceView;

// Sessions prevent a retiring render thread from publishing into a new space.
uint32_t p2_xr_abi_version(void);
uint64_t p2_xr_begin_session(void);
uint64_t p2_xr_begin_window_session(void);
int p2_xr_session_active(uint64_t session);
void p2_xr_end_session(uint64_t session);
int p2_xr_publish_frame(uint64_t session, const P2XRFrame *frame);
int p2_xr_publish_input(uint64_t session, const P2XRInput *input);
int p2_xr_read(uint64_t session, P2XRFrame *frame, P2XRInput *input);
// Engine-side coherent snapshot, including the current session identity.
// Returns 0 when there is no valid tracked immersive frame.
uint64_t p2_xr_read_latest(P2XRFrame *frame, P2XRInput *input);
uint64_t p2_xr_read_controls(P2XRInput *input);
void p2_xr_release_input(uint64_t session);

// Apple tracking: +X right, +Y up, -Z forward, meters.
// Source: +X forward, +Y left, +Z up, game units. Recenter removes only yaw
// and translation; looking up/down and head roll remain physical.
int p2_xr_align(const P2XRFrame *frame, vector_float3 source_eye_center,
                float source_yaw_degrees, float units_per_meter,
                matrix_float4x4 *source_from_tracking);
int p2_xr_source_view(const P2XRFrame *frame, uint32_t eye,
                      matrix_float4x4 source_from_tracking,
                      P2XRSourceView *view);
int p2_xr_source_controller(const P2XRFrame *frame, uint32_t hand,
                           matrix_float4x4 source_from_tracking,
                           P2XRSourceView *aim);
// Pass the verified engine portal transform, including pitch/roll. Call once
// on a player crossing, never for recursive rendering through a portal.
int p2_xr_cross_portal(matrix_float4x4 exit_from_entry,
                       matrix_float4x4 *source_from_tracking);

#ifdef __cplusplus
}
#endif
