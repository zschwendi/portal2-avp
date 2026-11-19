#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include "reticle_trace.h"
#include "modules.h"
#include "../../build/visionos/xr-reticle-profile.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

#if P2_RETICLE_PROFILE
enum {
    RAY_SIZE = 0x50, RAY_DELTA = 0x10, RAY_FLAGS = 0x44,
    SEGMENT_SIZE = 0x68, SEGMENT_COUNT = 16, SEGMENT_NEXT_PORTAL = 0x4,
    SEGMENT_START = 0x14, SEGMENT_END = 0x20, SEGMENT_FRACTION = 0x40,
    SEGMENT_ALL_SOLID = 0x4a, SEGMENT_START_SOLID = 0x4b,
    FILTER_SIZE = 0x24, FILTER_PASS_ENTITY = 0x4,
    TRACE_RAY_SLOT = 5, SHOOT_POSITION_SLOT = 0x4e8 / 4,
};

// The client assigns a serial to each entry. The render-side viewmodel hook
// records these handles so a level transition cannot leave stale pointers.
static uint32_t weapon_handle = UINT32_MAX, owner_handle = UINT32_MAX;
static uint32_t client_base, ray, filter, segments, position;
static int validated = 0;

static int pointer(uint32_t address) { return address >= 0x10000 && address < RT_IMPORT_BASE - 0x10000; }
static int finite_vector(vector_float3 v) { return isfinite(v.x) && isfinite(v.y) && isfinite(v.z); }

static float read_float(uint32_t address) {
    float value;
    memcpy(&value, GPTR(address), sizeof(value));
    return value;
}

static vector_float3 read_vector(uint32_t address) {
    float value[3];
    memcpy(value, GPTR(address), sizeof(value));
    return (vector_float3){value[0], value[1], value[2]};
}

static void write_vector(uint32_t address, vector_float3 value) {
    float xyz[] = {value.x, value.y, value.z};
    memcpy(GPTR(address), xyz, sizeof(xyz));
}

static uint32_t entity(uint32_t handle) {
    if (handle == UINT32_MAX) return 0;
    uint32_t list = R32(client_base + P2_RETICLE_ENTITY_LIST);
    if (!pointer(list)) return 0;
    uint32_t entry = list + (handle & 0xffffu) * 16u;
    if (R32(entry + 8) != handle >> 16) return 0;
    uint32_t object = R32(entry + 4);
    return pointer(object) ? object : 0;
}

static int verify_profile(CPU *c) {
    if (validated) return validated > 0;
    const GuestModule *client = rt_find_module("client.so"), *engine = rt_find_module("engine.so");
    if (!client || !engine) return 0;
    uint32_t cb = client->base, eb = engine->base;
    uint32_t trace = R32(cb + P2_RETICLE_TRACE_GLOBAL);
    if (!pointer(trace)) return 0;
    uint32_t trace_vtable = eb + P2_RETICLE_ENGINE_TRACE_VTABLE;
    uint32_t shooter_vtable = cb + P2_RETICLE_PLAYER_VTABLE;
#define CHECK(base, offset, sig) \
    !memcmp(rt_span(c, (base) + (offset), sizeof(sig)), (sig), sizeof(sig))
    if (R32(trace) != trace_vtable ||
        R32(trace_vtable + TRACE_RAY_SLOT * 4) != eb + P2_RETICLE_TRACE_RAY ||
        R32(shooter_vtable + SHOOT_POSITION_SLOT * 4) != cb + P2_RETICLE_SHOOT_POSITION ||
        !CHECK(eb, P2_RETICLE_TRACE_RAY, p2_reticle_sig_trace_ray) ||
        !CHECK(cb, P2_RETICLE_QUERY, p2_reticle_sig_query) ||
        !CHECK(cb, P2_RETICLE_FILTER_CTOR, p2_reticle_sig_filter_ctor) ||
        !CHECK(cb, P2_RETICLE_FILTER_SETUP, p2_reticle_sig_filter_setup) ||
        !CHECK(cb, P2_RETICLE_SHOOT_POSITION, p2_reticle_sig_shoot_position)) {
        validated = -1;
        fprintf(stderr, "[vision-reticle] Guest collision profile mismatch\n");
        return 0;
    }
#undef CHECK
    client_base = cb;
    validated = 1;
    return 1;
}

static int prepare_scratch(CPU *c) {
    if (ray) return 1;
    uint32_t allocation = rt_alloc(15 + RAY_SIZE + SEGMENT_COUNT * SEGMENT_SIZE + FILTER_SIZE + 12);
    if (!allocation) return 0;
    ray = (allocation + 15) & ~15u;
    segments = ray + RAY_SIZE;
    filter = segments + SEGMENT_COUNT * SEGMENT_SIZE;
    position = filter + FILTER_SIZE;

    // Use the exact stock filter and its class exclusions. It allocates its
    // small ignore list once for the guest lifetime and traces only read it.
    const uint32_t args[] = {filter, 0, 0};
    CPU saved = *c;
    rt_invoke(c, client_base + P2_RETICLE_FILTER_CTOR, args, 3);
    rt_invoke(c, client_base + P2_RETICLE_FILTER_SETUP, args, 1);
    *c = saved;
    return 1;
}

