// Pass through normal windowed rendering; paired rendering requires either
// a live XR session or the explicitly selected synthetic stereo diagnostic.
// Accept only the owned, SHA-256 checked Linux client profile.
#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include "modules.h"
#include "view_vision.h"
#include "gl_vision.h"
#include "../../build/visionos/xr-profile.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t original, table;
static int enabled = -1, installed, failed;
static unsigned calls;
static int stereo_audit, input_audit, rendering;
static uint32_t eye_views[2], eye_hud[2];
static uint64_t aligned_session;
static matrix_float4x4 source_from_tracking;
static vector_float3 previous_origin;
static float previous_yaw;
static unsigned stereo_frames;
static uint32_t previous_buttons;
void rt_ios_game_state_poll(void);
int rt_ios_game_ui_visible(void);
static float field(const unsigned char *view, size_t offset);

static void put_float(uint32_t address, unsigned offset, float value) { memcpy(GPTR(address + offset),&value,4); }
static void put_vector(uint32_t address, unsigned offset, vector_float3 value) {
    put_float(address,offset,value.x); put_float(address,offset+4,value.y); put_float(address,offset+8,value.z);
}

static void follow_player(const P2XRFrame *pose, uint64_t session, vector_float3 origin, float yaw) {
    if (aligned_session != session) {
        if (p2_xr_align(pose,origin,yaw,P2_XR_UNITS_PER_METER,&source_from_tracking)) aligned_session = session;
    } else {
        float delta = remainderf(yaw - previous_yaw,360) * (float)M_PI / 180;
        float c = cosf(delta), s = sinf(delta);
        matrix_float4x4 motion = {{{c,s,0,0},{-s,c,0,0},{0,0,1,0},{0,0,0,1}}};
        vector_float3 shift = origin - simd_mul(motion,(vector_float4){previous_origin.x,previous_origin.y,previous_origin.z,1}).xyz;
        motion.columns[3] = (vector_float4){shift.x,shift.y,shift.z,1};
        source_from_tracking = simd_mul(motion,source_from_tracking);
    }
    previous_origin = origin; previous_yaw = yaw;
}

static int render_stereo(CPU *c, const uint32_t original_args[5], const unsigned char *view) {
    P2XRFrame pose; P2XRInput controls;
    uint64_t session = p2_xr_read_latest(&pose,&controls);
    int diagnostic = !session && stereo_audit;
    if ((!session && !diagnostic) || rendering) return 0;
    int width = 0, height = 0;
    int32_t setup_width, setup_height;
    p2_vision_gl_drawable_size(&width,&height);
    memcpy(&setup_width,view+16,4); memcpy(&setup_height,view+24,4);
    if (setup_width != width || setup_height != height) return 0;
    rt_ios_game_state_poll();
    if (rt_ios_game_ui_visible() || view[32]) return 0;
    if (session && (controls.buttons & P2_XR_RECENTER) && !(previous_buttons & P2_XR_RECENTER)) aligned_session = 0;
    previous_buttons = controls.buttons;
    vector_float3 origin = {field(view,112),field(view,116),field(view,120)};
    vector_float3 angles = {field(view,124),field(view,128),field(view,132)};
    if (session) {
        follow_player(&pose,session,origin,angles.y);
        if (aligned_session != session) return 0;
    }
    for (unsigned eye = 0; eye < 2; ++eye) {
        if (!eye_views[eye]) eye_views[eye] = rt_alloc(P2_XR_VIEW_SETUP_SIZE);
        if (!eye_hud[eye]) eye_hud[eye] = rt_alloc(P2_XR_VIEW_SETUP_SIZE);
        if (!eye_views[eye] || !eye_hud[eye]) return 0;
    }
    // Copy before either render can update CViewRender's cached setup.
    unsigned char camera[P2_XR_VIEW_SETUP_SIZE], hud[P2_XR_VIEW_SETUP_SIZE];
    memcpy(camera,view,sizeof(camera));
    memcpy(hud,rt_span(c,original_args[2],sizeof(hud)),sizeof(hud));
    rendering = 1;
    for (unsigned eye = 0; eye < 2; ++eye) {
        memcpy(GPTR(eye_views[eye]),camera,sizeof(camera));
        memcpy(GPTR(eye_hud[eye]),hud,sizeof(hud));
        P2XRSourceView source = {.origin=origin,.angles=angles};
        if (session) {
            if (!p2_xr_source_view(&pose,eye,source_from_tracking,&source)) goto mono;
        } else {
            float pitch=angles.x*(float)M_PI/180, yaw=angles.y*(float)M_PI/180, roll=angles.z*(float)M_PI/180;
            vector_float3 right = {-sinf(roll)*sinf(pitch)*cosf(yaw)+cosf(roll)*sinf(yaw),
                -sinf(roll)*sinf(pitch)*sinf(yaw)-cosf(roll)*cosf(yaw),-sinf(roll)*cosf(pitch)};
            source.origin += right * (eye ? 0.032f : -0.032f) * P2_XR_UNITS_PER_METER;
        }
        for (unsigned target = 0; target < 2; ++target) {
            uint32_t setup = target ? eye_hud[eye] : eye_views[eye];
            *(unsigned char *)GPTR(setup + 52) = 0; // the supplied pose owns the view matrix
            put_vector(setup,112,source.origin); put_vector(setup,124,source.angles);
            if (session) {
                float x = source.projection.columns[0].x, y = source.projection.columns[1].y;
                if (!(x > 0 && y > 0)) goto mono;
                float fov = 2 * atanf(1/x) * 180 / (float)M_PI;
                put_float(setup,104,fov); put_float(setup,108,fov); put_float(setup,152,y/x);
                put_float(setup,240,1 + source.projection.columns[2].y/2);
                put_float(setup,244,source.projection.columns[2].y/2);
                put_float(setup,248,source.projection.columns[2].x/2);
                put_float(setup,252,1 + source.projection.columns[2].x/2);
                *(unsigned char *)GPTR(setup+256) |= 1;
                put_float(setup,136,2); put_float(setup,144,2);
            }
        }
        if (p2_vision_gl_begin_eye(eye)) goto mono;
        uint32_t args[5]; memcpy(args,original_args,sizeof(args));
        args[1] = eye_views[eye]; args[2] = eye_hud[eye];
        c->eax = rt_invoke(c,original,args,5);
        if (p2_vision_gl_end_eye(eye)) goto mono;
    }
    // Keep the right eye current: togl's normal Present writes there after
    // the captured left image is complete. Mono fallback must restore eye 0.
    int marked = p2_vision_gl_mark_stereo(session,session ? &pose : NULL,diagnostic);
    if (!marked) goto mono;
    rendering = 0;
    if (marked && ++stereo_frames <= 3)
        fprintf(stderr,"[vision-view] Stereo pair #%u rendered: session=%llu pose=%llu diagnostic=%d; physical gameplay unverified\n",
            stereo_frames,(unsigned long long)session,(unsigned long long)(session ? pose.sequence : 0),diagnostic);
    return marked;
mono:
    rendering = 0;
    p2_vision_gl_begin_eye(0);
    return 0;
}

