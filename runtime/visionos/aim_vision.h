#pragma once
// Tracked PSVR2 Sense portal-gun aim (runtime/visionos/aim_vision.c).
// Engine side only; Swift reads p2_vision_controller_aim_active (view_vision.h).
#include "rt.h"
#include "p2_xr.h"

// Guest game thread, each time the head drives the engine view angles
// (seated head aim): the body and the angles just written. Any failure, and
// p2_vision_aim_clear, stop controller aim until the next publication.
void p2_vision_aim_publish(uint64_t session, uint64_t sequence, const P2XRBody *body, vector_float3 head_angles);
void p2_vision_aim_clear(void);
// Guest game thread, with the verified RenderView hook: place the portal gun
// viewmodel at the controller while controller aim is active (audited
// client.so CalcViewModelView slot; refuses on any mismatch).
void p2_vision_viewmodel_install(CPU *c);
// runtime/native.c rt_native_trace_fire_portal{,_client} (tools/lift.py
// NATIVE_OVERRIDES): rewrites the ray TraceFirePortal is about to trace and
// returns 0 so the translated function runs. 0 without changes otherwise.
int p2_vision_trace_fire_portal(CPU *c, uint32_t entry, int client);
