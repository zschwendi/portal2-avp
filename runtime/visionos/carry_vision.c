#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include "aim_vision.h"
#include "input_vision.h"
#include "modules.h"
#include "xr-carry-profile.h"
#include "../../build/visionos/xr-reticle-profile.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if P2_XR_CARRY_PROFILE && P2_RETICLE_PROFILE
// All offsets here are for the Linux i386 modules pinned by visionos_carry.py.
// The inserted calls run on the guest thread while it owns the guest state.
enum {
    SERVER_PICKUP_VTABLE = 0xd21c58, SERVER_GRAB_VTABLE = 0xd21c20,
    SERVER_PLAYER_VTABLE = 0xde3b10, SERVER_ENTITY_LIST = 0x11b0d9c, SERVER_GLOBALS = 0x129801c,
    PICKUP_GRAB = 0x374, PICKUP_OWNER = 0x2430, SERVER_HELD_HANDLE = 0x2054,
    CLIENT_GRAB_VTABLE = 0x1208384, CLIENT_HELD_HANDLE = 0x54, CLIENT_GLOBALS = 0x18ab550,
    SERVER_PORTAL_HANDLE = 0x164c, SERVER_PORTAL_HELD = 0x1648,
    CLIENT_PORTAL_HANDLE = 0x1f34, CLIENT_PORTAL_HELD = 0x1f30,
    RAY_DELTA = 0x10, RAY_IS_RAY = 0x44, RAY_IS_SWEPT = 0x45,
};

typedef struct {
    uint32_t site, base, signature_rva;
    const unsigned char *signature;
    size_t signature_size;
    unsigned client, vm;
    int validated;
} CarrySite;

#define CARRY_SITE(name, symbol, module, is_client, viewmodel) \
    { P2_XR_CARRY_##symbol##_SITE, P2_XR_CARRY_##module##_BASE, P2_XR_CARRY_##symbol##_SIG_RVA, \
      p2_xr_carry_sig_##name, sizeof(p2_xr_carry_sig_##name), is_client, viewmodel, 0 }

static CarrySite sites[] = {
    CARRY_SITE(server_target, SERVER_TARGET, SERVER, 0, 0),
    CARRY_SITE(client_target, CLIENT_TARGET, CLIENT, 1, 0),
    CARRY_SITE(server_vm_target, SERVER_VM_TARGET, SERVER, 0, 1),
    CARRY_SITE(client_vm_target, CLIENT_VM_TARGET, CLIENT, 1, 1),
    CARRY_SITE(server_attach, SERVER_ATTACH, SERVER, 0, 0),
    CARRY_SITE(server_detach, SERVER_DETACH, SERVER, 0, 0),
#if defined(P2_XR_CARRY_SERVER_ANGLES_SITE)
    CARRY_SITE(server_angles, SERVER_ANGLES, SERVER, 0, 0),
    CARRY_SITE(client_angles, CLIENT_ANGLES, CLIENT, 1, 0),
    CARRY_SITE(server_vm_angles, SERVER_VM_ANGLES, SERVER, 0, 1),
    CARRY_SITE(client_vm_angles, CLIENT_VM_ANGLES, CLIENT, 1, 1),
#endif
};
#undef CARRY_SITE

static struct {
    uint32_t grab, player, handle, client_grab, client_handle;
    uint64_t session;
    unsigned hand;
    double attached_at;
    unsigned logged;
    struct {
        uint32_t grab;
        unsigned vm, linked;
        matrix_float3x3 grip, object_from_grip;
    } rotations[2];
} carried;

static int pointer(uint32_t value) {
    return value >= 0x10000 && value < RT_IMPORT_BASE - 0x200000;
}

static CarrySite *verified_site(CPU *c, uint32_t address) {
    for (unsigned i = 0; i < sizeof(sites) / sizeof(sites[0]); ++i) {
        CarrySite *site = &sites[i];
        if (site->site != address) continue;
        if (!site->validated) {
            const GuestModule *module = rt_find_module(site->client ? "client.so" : "server.so");
            if (!module) return NULL;
            site->validated = module->base == site->base &&
                !memcmp(rt_span(c, site->base + site->signature_rva, site->signature_size),
                        site->signature, site->signature_size) ? 1 : -1;
        }
        return site->validated > 0 ? site : NULL;
    }
    return NULL;
}

static uint32_t entity_entry(unsigned client, uint32_t index) {
    uint32_t list = R32(client ? P2_XR_CARRY_CLIENT_BASE + P2_RETICLE_ENTITY_LIST :
                                 P2_XR_CARRY_SERVER_BASE + SERVER_ENTITY_LIST);
    return pointer(list) ? list + index * (client ? 16 : 24) : 0;
}

static uint32_t entity(unsigned client, uint32_t handle) {
    if (handle == UINT32_MAX) return 0;
    uint32_t entry = entity_entry(client, handle & 0xffffu);
    return entry && R32(entry + 8) == handle >> 16 ? R32(entry + 4) : 0;
}

static int local_player(unsigned client, uint32_t player) {
    // This hook supports the local campaign. Slot 1 is its one human player.
    uint32_t globals = R32(client ? P2_XR_CARRY_CLIENT_BASE + CLIENT_GLOBALS :
                                    P2_XR_CARRY_SERVER_BASE + SERVER_GLOBALS);
    if (!pointer(globals) || R32(globals + 0x14) != 1) return 0;
    uint32_t entry = entity_entry(client, 1);
    uint32_t table = client ? P2_XR_CARRY_CLIENT_BASE + P2_RETICLE_PLAYER_VTABLE :
                              P2_XR_CARRY_SERVER_BASE + SERVER_PLAYER_VTABLE;
    return pointer(player) && entry && R32(entry + 4) == player && R32(player) == table;
}

static vector_float3 load_vector(uint32_t from) {
    return (vector_float3){RF(from), RF(from + 4), RF(from + 8)};
}

static void store_vector(uint32_t to, vector_float3 value) {
    WF(to, value.x);
    WF(to + 4, value.y);
    WF(to + 8, value.z);
}

static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec * 1e-9;
}

