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
// Immersive input needs a tracked head frame. A Sense pair's controls keep
// working while its right controller is untracked; actions held when that
// tracking is lost are released until let go (see p2_xr.c).
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

// Symmetric perspective covering one eye's compositor tangent extents at the
// engine render aspect (width/height). Keeps the compositor's rightUpBack,
// Metal reverse-Z depth row, so sourceProj * inverse(currentProj) crops it.
// fov_degrees: CViewSetup fov, horizontal across the full width (Source
// builds tan(vertical/2) = tan(fov/2) / aspect). 0 rejects skewed/odd input.
int p2_xr_cover_projection(matrix_float4x4 eye_projection, float aspect,
                           matrix_float4x4 *cover, float *fov_degrees);

// Seated head aim. The tracking space is the player's body: it turns only by
// snap/smooth turns and by engine yaw changes the head did not write (portal
// crossings, teleports, level changes, stick turning while tracking was
// lost). Head yaw itself never turns it. Not part of the Swift frame ABI.
#define P2_XR_PITCH_LIMIT 89.0f // Source cl_pitchup/cl_pitchdown defaults
#define P2_XR_SNAP_ENGAGE 0.7f
#define P2_XR_SNAP_RELEASE 0.3f
typedef struct {
    matrix_float4x4 source_from_tracking;
    vector_float3 origin; // engine eye origin at the last alignment/follow
    float engine_yaw;     // engine yaw as last written or observed, degrees
    uint32_t aligned;
} P2XRBody;
int p2_xr_body_align(P2XRBody *body, const P2XRFrame *frame, vector_float3 origin,
                     float engine_yaw, float units_per_meter);
// Yaw-only re-base: turns the body once by an engine yaw change since the
// last write/observation and returns it (degrees); 0 for none/invalid.
float p2_xr_body_observe(P2XRBody *body, float engine_yaw);
// Turn about the vertical axis through the engine eye origin (+ is left).
int p2_xr_body_turn(P2XRBody *body, float degrees);
// Carry the tracking space with the engine eye origin (translation only).
int p2_xr_body_follow(P2XRBody *body, vector_float3 origin);
// Engine angles aiming where the head looks: pitch clamped, roll 0. Records
// the yaw as the engine's expected yaw. 0 when the head looks straight up/down.
int p2_xr_body_aim(P2XRBody *body, const P2XRFrame *frame, vector_float3 *angles);

typedef struct { uint32_t latched; } P2XRSnapTurn;
// Right stick right (+turn_x) turns right, a negative Source yaw. One turn per
// push past P2_XR_SNAP_ENGAGE; re-armed below P2_XR_SNAP_RELEASE.
float p2_xr_snap_turn(P2XRSnapTurn *state, float turn_x, float step_degrees);
float p2_xr_smooth_turn(float turn_x, float degrees_per_second, float seconds);
// Numeric setting text (environment). *value is always usable: 0 unset,
// 1 parsed, -1 rejected (fallback kept).
int p2_xr_setting(const char *text, float fallback, float low, float high, float *value);

// ---- Tracked controller (Sense) portal aim ---------------------------------
// The portal gun fires along the right controller's aim ray instead of the
// head. The engine-side basis is the seated-head-aim body as last driven: a
// shot uses the newest controller pose through it, so firing never waits on a
// render. Not part of the Swift frame ABI.
#define P2_XR_AIM_HAND 1u                // fixed hardware right Sense controller
#define P2_XR_AIM_MAX_AGE 0.25           // seconds since the head last drove the engine
#define P2_XR_AIM_MAX_FRAMES 30u         // pose publications since then (~0.33 s at 90 Hz)
// Trace starts stay inside the standing/crouched player hull around the engine
// eye (32 units wide; the crouched eye is 28 above its bottom and 8 below its
// top). The hull is clear of world solids, so the start is reachable from the
// eye without crossing a wall: a hand through a wall cannot place portals
// behind it. Farther than P2_XR_AIM_REACH, tracking and body disagree: the
// engine's own start is kept, with the controller direction.
#define P2_XR_AIM_HALF_WIDTH 15.0f
#define P2_XR_AIM_BELOW 26.0f
#define P2_XR_AIM_ABOVE 6.0f
#define P2_XR_AIM_REACH 40.0f
// The engine's fire direction must be the head aim the body wrote (within
// this many degrees). Otherwise something else chose it (a portal the player
// stands in rotated it, a scripted direction, a view override): keep it.
#define P2_XR_AIM_HEAD_TOLERANCE 12.0f
typedef struct {
    uint64_t session;        // tracked session whose head drives the engine; 0 none
    uint64_t sequence;       // pose sequence the head aim was computed from
    double stamp;            // monotonic seconds when the head drove the engine
    matrix_float4x4 source_from_tracking;
    vector_float3 eye;       // engine eye origin source_from_tracking follows
    vector_float3 head;      // unit forward of the engine angles the head wrote
} P2XRAimBasis;
// head_angles: the Source pitch/yaw/roll written to the engine.
int p2_xr_aim_basis(P2XRAimBasis *basis, uint64_t session, uint64_t sequence, double stamp,
                    const P2XRBody *body, vector_float3 head_angles);
// The basis belongs to the latest tracked frame's session, is recent, and the
// right controller is position+orientation tracked in that frame.
int p2_xr_aim_fresh(const P2XRAimBasis *basis, uint64_t session, const P2XRFrame *latest, double now);
// Right controller aim ray: origin relative to the basis eye, unit direction.
int p2_xr_aim_controller(const P2XRAimBasis *basis, const P2XRFrame *latest,
                         vector_float3 *offset, vector_float3 *direction);
// Engine trace start moved by the controller offset, clamped into the hull
// box: 1 moved, 2 too far (engine start kept), 0 invalid input.
int p2_xr_aim_start(vector_float3 engine_start, vector_float3 offset, vector_float3 *start);
// The ray to trace instead of (engine_start, engine_direction); 0 keeps the
// engine's ray (outputs untouched).
int p2_xr_aim_ray(const P2XRAimBasis *basis, const P2XRFrame *latest,
                  vector_float3 engine_start, vector_float3 engine_direction,
                  vector_float3 *start, vector_float3 *direction);
// Viewmodel pose for the current engine eye: the grip position plus
// grip_offset (forward, left, up in the controller's aim frame, Source
// units), oriented like the aim ray including roll.
int p2_xr_aim_viewmodel(const P2XRAimBasis *basis, const P2XRFrame *latest, vector_float3 eye,
                        vector_float3 grip_offset, P2XRSourceView *pose);

#ifdef __cplusplus
}
#endif
