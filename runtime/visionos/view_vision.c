// Pass through normal windowed rendering; paired rendering requires either
// a live XR session or the explicitly selected synthetic stereo diagnostic.
// Accept only the owned, SHA-256 checked Linux client profile. In a tracked
// immersive session the head also drives the engine view angles (seated head
// aim), only with the separately validated engine.so profile.
#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include "modules.h"
#include "view_vision.h"
#include "aim_vision.h"
#include "gl_vision.h"
#include "../../build/visionos/xr-profile.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef P2_XR_HEAD_AIM_PROFILE
#define P2_XR_HEAD_AIM_PROFILE 0 // profile predates the engine audit: no head aim
#endif

static uint32_t original, table;
static int enabled = -1, installed, failed;
static unsigned calls;
static int stereo_audit, input_audit, rendering;
static uint32_t eye_views[2], eye_hud[2];
static uint64_t aligned_session;
static P2XRBody body;
static float previous_yaw;
static unsigned stereo_frames;
static uint32_t previous_buttons;
static float units_per_meter = P2_XR_UNITS_PER_METER, snap_degrees = 45, smooth_rate;
void rt_ios_game_state_poll(void);
int rt_ios_game_ui_visible(void);
static float field(const unsigned char *view, size_t offset);

static void put_float(uint32_t address, unsigned offset, float value) { memcpy(GPTR(address + offset),&value,4); }
static void put_vector(uint32_t address, unsigned offset, vector_float3 value) {
    put_float(address,offset,value.x); put_float(address,offset+4,value.y); put_float(address,offset+8,value.z);
}
static int pointer(uint32_t address) { return address >= 0x10000 && address < RT_IMPORT_BASE - 128; }

// ---- Seated head aim --------------------------------------------------------
// VEngineClient015 (engine.so CreateInterface) GetViewAngles/SetViewAngles,
// Linux i386 cdecl (this, QAngle *). Slots 18/19 agree with
// p2sr/SourceAutoRecord (MIT) Portal 2 offsets; tools/visionos_hooks.py
// re-derives them from the SHA-256 pinned engine.so (RTTI vtable, byte
// prefixes, the setter's own "rejecting invalid value" message, the shared
// QAngle field). The interface vtable, loaded bytes and a write/read round
// trip are checked here. Any mismatch leaves head aim off and the stereo
// view on, with stick turning as before.
static int aim_status;          // 0 unresolved, 1 validated, -1 refused/disabled
static int aim_confirmed;       // a real change was written and read back
static uint32_t aim_interface, aim_get, aim_set, aim_buffer;
static uint64_t aim_session;    // tracked session whose head drives engine angles
static unsigned aim_rebases;
static P2XRSnapTurn snap;
static double turn_clock;