static int pointer(uint32_t address) { return address >= 0x10000 && address < RT_IMPORT_BASE - 128; }
static const char *text(CPU *c, uint32_t address) {
    return pointer(address) ? rt_span(c,address,128) : "";
}
static uint32_t seen_tables[64];
static unsigned table_count;
static void audit_table(CPU *c, uint32_t table_address, unsigned depth) {
    if (!pointer(table_address) || depth > 10 || table_count == 64) return;
    for (unsigned i = 0; i < table_count; ++i) if (seen_tables[i] == table_address) return;
    seen_tables[table_count++] = table_address;
    const uint32_t *table_data = rt_span(c,table_address,20);
    uint32_t properties = table_data[0], count = table_data[1];
    const char *table_name = text(c,table_data[3]);
    if (!pointer(properties) || count > 512) return;
    // Public Source i386 RecvProp ABI: 60 bytes, nested table at +40,
    // object-relative offset +44, element stride/count +48/+52.
    for (uint32_t i = 0; i < count; ++i) {
        const uint32_t *property = rt_span(c,properties + i * 60,60);
        const char *name = text(c,property[0]);
        if (strstr(name,"Portal") || strstr(name,"matrixThisToLinked") ||
            strstr(table_name,"EntityPortalled")) {
            fprintf(stderr,"[vision-metadata] %.96s.%.96s type=%u offset=%u stride=%u count=%u nested=%.96s\n",
                table_name,name,property[1],property[11],property[12],property[13],
                pointer(property[10]) ? text(c,R32(property[10] + 12)) : "");
        }
        if (property[1] == 6) audit_table(c,property[10],depth + 1); // DPT_DataTable
    }
}
static void audit_portal_metadata(CPU *c) {
    const GuestModule *client = rt_find_module("client.so");
    uint32_t create = client ? rt_module_symbol(client,"CreateInterface") : 0;
    uint32_t name = create ? rt_alloc(sizeof("VClient016")) : 0;
    if (!name) return;
    memcpy(GPTR(name),"VClient016",sizeof("VClient016"));
    uint32_t arguments[2] = {name,0};
    uint32_t interface = rt_invoke(c,create,arguments,2);
    rt_free(name);
    if (!pointer(interface)) return;
    // VClient016 GetAllClasses is slot 8 on both Linux and Windows;
    // subsequent structures here are explicitly the Linux i386 data ABI.
    uint32_t method = R32(R32(interface) + 8 * 4);
    uint32_t current = rt_invoke(c,method,&interface,1);
    for (unsigned n = 0; pointer(current) && n < 2048; ++n) {
        const uint32_t *description = rt_span(c,current,24);
        const char *class_name = text(c,description[2]);
        if (strstr(class_name,"Portal_Player") || strstr(class_name,"Prop_Portal")) {
            fprintf(stderr,"[vision-metadata] Portal client class %.96s at %#x\n",class_name,current);
            audit_table(c,description[3],0);
        }
        current = description[4];
    }
}

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
    if (++calls <= 3 || !plausible || (input_audit && calls % 60 == 0)) {
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
    if (plausible && calls == 1) audit_portal_metadata(c);
    if (plausible && render_stereo(c,args,view)) return 1;
    c->eax = rt_invoke(c, original, args, 5);
    return 1;
}
RT_SHIM_PROVIDER(audit_render)

void p2_vision_view_poll(void) {
    if (enabled < 0) {
        const char *value = getenv("P2_XR_HOOK_AUDIT");
        enabled = value && !strcmp(value, "1");
        value = getenv("P2_VISION_STEREO_AUDIT");
        stereo_audit = value && !strcmp(value,"1");
        value = getenv("P2_VISION_INPUT_AUDIT");
        input_audit = TARGET_OS_SIMULATOR && value && !strcmp(value,"1");
    }
    if (installed || failed || (!enabled && !stereo_audit && !input_audit && !p2_xr_read_latest(NULL,NULL))) return;
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
    fprintf(stderr, "[vision-view] Installed verified Linux RenderView hook at %#x (original %#x), audit=%d diagnostic_stereo=%d; tracked stereo requires a live XR session\n",
        table + 6 * 4, original,enabled,stereo_audit);
}
#endif
