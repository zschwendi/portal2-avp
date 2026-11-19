#pragma once

#include "p2_xr.h"
#include "rt.h"

// All calls belong on the guest game thread. The viewmodel hook supplies the
// live Portal gun; the render hook uses the same ordinary start as firing.
int p2_vision_reticle_weapon(CPU *c, uint32_t viewmodel, uint32_t owner);
int p2_vision_reticle_origin(CPU *c, vector_float3 *stock);
int p2_vision_trace_reticle(CPU *c, vector_float3 start, vector_float3 direction, vector_float3 *hit);
uint32_t p2_vision_reticle_surface(CPU *c);