static void aim_refuse(const char *reason) {
    aim_status = -1; aim_session = 0;
    p2_vision_aim_clear(); // controller aim needs the head-driven engine angles
    fprintf(stderr,"[vision-aim] Head aim refused: %s; stereo view keeps stick turning\n",reason);
}
static int aim_read(CPU *c, vector_float3 *angles) {
    uint32_t arguments[2] = {aim_interface,aim_buffer};
    memset(GPTR(aim_buffer),0xff,12); // NaN: an untouched buffer fails below
    rt_invoke(c,aim_get,arguments,2);
    float value[3];
    memcpy(value,GPTR(aim_buffer),sizeof(value));
    // SetViewAngles normalizes to [-180,180]; a server fixangle may store
    // [0,360) yaw unnormalized. Anything beyond that is not an angle.
    for (unsigned i = 0; i < 3; ++i) if (!isfinite(value[i]) || fabsf(value[i]) > 720) return 0;
    *angles = (vector_float3){value[0],value[1],value[2]};
    return 1;
}
static void aim_write(CPU *c, vector_float3 angles) {
    float value[3] = {angles.x,angles.y,angles.z};
    memcpy(GPTR(aim_buffer),value,sizeof(value));
    uint32_t arguments[2] = {aim_interface,aim_buffer};
    rt_invoke(c,aim_set,arguments,2);
}
static int aim_resolve(CPU *c) {
    if (aim_status) return aim_status > 0;
#if P2_XR_HEAD_AIM_PROFILE
    const char *value = getenv("P2_XR_HEAD_AIM");
    if (value && !strcmp(value,"0")) { aim_refuse("disabled by P2_XR_HEAD_AIM=0"); return 0; }
    const GuestModule *engine = rt_find_module("engine.so");
    uint32_t create = engine ? rt_module_symbol(engine,"CreateInterface") : 0;
    if (!create) { aim_refuse("engine.so CreateInterface is absent"); return 0; }
    uint32_t name = rt_alloc(sizeof(P2_XR_ENGINE_CLIENT_INTERFACE));
    if (!name) return 0; // retry on a later frame
    memcpy(GPTR(name),P2_XR_ENGINE_CLIENT_INTERFACE,sizeof(P2_XR_ENGINE_CLIENT_INTERFACE));
    uint32_t arguments[2] = {name,0};
    uint32_t interface = rt_invoke(c,create,arguments,2);
    rt_free(name);
    uint32_t vtable = engine->base + P2_XR_ENGINE_CLIENT_VTABLE_RVA;
    uint32_t get = engine->base + P2_XR_GET_VIEW_ANGLES_RVA, set = engine->base + P2_XR_SET_VIEW_ANGLES_RVA;
    if (!pointer(interface) || R32(interface) != vtable ||
        R32(vtable + P2_XR_GET_VIEW_ANGLES_SLOT * 4) != get || R32(vtable + P2_XR_SET_VIEW_ANGLES_SLOT * 4) != set ||
        memcmp(rt_span(c,get,sizeof(p2_xr_get_view_angles_signature)),p2_xr_get_view_angles_signature,
               sizeof(p2_xr_get_view_angles_signature)) ||
        memcmp(rt_span(c,set,sizeof(p2_xr_set_view_angles_signature)),p2_xr_set_view_angles_signature,
               sizeof(p2_xr_set_view_angles_signature))) {
        aim_refuse("loaded " P2_XR_ENGINE_CLIENT_INTERFACE " does not match the audited engine.so profile");
        return 0;
    }
    if (!aim_buffer && !(aim_buffer = rt_alloc(12))) return 0;
    aim_interface = interface; aim_get = get; aim_set = set;
    vector_float3 angles;
    if (!aim_read(c,&angles)) { aim_refuse("implausible engine view angles"); return 0; }
    aim_status = 1;
    fprintf(stderr,"[vision-aim] Validated " P2_XR_ENGINE_CLIENT_INTERFACE " view angles (get %#x, set %#x) angles=(%.2f,%.2f,%.2f); physical head aim unverified\n",
        get,set,angles.x,angles.y,angles.z);
    return 1;
#else
    (void)c;
    aim_refuse("this build has no validated engine.so profile");
    return 0;
#endif
}
// Engine yaw changes the head did not write turn the body once, about the
// player: portal crossings, teleports, level changes, stick turning while
// tracking was lost. Pitch/roll changes are dropped (yaw-only re-base).
static int aim_observe(CPU *c, uint64_t session, vector_float3 *engine) {
    if (!aim_resolve(c)) return 0;
    if (!aim_read(c,engine)) { aim_refuse("engine view angles became implausible"); return 0; }
    if (aim_session != session || aligned_session != session) { body.engine_yaw = engine->y; return 1; }
    float expected = body.engine_yaw, turn = p2_xr_body_observe(&body,engine->y);
    if (turn != 0 && ++aim_rebases <= 64)
        fprintf(stderr,"[vision-aim] Body yaw re-based by %.2f (engine yaw %.2f, expected %.2f) at origin (%.1f,%.1f,%.1f)\n",
            turn,engine->y,expected,body.origin.x,body.origin.y,body.origin.z);
    return 1;
}
static void aim_drive(CPU *c, const P2XRFrame *pose, uint64_t session, vector_float3 engine) {
    vector_float3 head;
    if (aim_status <= 0 || aligned_session != session || !p2_xr_body_aim(&body,pose,&head)) return;
    aim_write(c,head);
    if (!aim_confirmed) {
        // Until one real change reads back, prove the setter feeds the getter.
        vector_float3 back;
        if (!aim_read(c,&back) || fabsf(remainderf(back.x - head.x,360)) > 0.01f ||
            fabsf(remainderf(back.y - head.y,360)) > 0.01f || fabsf(back.z) > 0.01f) {
            aim_refuse("written view angles did not read back");
            return;
        }
        aim_confirmed = fabsf(remainderf(head.x - engine.x,360)) > 0.01f || fabsf(remainderf(head.y - engine.y,360)) > 0.01f;
    }
    if (aim_session != session)
        fprintf(stderr,"[vision-aim] Head drives engine view angles for session %llu (pitch %.2f yaw %.2f, scale %.3f units/m, %s turn); physical aim unverified\n",
            (unsigned long long)session,head.x,head.y,units_per_meter,smooth_rate > 0 ? "smooth" : "snap");
    aim_session = session;
    // Tracked controller aim (aim_vision.c) uses this body and checks every
    // engine shot against the angles just written.
    p2_vision_aim_publish(session,pose->sequence,&body,head);
}
// Session over: leave the angles where the head last aimed, level roll and
// in-range pitch, so windowed stick look continues without a snap.
static void aim_release(CPU *c) {
    vector_float3 engine = {0,0,0};
    int read = aim_status > 0 && aim_read(c,&engine);
    if (read) {
        engine.x = fmaxf(-P2_XR_PITCH_LIMIT,fminf(P2_XR_PITCH_LIMIT,engine.x)); engine.z = 0;
        aim_write(c,engine);
    }
    fprintf(stderr,"[vision-aim] Released engine view angles of session %llu (pitch %.2f yaw %.2f roll 0, read=%d)\n",
        (unsigned long long)aim_session,engine.x,engine.y,read);
    aim_session = 0;
    p2_vision_aim_clear();
    snap = (P2XRSnapTurn){0};
    turn_clock = 0;
}
static void aim_poll(void) {
    P2XRFrame pose; P2XRInput controls;
    uint64_t session = p2_xr_read_latest(&pose,&controls);
    int live = session && aligned_session == session && installed && !failed;
    if (!aim_session && !live) return;
    CPU *c = rt_foreign_thread_attach();
    if (!c) return;
    if (aim_session && (failed || !p2_xr_session_active(aim_session))) { aim_release(c); return; }
    // Tracking lost or awaiting (re)alignment: keep the expectation; the
    // change is observed once tracking returns.
    if (!live) { turn_clock = 0; return; }
    rt_ios_game_state_poll();
    vector_float3 engine;
    if (rt_ios_game_ui_visible() || !aim_observe(c,session,&engine)) { turn_clock = 0; return; }
    if (aim_session == session) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC,&now);
        double seconds = (double)now.tv_sec + now.tv_nsec * 1e-9;
        float turn = smooth_rate > 0 ?
            p2_xr_smooth_turn(controls.turn_x,smooth_rate,turn_clock > 0 ? (float)(seconds - turn_clock) : 0) :
            p2_xr_snap_turn(&snap,controls.turn_x,snap_degrees);
        turn_clock = seconds;
        if (turn != 0) p2_xr_body_turn(&body,turn);
    }
    aim_drive(c,&pose,session,engine);
}
int p2_vision_view_rendering(void) { return rendering; }
int p2_vision_head_aim_active(void) {
    return aim_session && aim_session == p2_xr_read_latest(NULL,NULL);
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
    if (setup_width != width || setup_height != height || width <= 0 || height <= 0) return 0;
    // UI flag as last polled from the SDL event pump (p2_vision_input_poll and
    // aim_poll, 10 Hz). Never poll here: the poll also runs queued console
    // commands and autoexec, which must not execute inside RenderView.
    if (rt_ios_game_ui_visible() || view[32]) return 0;
    if (session && (controls.buttons & P2_XR_RECENTER) && !(previous_buttons & P2_XR_RECENTER)) aligned_session = 0;
    previous_buttons = controls.buttons;
    vector_float3 origin = {field(view,112),field(view,116),field(view,120)};
    vector_float3 angles = {field(view,124),field(view,128),field(view,132)};
    if (session) {
        // Observe before following: a crossing in this frame's simulation
        // turns the body about the old origin, then follow carries it across.
        vector_float3 engine;
        int aim = aim_observe(c,session,&engine);
        if (aligned_session != session) {
            if (p2_xr_body_align(&body,&pose,origin,aim ? engine.y : angles.y,units_per_meter)) aligned_session = session;
        } else {
            // Without head aim the engine yaw is stick-driven: follow it.
            if (aim_session != session) p2_xr_body_turn(&body,remainderf(angles.y - previous_yaw,360));
            p2_xr_body_follow(&body,origin);
        }
        previous_yaw = angles.y;
        if (aligned_session != session) return 0;
        if (aim) aim_drive(c,&pose,session,engine);
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
    matrix_float4x4 cover[2] = {matrix_identity_float4x4,matrix_identity_float4x4};
    float aspect = (float)width / (float)height;
    rendering = 1;
    for (unsigned eye = 0; eye < 2; ++eye) {
        memcpy(GPTR(eye_views[eye]),camera,sizeof(camera));
        memcpy(GPTR(eye_hud[eye]),hud,sizeof(hud));
        P2XRSourceView source = {.origin=origin,.angles=angles};
        float fov = 0;
        if (session) {
            if (!p2_xr_source_view(&pose,eye,body.source_from_tracking,&source)) goto mono;
            // CViewSetup fov is horizontal over the full width at aspect
            // width/height (93.695 logged for 90 at 4:3 on 1024x720), so a
            // symmetric frustum needs no unverified off-center fields.
            if (!p2_xr_cover_projection(source.projection,aspect,&cover[eye],&fov)) {
                static int reported;
                if (!reported++) {
                    matrix_float4x4 m = source.projection;
                    fprintf(stderr,"[vision-view] Eye %u projection rejected for cover (mono fallback): "
                        "c0=(%g,%g,%g,%g) c1=(%g,%g,%g,%g) c2=(%g,%g,%g,%g) c3=(%g,%g,%g,%g)\n",eye,
                        m.columns[0].x,m.columns[0].y,m.columns[0].z,m.columns[0].w,
                        m.columns[1].x,m.columns[1].y,m.columns[1].z,m.columns[1].w,
                        m.columns[2].x,m.columns[2].y,m.columns[2].z,m.columns[2].w,
                        m.columns[3].x,m.columns[3].y,m.columns[3].z,m.columns[3].w);
                }
                goto mono;
            }
        } else {
            float pitch=angles.x*(float)M_PI/180, yaw=angles.y*(float)M_PI/180, roll=angles.z*(float)M_PI/180;
            vector_float3 right = {-sinf(roll)*sinf(pitch)*cosf(yaw)+cosf(roll)*sinf(yaw),
                -sinf(roll)*sinf(pitch)*sinf(yaw)-cosf(roll)*cosf(yaw),-sinf(roll)*cosf(pitch)};
            source.origin += right * (eye ? 0.032f : -0.032f) * units_per_meter;
        }
        for (unsigned target = 0; target < 2; ++target) {
            uint32_t setup = target ? eye_hud[eye] : eye_views[eye];
            *(unsigned char *)GPTR(setup + 52) = 0; // the supplied pose owns the view matrix
            put_vector(setup,112,source.origin); put_vector(setup,124,source.angles);
            if (session) {
                put_float(setup,104,fov); put_float(setup,108,fov); put_float(setup,152,aspect);
                *(unsigned char *)GPTR(setup+256) &= (unsigned char)~1u; // m_bOffCenter off
                put_float(setup,136,2); put_float(setup,144,2);
            }
        }
        if (p2_vision_gl_begin_eye(eye)) goto mono;
        uint32_t args[5]; memcpy(args,original_args,sizeof(args));
        args[1] = eye_views[eye]; args[2] = eye_hud[eye];
        c->eax = rt_invoke(c,original,args,5);
        if (p2_vision_gl_end_eye(eye)) goto mono;
    }
    // Publish the projection each image was rendered with; the compositor
    // crops it with sourceProj * inverse(currentProj).
    for (unsigned eye = 0; session && eye < 2; ++eye) {
        matrix_float4x4 p = pose.eyes[eye].projection;
        vector_float3 axis = -pose.eyes[eye].head_from_eye.columns[2].xyz; // canted eyes skew the HUD
        if (stereo_frames < 3)
            fprintf(stderr,"[vision-view] Eye %u compositor tangents L=%.3f R=%.3f B=%.3f T=%.3f axis=(%.4f,%.4f,%.4f) -> symmetric fov=%.2f aspect=%.3f\n",
                eye,(p.columns[2].x - 1) / p.columns[0].x,(p.columns[2].x + 1) / p.columns[0].x,
                (p.columns[2].y - 1) / p.columns[1].y,(p.columns[2].y + 1) / p.columns[1].y,axis.x,axis.y,axis.z,
                2 * atanf(1 / cover[eye].columns[0].x) * 180 / (float)M_PI,aspect);
        pose.eyes[eye].projection = cover[eye];
    }
    // Keep the right eye current: togl's normal Present writes there after
    // the captured left image is complete. Mono fallback must restore eye 0.
    int marked = p2_vision_gl_mark_stereo(session,session ? &pose : NULL,diagnostic);
    if (!marked) goto mono;
    rendering = 0;
    if (marked && ++stereo_frames <= 3)
        fprintf(stderr,"[vision-view] Stereo pair #%u rendered: session=%llu pose=%llu diagnostic=%d head_aim=%d; physical gameplay unverified\n",
            stereo_frames,(unsigned long long)session,(unsigned long long)(session ? pose.sequence : 0),diagnostic,
            session && aim_session == session);
    return marked;
mono:
    rendering = 0;
    p2_vision_gl_begin_eye(0);
    return 0;
}

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
    if (plausible && calls == 1) {
        audit_portal_metadata(c);
        // Read-only head-aim profile check (no session needed, nothing written).
        if (enabled) aim_resolve(c);
    }
    if (plausible && render_stereo(c,args,view)) return 1;
    c->eax = rt_invoke(c, original, args, 5);
    return 1;
}
RT_SHIM_PROVIDER(audit_render)