static uint32_t weapon(void) {
    uint32_t value = entity(weapon_handle);
    return value && R32(value) == client_base + P2_RETICLE_WEAPON_VTABLE ? value : 0;
}

static uint32_t owner(void) {
    uint32_t value = entity(owner_handle);
    return value && R32(value) == client_base + P2_RETICLE_PLAYER_VTABLE ? value : 0;
}
#endif

int p2_vision_reticle_weapon(CPU *c, uint32_t viewmodel, uint32_t player) {
#if P2_RETICLE_PROFILE
    weapon_handle = owner_handle = UINT32_MAX;
    if (!c || !pointer(viewmodel) || !pointer(player) || !verify_profile(c)) return 0;
    weapon_handle = R32(viewmodel + P2_RETICLE_VIEWMODEL_WEAPON);
    owner_handle = R32(viewmodel + P2_RETICLE_VIEWMODEL_OWNER);
    if (owner() == player && weapon()) return 1;
    weapon_handle = owner_handle = UINT32_MAX;
#else
    (void)c; (void)viewmodel; (void)player;
#endif
    return 0;
}

int p2_vision_reticle_origin(CPU *c, vector_float3 *stock) {
#if P2_RETICLE_PROFILE
    if (!c || !stock || validated <= 0 || !weapon()) return 0;
    uint32_t player = owner();
    if (!player || entity(R32(player + P2_RETICLE_PORTAL_ENVIRONMENT)) || !prepare_scratch(c)) return 0;

    // On i386 this Vector return uses a hidden result pointer and ret $4.
    // Invoke that ABI explicitly and restore the caller's guest registers.
    CPU saved = *c;
    uint32_t args = (c->esp - 8) & ~15u;
    c->esp = args;
    W32(args, position);
    W32(args + 4, player);
    rt_call(c, client_base + P2_RETICLE_SHOOT_POSITION, RT_RETURN_SENTINEL);
    int returned = c->esp == args + 4 && c->eax == position;
    *c = saved;
    vector_float3 result = read_vector(position);
    if (!returned || !finite_vector(result)) return 0;
    *stock = result;
    return 1;
#else
    (void)c; (void)stock;
    return 0;
#endif
}

int p2_vision_trace_reticle(CPU *c, vector_float3 start, vector_float3 direction, vector_float3 *hit) {
#if P2_RETICLE_PROFILE
    if (!c || !hit || validated <= 0 || !finite_vector(start) || !finite_vector(direction)) return 0;
    uint32_t gun = weapon();
    float length = simd_length(direction);
    if (!gun || !(length > 0.98f && length < 1.02f) || !prepare_scratch(c)) return 0;
    float range = read_float(gun + P2_RETICLE_WEAPON_RANGE);
    if (!(range >= 1 && range <= 56756)) return 0;

    direction /= length;
    memset(GPTR(ray), 0, RAY_SIZE + SEGMENT_COUNT * SEGMENT_SIZE);
    write_vector(ray, start);
    write_vector(ray + RAY_DELTA, direction * range);
    W32(ray + RAY_FLAGS, 0x0101u); // is ray, is swept
    W32(filter + FILTER_PASS_ENTITY, gun);
    const uint32_t args[] = {ray, P2_RETICLE_MASK, filter, segments, SEGMENT_COUNT};
    CPU saved = *c;
    unsigned count = rt_invoke(c, client_base + P2_RETICLE_QUERY, args, 5);
    *c = saved;
    if (!count || count > SEGMENT_COUNT) return 0;

    uint32_t last = segments + (count - 1) * SEGMENT_SIZE;
    float fraction = read_float(last + SEGMENT_FRACTION);
    if (!(fraction >= 0 && fraction < 1) || R8(last + SEGMENT_ALL_SOLID) ||
        R8(last + SEGMENT_START_SOLID) || R32(last + SEGMENT_NEXT_PORTAL)) return 0;

    vector_float3 result = read_vector(last + SEGMENT_END);
    if (count > 1) {
        // Linked portals preserve distance. Unfold the traced segments back
        // along the original ray to display the target at its apparent depth.
        float distance = 0;
        for (unsigned i = 0; i < count; ++i) {
            uint32_t segment = segments + i * SEGMENT_SIZE;
            distance += simd_distance(read_vector(segment + SEGMENT_START), read_vector(segment + SEGMENT_END));
        }
        if (!(distance > 0 && distance <= range)) return 0;
        result = start + direction * distance;
    }
    if (!finite_vector(result) || simd_distance(start, result) < 0.5f) return 0;
    *hit = result;
    return 1;
#else
    (void)c; (void)start; (void)direction; (void)hit;
    return 0;
#endif
}
#endif
