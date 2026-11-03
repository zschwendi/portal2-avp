// Tracked PSVR2 Sense portal-gun aim in immersive play.
//
// Portal placement: server.so CWeaponPortalgun::TraceFirePortal and its
// client.so prediction copy are non-virtual and reached by one direct call
// each, so tools/lift.py NATIVE_OVERRIDES routes them through runtime/native.c
// to p2_vision_trace_fire_portal. Only the audited caller (SHA-pinned module,
// loaded entry and call-site bytes, return address) with a player-placed shot
// is touched: the start/direction vectors that caller passed are rewritten to
// the right controller's aim ray and the translated function then traces it.
// The caller's later uses of the same vectors (the PortalBlast effect angles)
// follow along. Grab and use keep following the head (seated head aim sets the
// engine view angles; view_vision.c).
//
// Viewmodel: C_BaseViewModel/C_PredictedViewModel CalcViewModelView (vtable
// slot 288, audited by tools/visionos_hooks.py) runs unchanged, then the model
// is placed at the controller with the engine's own SetLocalOrigin/Angles, so
// head bob, lag and shake never move the gun out of the hand.
//
// Behaviour reference: the unlicensed Portal2VR mod also aims TraceFirePortal
// and CalcViewModelView from a controller; nothing was copied from it.
// Signatures/slots: p2sr/SourceAutoRecord (MIT) Linux locators, re-derived
// from the owned binaries. Physical aim and viewmodel placement are unverified.
#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include "modules.h"
#include "aim_vision.h"
#include "view_vision.h"
#include "../../build/visionos/xr-profile.h"
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef P2_XR_PORTAL_AIM_PROFILE
#define P2_XR_PORTAL_AIM_PROFILE 0 // profile predates the server audit: portals follow the head
#endif
#ifndef P2_XR_CLIENT_PORTAL_AIM_PROFILE
#define P2_XR_CLIENT_PORTAL_AIM_PROFILE 0
#endif
#ifndef P2_XR_VIEWMODEL_PROFILE
#define P2_XR_VIEWMODEL_PROFILE 0
#endif

int rt_ios_game_ui_visible_shared(void); // runtime/ios/game_state.c, any thread

static pthread_mutex_t basis_lock = PTHREAD_MUTEX_INITIALIZER;
static P2XRAimBasis basis;
static pthread_once_t settings_once = PTHREAD_ONCE_INIT;
static int controller_aim, viewmodel_enabled;
// Viewmodel origin relative to the grip, in the aim frame (forward, left, up),
// Source units. Starting point, not a calibration: Portal 2 starts its shot
// effect 30 forward, 4 right and 8 below the eye, and the owned v_portalgun
// hand bone sits ~25 units behind its muzzle, so the gun's hand is near
// (5, -5, -9) from the viewmodel origin. P2_XR_VIEWMODEL_OFFSET overrides it.
static vector_float3 grip_offset = {-5, 5, 9};

static double monotonic(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + now.tv_nsec * 1e-9;
}
static int disabled(const char *name) {
    const char *value = getenv(name);
    return value && !strcmp(value, "0");
}
static void read_settings(void) {
    // Same switch as the lifter wrapper (rt_native_enabled): when it keeps the
    // translated trace, nothing else may claim controller aim either.
    controller_aim = P2_XR_PORTAL_AIM_PROFILE && !disabled("P2_NATIVE_TRACE_FIRE_PORTAL");
    viewmodel_enabled = controller_aim && P2_XR_VIEWMODEL_PROFILE && !disabled("P2_XR_VIEWMODEL");
    const char *value = getenv("P2_XR_VIEWMODEL_OFFSET");
    if (value && *value) {
        float x, y, z;
        char tail;
        if (sscanf(value, "%f,%f,%f%c", &x, &y, &z, &tail) == 3 && isfinite(x) && isfinite(y) && isfinite(z) &&
            fabsf(x) <= 40 && fabsf(y) <= 40 && fabsf(z) <= 40) grip_offset = (vector_float3){x, y, z};
        else fprintf(stderr, "[vision-aim] P2_XR_VIEWMODEL_OFFSET=%s rejected (forward,left,up within 40 units)\n", value);
    }
    fprintf(stderr, "[vision-aim] Controller portal aim %s (server profile %d, client prediction %d, viewmodel %d, "
        "grip offset %.1f,%.1f,%.1f); physical aim unverified\n", controller_aim ? "available" : "off",
        P2_XR_PORTAL_AIM_PROFILE, P2_XR_CLIENT_PORTAL_AIM_PROFILE, viewmodel_enabled,
        grip_offset.x, grip_offset.y, grip_offset.z);
}
static void settings(void) { pthread_once(&settings_once, read_settings); }