static void read_settings(void) {
    const char *value = getenv("P2_XR_HOOK_AUDIT");
    enabled = value && !strcmp(value, "1");
    value = getenv("P2_VISION_STEREO_AUDIT");
    stereo_audit = value && !strcmp(value,"1");
    value = getenv("P2_VISION_INPUT_AUDIT");
    input_audit = TARGET_OS_SIMULATOR && value && !strcmp(value,"1");
    // Physical calibration: Source units per meter (inch-based default).
    static const struct { const char *name; float *value, low, high; } settings[] = {
        {"P2_XR_UNITS_PER_METER",&units_per_meter,10,100},
        {"P2_XR_SNAP_TURN_DEGREES",&snap_degrees,5,180},
        {"P2_XR_SMOOTH_TURN_DEGREES_PER_SECOND",&smooth_rate,0,720}, // >0 replaces snap
    };
    for (unsigned i = 0; i < sizeof(settings) / sizeof(settings[0]); ++i) {
        value = getenv(settings[i].name);
        int parsed = p2_xr_setting(value,*settings[i].value,settings[i].low,settings[i].high,settings[i].value);
        if (parsed) fprintf(stderr,"[vision-view] %s=%s %s: using %.3f\n",settings[i].name,value,
            parsed > 0 ? "accepted" : "rejected (out of range)",*settings[i].value);
    }
}

void p2_vision_view_poll(void) {
    if (enabled < 0) read_settings();
    if (!installed && !failed && (enabled || stereo_audit || input_audit || p2_xr_read_latest(NULL,NULL))) {
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
        // Pass-through until the tracked controller aims (aim_vision.c).
        p2_vision_viewmodel_install(c);
    }
    aim_poll();
}
#endif