static int audit_enabled(void) {
#if TARGET_OS_SIMULATOR
    static int enabled = -1;
    if (enabled < 0) {
        const char *value = getenv("P2_VISION_CARRY_AUDIT");
        enabled = value && !strcmp(value, "1");
    }
    return enabled;
#else
    return 0;
#endif
}

static void audit_rejected(const CarrySite *site, unsigned step) {
#if TARGET_OS_SIMULATOR
    static unsigned failures[4];
    unsigned index = site->client * 2 + site->vm;
    if (audit_enabled() && !(failures[index] & (1u << step))) {
        failures[index] |= 1u << step;
        fprintf(stderr, "[vision-carry] Simulator %s %s target rejected at check %u\n",
                site->client ? "client" : "server", site->vm ? "viewmodel" : "physics", step);
    }
#else
    (void)site; (void)step;
#endif
}
#endif

void p2_vision_carry_lifecycle(CPU *c, uint32_t address) {
#if P2_XR_CARRY_PROFILE && P2_RETICLE_PROFILE
    const CarrySite *site = verified_site(c, address);
    if (!site) return;
    if (address == P2_XR_CARRY_SERVER_DETACH_SITE) {
        if (R32(c->esp + 4) == carried.grab) {
            if (audit_enabled()) fprintf(stderr, "[vision-carry] detached %#x\n", carried.handle);
            memset(&carried, 0, sizeof(carried));
        }
        return;
    }
    if (address != P2_XR_CARRY_SERVER_ATTACH_SITE) return;
    uint32_t pickup = c->ebx;
    if (!pointer(pickup) || R32(pickup) != site->base + SERVER_PICKUP_VTABLE) return;
    uint32_t player = R32(pickup + PICKUP_OWNER), grab = pickup + PICKUP_GRAB;
    if (!local_player(0, player) || R32(grab) != site->base + SERVER_GRAB_VTABLE) return;
    uint32_t handle = R32(grab + SERVER_HELD_HANDLE);
    if (!entity(0, handle)) return;

    memset(&carried, 0, sizeof(carried));
    P2XRInput input;
    uint64_t session = p2_xr_read_latest(NULL, &input);
    unsigned hand = P2_XR_AIM_HAND;
    if (!audit_enabled()) {
        if (!session || !input.spatial || !input.connected) return;
        // If no recent grip edge survived a delay, use the weapon hand.
        p2_vision_take_grip_use(session, &hand);
    }
    carried.grab = grab;
    carried.player = player;
    carried.handle = handle;
    carried.session = session;
    carried.hand = hand;
    carried.attached_at = monotonic_seconds();
    fprintf(stderr, "[vision-carry] %s engaged for handle %#x with %s hand\n",
            audit_enabled() ? "Simulator fixture" : "Tracked carry", handle, hand ? "right" : "left");
#else
    (void)c; (void)address;
#endif
}