void p2_vision_aim_publish(uint64_t session, uint64_t sequence, const P2XRBody *body, vector_float3 head_angles) {
    P2XRAimBasis next;
    int valid = p2_xr_aim_basis(&next, session, sequence, monotonic(), body, head_angles);
    pthread_mutex_lock(&basis_lock);
    if (valid) basis = next;
    else memset(&basis, 0, sizeof(basis));
    pthread_mutex_unlock(&basis_lock);
}
void p2_vision_aim_clear(void) {
    pthread_mutex_lock(&basis_lock);
    memset(&basis, 0, sizeof(basis));
    pthread_mutex_unlock(&basis_lock);
}
// Everything a controller shot or viewmodel needs: audited profile, Sense
// pair owning input, current tracked session with the right controller
// tracked, head aim recent, game UI hidden.
static int aim_live(P2XRAimBasis *current, P2XRFrame *latest) {
    settings();
    if (!controller_aim) return 0;
    P2XRInput controls;
    uint64_t session = p2_xr_read_latest(latest, &controls);
    if (!session || !controls.spatial || !controls.connected || rt_ios_game_ui_visible_shared()) return 0;
    pthread_mutex_lock(&basis_lock);
    *current = basis;
    pthread_mutex_unlock(&basis_lock);
    return p2_xr_aim_fresh(current, session, latest, monotonic());
}
int p2_vision_controller_aim_active(void) {
    P2XRAimBasis current;
    P2XRFrame latest;
    return aim_live(&current, &latest);
}

// Unused when the profile header disables controller aim.
__attribute__((unused)) static int pointer(uint32_t address) { return address >= 0x10000 && address < RT_IMPORT_BASE - 128; }
__attribute__((unused)) static vector_float3 read_vector(uint32_t address) {
    float value[3];
    memcpy(value, GPTR(address), sizeof(value));
    return (vector_float3){value[0], value[1], value[2]};
}
__attribute__((unused)) static void write_vector(uint32_t address, vector_float3 vector) {
    float value[3] = {vector.x, vector.y, vector.z};
    memcpy(GPTR(address), value, sizeof(value));
}

// ---- Portal placement ------------------------------------------------------
#if P2_XR_PORTAL_AIM_PROFILE
static struct { uint32_t entry, back; int valid; unsigned shots, kept; } sites[2];
// The audited callers pass their own stack vectors (above the six arguments).
static int caller_vector(const CPU *c, uint32_t address) {
    return address >= c->esp + 28 && address <= c->esp + 0x1000 - 12 && !(address & 3);
}
static int audited_site(CPU *c, uint32_t entry, int client) {
    if (sites[client].entry == entry) return sites[client].valid;
    sites[client].entry = entry;
    sites[client].valid = 0;
    const GuestModule *module = rt_find_module(client ? "client.so" : "server.so");
    uint32_t rva = P2_XR_SERVER_TRACE_FIRE_PORTAL_RVA, back = P2_XR_SERVER_TRACE_FIRE_PORTAL_RETURN_RVA;
    const unsigned char *signature = p2_xr_server_trace_signature, *call = p2_xr_server_trace_call_site;
    size_t signature_size = sizeof(p2_xr_server_trace_signature), call_size = sizeof(p2_xr_server_trace_call_site);
#if P2_XR_CLIENT_PORTAL_AIM_PROFILE
    if (client) {
        rva = P2_XR_CLIENT_TRACE_FIRE_PORTAL_RVA; back = P2_XR_CLIENT_TRACE_FIRE_PORTAL_RETURN_RVA;
        signature = p2_xr_client_trace_signature; call = p2_xr_client_trace_call_site;
        signature_size = sizeof(p2_xr_client_trace_signature); call_size = sizeof(p2_xr_client_trace_call_site);
    }
#else
    if (client) module = NULL; // no audited client profile: prediction keeps the head ray
#endif
    if (module && entry == module->base + rva) {
        back += module->base;
        sites[client].back = back;
        sites[client].valid = !memcmp(rt_span(c, entry, signature_size), signature, signature_size) &&
            !memcmp(rt_span(c, back - call_size, call_size), call, call_size);
    }
    fprintf(stderr, "[vision-aim] %s TraceFirePortal override %s at %#x (caller returns to %#x)\n",
        client ? "Client prediction" : "Server", sites[client].valid ? "wired" : !module ?
        "off: no audited profile (keeps the head ray)" : "REFUSED: loaded code is not the audited profile",
        entry, sites[client].back);
    return sites[client].valid;
}
#endif

