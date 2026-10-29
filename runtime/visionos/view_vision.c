// The first stage is a pass-through renderer audit. No camera is changed.
// The build tool accepts only the owned, SHA-256 checked Linux client profile.
#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include "modules.h"
#include "view_vision.h"
#include "../../build/visionos/xr-profile.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t original, table;
static int enabled = -1, installed, failed;
static unsigned calls;

static float field(const unsigned char *view, size_t offset) {
    float value;
    memcpy(&value, view + offset, sizeof(value));
    return value;
}

static int audit_render(CPU *c, const char *name) {
    if (strcmp(name, "__p2_vision_render_view_audit")) return 0;
    uint32_t args[5];
    for (unsigned i = 0; i < 5; ++i) args[i] = R32(c->esp + 4 + i * 4);
    const unsigned char *view = rt_span(c, args[1], P2_XR_VIEW_SETUP_SIZE);
    int32_t width, height;
    memcpy(&width, view + 16, 4); memcpy(&height, view + 24, 4);
    float fov = field(view, 104), aspect = field(view, 152);
    int plausible = width > 0 && width <= 8192 && height > 0 && height <= 8192 &&
        isfinite(fov) && fov > 1 && fov < 179 && isfinite(aspect) && aspect >= 0 && aspect < 10;
    for (size_t offset = 112; offset < 136; offset += 4)
        plausible = plausible && isfinite(field(view, offset));
    if (++calls <= 3 || !plausible) {
        fprintf(stderr, "[vision-view] pass-through RenderView #%u: this=%#x view=%#x %dx%d fov=%.3f aspect=%.3f origin=(%.3f,%.3f,%.3f) angles=(%.3f,%.3f,%.3f) clear=%#x draw=%#x ABI=%s\n",
            calls, args[0], args[1], width, height, fov, aspect,
            field(view,112),field(view,116),field(view,120),
            field(view,124),field(view,128),field(view,132),args[3],args[4],plausible ? "plausible" : "REJECTED");
    }
    if (!plausible && !failed) {
        failed = 1;
        W32(table + 6 * 4, original);
        fprintf(stderr, "[vision-view] Removed audit hook after unexpected camera layout\n");
    }
    c->eax = rt_invoke(c, original, args, 5);
    return 1;
}
RT_SHIM_PROVIDER(audit_render)

void p2_vision_view_poll(void) {
    if (enabled < 0) {
        const char *value = getenv("P2_XR_HOOK_AUDIT");
        enabled = value && !strcmp(value, "1");
    }
    if (!enabled || installed || failed) return;
    const GuestModule *client = rt_find_module("client.so");
    if (!client) return;
    table = client->base + P2_XR_CLIENT_VTABLE_RVA;
    original = client->base + P2_XR_RENDER_VIEW_RVA;
    CPU *c = rt_foreign_thread_attach();
    if (!c) return;
    if (R32(table + 6 * 4) != original ||
        memcmp(rt_span(c, original, sizeof(p2_xr_render_signature)),
               p2_xr_render_signature, sizeof(p2_xr_render_signature))) {
        failed = 1;
        fprintf(stderr, "[vision-view] Refused audit hook: loaded client profile mismatch\n");
        return;
    }
    uint32_t replacement = rt_dynamic_import("__p2_vision_render_view_audit");
    if (!replacement) { failed = 1; return; }
    W32(table + 6 * 4, replacement);
    installed = 1;
    fprintf(stderr, "[vision-view] Installed pass-through Linux RenderView audit at %#x (original %#x); no stereo camera changes\n", table + 6 * 4, original);
}
#endif
