#pragma once
// Tracked PSVR2 Sense portal-gun aim (runtime/visionos/aim_vision.c).
// Engine side only.
#include "rt.h"
#include "p2_xr.h"

// Guest game thread, each time the head drives the engine view angles
// (seated head aim): the body and the angles just written. Any failure, and
// p2_vision_aim_clear, stop controller aim until the next publication.
void p2_vision_aim_publish(uint64_t session, uint64_t sequence, const P2XRBody *camera,
                           const P2XRBody *body, vector_float3 head_angles);
void p2_vision_aim_clear(void);
// Map the selected Sense grip through the gameplay body. View-only pitch and
// height must not move a physics object as the user looks around.
int p2_vision_carry_grip(uint64_t session, const P2XRFrame *frame, const P2XRInput *input,
                       unsigned hand, vector_float3 stock_origin, vector_float3 *target,
                       matrix_float3x3 *orientation);
typedef enum {
    P2_VISION_RETICLE_HEAD,
    P2_VISION_RETICLE_HIDDEN,
    P2_VISION_RETICLE_TRACKED,
} P2VisionAimReticle;
// Reticle state for this stereo snapshot. Only TRACKED writes the collision
// point in ARKit tracking space. HEAD lets the stock HUD draw at its center.
P2VisionAimReticle p2_vision_aim_reticle(CPU *c, uint64_t session, const P2XRFrame *pose,
                                      const P2XRInput *controls, vector_float3 *tracking_hit);
// Guest game thread, with the verified RenderView hook: place the portal gun
// viewmodel at the controller while controller aim is active (audited
// client.so CalcViewModelView slot; refuses on any mismatch).
void p2_vision_viewmodel_install(CPU *c);
// runtime/native.c rt_native_trace_fire_portal{,_client} (tools/lift.py
// NATIVE_OVERRIDES): rewrites the ray TraceFirePortal is about to trace and
// returns 0 so the translated function runs. 0 without changes otherwise.
int p2_vision_trace_fire_portal(CPU *c, uint32_t entry, int client);