int p2_vision_trace_fire_portal(CPU *c, uint32_t entry, int client) {
#if P2_XR_PORTAL_AIM_PROFILE
    settings();
    if (!controller_aim || (client != 0 && client != 1) || !audited_site(c, entry, client)) return 0;
    // [esp] return, +4 this, +8 &start, +12 &direction, +16 portal2, +20 placed-by.
    if (R32(c->esp) != sites[client].back || R32(c->esp + 20) != P2_XR_PORTAL_PLACED_BY_PLAYER) return 0;
    uint32_t start_at = R32(c->esp + 8), direction_at = R32(c->esp + 12);
    if (!caller_vector(c, start_at) || !caller_vector(c, direction_at) ||
        (start_at > direction_at ? start_at - direction_at : direction_at - start_at) < 12) return 0;
    P2XRAimBasis current;
    P2XRFrame latest;
    if (!aim_live(&current, &latest)) return 0;
    vector_float3 engine_start = read_vector(start_at), engine_direction = read_vector(direction_at), start, direction;
    if (!p2_xr_aim_ray(&current, &latest, engine_start, engine_direction, &start, &direction)) {
        if (++sites[client].kept <= 8)
            fprintf(stderr, "[vision-aim] %s shot kept the engine ray (%.3f,%.3f,%.3f): not the head aim "
                "(portal the player stands in, scripted direction) or controller pose rejected\n",
                client ? "Predicted" : "Server", engine_direction.x, engine_direction.y, engine_direction.z);
        return 0;
    }
    write_vector(start_at, start);
    write_vector(direction_at, direction);
    if (++sites[client].shots <= 16)
        fprintf(stderr, "[vision-aim] %s shot #%u from the right controller: start (%.1f,%.1f,%.1f) -> (%.1f,%.1f,%.1f), "
            "direction (%.3f,%.3f,%.3f) -> (%.3f,%.3f,%.3f), pose %llu\n", client ? "Predicted" : "Server",
            sites[client].shots, engine_start.x, engine_start.y, engine_start.z, start.x, start.y, start.z,
            engine_direction.x, engine_direction.y, engine_direction.z, direction.x, direction.y, direction.z,
            (unsigned long long)latest.sequence);
    return 0; // the translated TraceFirePortal traces the rewritten ray
#else
    (void)c; (void)entry; (void)client;
    return 0;
#endif
}

// ---- Viewmodel at the controller --------------------------------------------
#if P2_XR_PORTAL_AIM_PROFILE && P2_XR_VIEWMODEL_PROFILE
static uint32_t view_original, set_origin, set_angles, pose_buffer;
static int view_state; // 0 not tried, 1 installed, -1 refused
static unsigned placed;
#endif