void p2_vision_carry_target(CPU *c, uint32_t address) {
#if P2_XR_CARRY_PROFILE && P2_RETICLE_PROFILE
    if (!carried.grab) return;
    const CarrySite *site = verified_site(c, address);
    if (!site) {
        static unsigned reports;
        if (audit_enabled() && reports++ < 4) fprintf(stderr, "[vision-carry] Site %#x failed signature check\n", address);
        return;
    }
    carried.rotations[site->client].grab = 0;
    uint32_t ray = R32(c->esp), grab, player;
    if (R32(c->esp + 4) != (site->vm ? 0x0200400bu : 0x400bu)) { audit_rejected(site, 1); return; }
    if (site->vm && site->client) {
        if (ray != c->ebp - 0xc8u) { audit_rejected(site, 2); return; }
        grab = R32(c->ebp + 8);
        player = R32(c->ebp + 12);
    } else {
        uint32_t args = c->esp + (site->vm ? 0x200 : 0x280);
        if (ray != c->esp + (site->vm ? 0x130 : 0x160)) { audit_rejected(site, 2); return; }
        grab = R32(args);
        player = R32(args + 4);
    }
    if (!R8(ray + RAY_IS_RAY) || !pointer(grab) || !local_player(site->client, player)) {
        audit_rejected(site, !R8(ray + RAY_IS_RAY) ? 3 : 4);
        return;
    }
    if (site->client) {
        if (R32(grab) != site->base + CLIENT_GRAB_VTABLE || R8(player + CLIENT_PORTAL_HELD) ||
            entity(1, R32(player + CLIENT_PORTAL_HANDLE)) ||
            entity(1, R32(player + P2_RETICLE_PORTAL_ENVIRONMENT))) { audit_rejected(site, 5); return; }
        uint32_t handle = R32(grab + CLIENT_HELD_HANDLE);
        if ((handle & 0xffffu) != (carried.handle & 0xffffu) || !entity(1, handle)) { audit_rejected(site, 6); return; }
        // The client has its own handle serials. Bind once after matching the
        // authoritative entity slot and continue to check that client serial.
        if (!carried.client_grab) {
            carried.client_grab = grab;
            carried.client_handle = handle;
        }
        if (carried.client_grab != grab || carried.client_handle != handle) return;
    } else if (grab != carried.grab || player != carried.player ||
               R32(grab + SERVER_HELD_HANDLE) != carried.handle || !entity(0, carried.handle) ||
               R8(player + SERVER_PORTAL_HELD) || entity(0, R32(player + SERVER_PORTAL_HANDLE))) { audit_rejected(site, 7); return; }

    vector_float3 origin = load_vector(ray), target, delta;
    matrix_float3x3 grip;
    if (audit_enabled()) {
        double elapsed = monotonic_seconds() - carried.attached_at;
        target = origin + (vector_float3){42, elapsed < 1.5 ? -9 : 9, -11};
        grip = p2_xr_angle_matrix((vector_float3){0, elapsed < 2.25 ? 0 : 35, 0});
    } else {
        P2XRFrame frame;
        P2XRInput input;
        uint64_t session = p2_xr_read_latest(&frame, &input);
        if (session != carried.session || !p2_vision_carry_grip(session, &frame, &input, carried.hand, origin, &target, &grip)) return;
    }
    delta = target - origin;
    float square = simd_length_squared(delta);
    if (!(square >= 1 && square <= 60 * 60)) { audit_rejected(site, 8); return; }

    // Change only the desired ray. The original stock start, brush and hull
    // traces, penetration handling and physics controller remain in charge.
    store_vector(ray + RAY_DELTA, delta);
    W8(ray + RAY_IS_SWEPT, 1);
    if (!site->vm) {
        WF(ray - 0x120, sqrtf(square));
        WF(ray - (site->client ? 0x118 : 0x11c), 0); // stock head-based elevation
    } else if (site->client) {
        WF(ray - 0x100, square);
        WF(ray - 0x104, delta.x);
        WF(ray - 0xfc, delta.y);
        WF(ray - 0xf0, delta.z);
    } else {
        WF(ray - 0xf8, square);
        WF(ray - 0xec, delta.x);
        WF(ray - 0xf0, delta.y);
        WF(ray - 0xf4, delta.z);
    }
    carried.rotations[site->client].grab = grab;
    carried.rotations[site->client].vm = site->vm;
    carried.rotations[site->client].grip = grip;
    unsigned log_bit = 1u << (site->client * 2 + site->vm);
    if (audit_enabled() && delta.y > 0) log_bit <<= 4;
    if (!(carried.logged & log_bit)) {
        carried.logged |= log_bit;
        fprintf(stderr, "[vision-carry] %s %s target for %#x: (%.2f, %.2f, %.2f)\n",
                site->client ? "Client" : "Server", site->vm ? "viewmodel" : "physics",
                carried.handle, delta.x, delta.y, delta.z);
    }
#else
    (void)c; (void)address;
#endif
}

void p2_vision_carry_angles(CPU *c, uint32_t address) {
#if P2_XR_CARRY_PROFILE && P2_RETICLE_PROFILE && defined(P2_XR_CARRY_SERVER_ANGLES_SITE)
    if (!carried.grab) return;
    const CarrySite *site = verified_site(c, address);
    if (!site) return;
    typeof(carried.rotations[0]) *rotation = &carried.rotations[site->client];
    if (!rotation->grab || rotation->vm != site->vm) return;

    uint32_t grab, angles;
    vector_float3 stock;
    if (site->vm && site->client) {
        grab = c->ebx;
        angles = c->ebp - 0x164;
        if (grab != R32(c->ebp + 8) || c->esi != R32(c->ebp + 12) ||
            R32(angles) != c->xmm[3].d[0] || R32(angles + 4) != c->xmm[1].d[0] ||
            R32(angles + 8) != c->xmm[2].d[0]) return;
    } else if (site->vm) {
        grab = c->esi;
        angles = R32(c->esp + 8);
        if (grab != R32(c->esp) || angles != c->ebp || angles != c->esp + 0x94) return;
    } else {
        grab = site->client ? c->ebp : c->ebx;
        angles = R32(c->esp);
        if (angles != c->esi || angles != c->esp + 0xcc || R32(c->esp + 4) != c->esp + 0x110) return;
    }
    if (grab != rotation->grab) return;
    rotation->grab = 0;
    stock = load_vector(angles);
    if (!(fabsf(stock.x) < 720 && fabsf(stock.y) < 720 && fabsf(stock.z) < 720)) return;
    if (!rotation->linked) {
        rotation->object_from_grip = simd_mul(simd_transpose(rotation->grip), p2_xr_angle_matrix(stock));
        rotation->linked = 1;
    }
    vector_float3 tracked = p2_xr_matrix_angles(simd_mul(rotation->grip, rotation->object_from_grip));
    if (site->client && site->vm) {
        c->xmm[3].f[0] = tracked.x;
        c->xmm[1].f[0] = tracked.y;
        c->xmm[2].f[0] = tracked.z;
    } else store_vector(angles, tracked);
    unsigned bit = 1u << (8 + site->client * 2 + site->vm);
    if (audit_enabled() && monotonic_seconds() - carried.attached_at > 2.25) bit <<= 4;
    if (audit_enabled() && !(carried.logged & bit)) {
        carried.logged |= bit;
        fprintf(stderr, "[vision-carry] %s %s angle: %.1f %.1f %.1f\n",
                site->client ? "Client" : "Server", site->vm ? "viewmodel" : "physics",
                tracked.x, tracked.y, tracked.z);
    }
#else
    (void)c; (void)address;
#endif
}
#endif