void p2_vision_viewmodel_install(CPU *c) {
#if P2_XR_PORTAL_AIM_PROFILE && P2_XR_VIEWMODEL_PROFILE
    settings();
    if (view_state || !viewmodel_enabled) return;
    const GuestModule *client = rt_find_module("client.so");
    if (!client) return;
    uint32_t base = client->base, slots[2] = {
        base + P2_XR_VIEWMODEL_VTABLE_RVA + P2_XR_CALC_VIEWMODEL_VIEW_SLOT * 4,
        base + P2_XR_PREDICTED_VIEWMODEL_VTABLE_RVA + P2_XR_CALC_VIEWMODEL_VIEW_SLOT * 4};
    view_original = base + P2_XR_CALC_VIEWMODEL_VIEW_RVA;
    set_origin = base + P2_XR_SET_LOCAL_ORIGIN_RVA;
    set_angles = base + P2_XR_SET_LOCAL_ANGLES_RVA;
    view_state = -1;
    if (R32(slots[0]) != view_original || R32(slots[1]) != view_original ||
        memcmp(rt_span(c, view_original, sizeof(p2_xr_calc_viewmodel_view_signature)),
               p2_xr_calc_viewmodel_view_signature, sizeof(p2_xr_calc_viewmodel_view_signature)) ||
        memcmp(rt_span(c, set_origin, sizeof(p2_xr_set_local_origin_signature)),
               p2_xr_set_local_origin_signature, sizeof(p2_xr_set_local_origin_signature)) ||
        memcmp(rt_span(c, set_angles, sizeof(p2_xr_set_local_angles_signature)),
               p2_xr_set_local_angles_signature, sizeof(p2_xr_set_local_angles_signature))) {
        fprintf(stderr, "[vision-aim] Refused viewmodel hook: loaded client viewmodel code is not the audited profile; gun stays head-locked\n");
        return;
    }
    uint32_t replacement = rt_dynamic_import("__p2_vision_calc_viewmodel_view");
    if (!replacement) return;
    W32(slots[0], replacement);
    W32(slots[1], replacement);
    view_state = 1;
    fprintf(stderr, "[vision-aim] Installed viewmodel hook (CalcViewModelView slot %u, original %#x); the gun follows the right controller only while controller aim is active\n",
        P2_XR_CALC_VIEWMODEL_VIEW_SLOT, view_original);
#else
    (void)c;
#endif
}

static int viewmodel_shim(CPU *c, const char *name) {
    if (strcmp(name, "__p2_vision_calc_viewmodel_view")) return 0;
#if P2_XR_PORTAL_AIM_PROFILE && P2_XR_VIEWMODEL_PROFILE
    // (this, owner, const Vector *eye, const QAngle *angles): the engine's own
    // placement first, unchanged, so its bob/lag state stays continuous.
    uint32_t args[4];
    for (unsigned i = 0; i < 4; ++i) args[i] = R32(c->esp + 4 + i * 4);
    rt_invoke(c, view_original, args, 4);
    P2XRAimBasis current;
    P2XRFrame latest;
    P2XRSourceView pose;
    if (!pointer(args[0]) || !pointer(args[2]) || !aim_live(&current, &latest) ||
        !p2_xr_aim_viewmodel(&current, &latest, read_vector(args[2]), grip_offset, &pose)) return 1;
    if (!pose_buffer && !(pose_buffer = rt_alloc(24))) return 1;
    write_vector(pose_buffer, pose.origin);
    write_vector(pose_buffer + 12, pose.angles);
    uint32_t place[2] = {args[0], pose_buffer};
    rt_invoke(c, set_origin, place, 2);
    place[1] = pose_buffer + 12;
    rt_invoke(c, set_angles, place, 2);
    if (++placed <= 3)
        fprintf(stderr, "[vision-aim] Viewmodel %#x placed at the controller: origin (%.1f,%.1f,%.1f) angles (%.1f,%.1f,%.1f)\n",
            args[0], pose.origin.x, pose.origin.y, pose.origin.z, pose.angles.x, pose.angles.y, pose.angles.z);
    return 1;
#else
    (void)c;
    return 0; // never imported without the audited profile
#endif
}
RT_SHIM_PROVIDER(viewmodel_shim)
#endif
