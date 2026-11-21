// Offscreen native GPU check for the actual gl4es/ANGLE host path. No game.
#import <Foundation/Foundation.h>
#include <IOSurface/IOSurfaceRef.h>
#define SDL_MAIN_HANDLED
#include <SDL.h>
#include "gl_vision.h"
#include "input_vision.h"
#include "p2_xr.h"

SDL_GLContext rt_ios_gl_create_context(SDL_Window *window);
void *rt_host_gl_symbol(void *library, const char *name);
void rt_ios_gl_swap_window(SDL_Window *window);
SDL_Window *p2_vision_create_window(const char *, int, int, int, int, Uint32);
void p2_vision_set_window_size(SDL_Window *, int, int);

static int check_frame(int width, int height, const unsigned char expected[4]) {
    P2VisionGLFrame frame;
    if (!p2_vision_gl_acquire(&frame)) return 0;
    IOSurfaceRef storage = (IOSurfaceRef)frame.surface;
    IOSurfaceLock(storage,kIOSurfaceLockReadOnly,NULL);
    unsigned char pixel[4]; memcpy(pixel,IOSurfaceGetBaseAddress(storage),4);
    IOSurfaceUnlock(storage,kIOSurfaceLockReadOnly,NULL);
    p2_vision_gl_release(frame.slot);
    fprintf(stderr,"[P2-GL-PROBE] frame=%llu size=%ux%u BGRA=%u,%u,%u,%u\n",
        (unsigned long long)frame.sequence,frame.width,frame.height,pixel[0],pixel[1],pixel[2],pixel[3]);
    int valid = frame.width == (unsigned)width && frame.height == (unsigned)height &&
        frame.kind == P2_VISION_MONO && !frame.flip_left_y;
    for (int i = 0; i < 4; ++i) valid = valid && abs((int)pixel[i] - expected[i]) <= 2;
    return valid;
}
static int input_route(void) {
    if (p2_vision_input_init()) return 0;
    SDL_GameController *controller = SDL_GameControllerOpen(0);
    if (!controller) return 0;
    uint64_t session = p2_xr_begin_window_session();
    P2XRInput input = {.connected=1,.move_x=0.5f,.move_y=-0.25f,.turn_x=-0.75f,.look_y=0.5f,
        .blue_trigger=1,.orange_trigger=0.5f,.buttons=P2_XR_JUMP|P2_XR_USE};
    p2_xr_publish_input(session,&input);
    p2_vision_input_poll(); SDL_JoystickUpdate();
    fprintf(stderr,"[P2-INPUT-PROBE] axes=%d,%d triggers=%d,%d buttons=%u,%u\n",
        SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_LEFTX),
        SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_LEFTY),
        SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_TRIGGERLEFT),
        SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_TRIGGERRIGHT),
        SDL_GameControllerGetButton(controller,SDL_CONTROLLER_BUTTON_A),
        SDL_GameControllerGetButton(controller,SDL_CONTROLLER_BUTTON_X));
    int valid = abs(SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_LEFTX)-16384) <= 1 &&
        abs(SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_LEFTY)-8192) <= 1 &&
        abs(SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_RIGHTX)+24575) <= 1 &&
        abs(SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_RIGHTY)+16384) <= 1 &&
        SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_TRIGGERRIGHT) == 32767 &&
        abs(SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_TRIGGERLEFT)-16383) <= 1 &&
        SDL_GameControllerGetButton(controller,SDL_CONTROLLER_BUTTON_A) &&
        SDL_GameControllerGetButton(controller,SDL_CONTROLLER_BUTTON_X);
    input.connected = 0;
    p2_xr_publish_input(session,&input);
    p2_vision_input_poll(); SDL_JoystickUpdate();
    valid = valid && !SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_LEFTX) &&
        !SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_TRIGGERRIGHT) &&
        !SDL_GameControllerGetButton(controller,SDL_CONTROLLER_BUTTON_A);
    p2_xr_end_session(session);
    SDL_GameControllerClose(controller);
    // The real guest cycles SDL input while starting. Its shutdown invalidates
    // host joystick pointers too; polling must rebuild one usable native pad.
    SDL_QuitSubSystem(SDL_INIT_GAMECONTROLLER | SDL_INIT_JOYSTICK);
    p2_vision_input_poll();
    controller = SDL_GameControllerOpen(0);
    session = p2_xr_begin_window_session();
    input = (P2XRInput){.connected=1,.move_x=-0.5f,.buttons=P2_XR_PAUSE};
    p2_xr_publish_input(session,&input);
    p2_vision_input_poll(); SDL_JoystickUpdate();
    valid = valid && controller && SDL_NumJoysticks() == 1 &&
        abs(SDL_GameControllerGetAxis(controller,SDL_CONTROLLER_AXIS_LEFTX)+16384) <= 1 &&
        SDL_GameControllerGetButton(controller,SDL_CONTROLLER_BUTTON_START);
    p2_xr_end_session(session);
    SDL_GameControllerClose(controller);
    fprintf(stderr,"[P2-INPUT-PROBE] %s: synthetic native snapshot -> SDL gamepad, trigger polarity and disconnect release; physical controls unverified\n",valid ? "PASS" : "FAIL");
    fprintf(stderr,"[P2-INPUT-PROBE] %s: native gamepad recovers after guest SDL input subsystem shutdown\n",valid ? "PASS" : "FAIL");
    return valid;
}

static int check_captured_pair(const unsigned char expected[2][4][4]) {
    P2VisionGLFrame frame;
    if (!p2_vision_gl_acquire(&frame)) return 0;
    int paired = frame.eye_count == 2 && frame.kind == P2_VISION_DIAGNOSTIC_STEREO &&
        !frame.xr_session && !frame.render_pose.tracked && frame.surface && frame.right_surface &&
        frame.surface != frame.right_surface;
    int valid = paired && frame.flip_left_y == 1;
    for (unsigned eye=0; paired && eye<2; ++eye) {
        IOSurfaceRef surface = (IOSurfaceRef)(eye ? frame.right_surface : frame.surface);
        IOSurfaceLock(surface,kIOSurfaceLockReadOnly,NULL);
        unsigned char *base = IOSurfaceGetBaseAddress(surface);
        size_t stride = IOSurfaceGetBytesPerRow(surface);
        int corners_match = 1;
        for (unsigned corner=0; corner<4; ++corner) {
            unsigned x = corner&1 ? frame.width-1 : 0, y = corner&2 ? frame.height-1 : 0;
            unsigned char *pixel = base + y*stride + x*4;
            // The raw capture keeps GL row order for the left eye. Source's
            // later Present reverses the two rows of quadrants on the right.
            const unsigned char *color = expected[eye][eye ? corner ^ 2 : corner];
            int pixel_matches = 1;
            for (unsigned channel=0; channel<4; ++channel)
                pixel_matches = pixel_matches && abs((int)pixel[channel]-color[channel]) <= 2;
            if (!pixel_matches)
                fprintf(stderr,"[P2-GL-PROBE] eye=%u corner=%u actual=%u,%u,%u,%u expected=%u,%u,%u,%u\n",
                    eye,corner,pixel[0],pixel[1],pixel[2],pixel[3],color[0],color[1],color[2],color[3]);
            corners_match = corners_match && pixel_matches;
        }
        fprintf(stderr,"[P2-GL-PROBE] captured eye=%u row0 BGRA=%u,%u,%u,%u flip_left_y=%u corners=%s\n",
            eye,base[0],base[1],base[2],base[3],frame.flip_left_y,corners_match ? "PASS" : "FAIL");
        valid = valid && corners_match;
        IOSurfaceUnlock(surface,kIOSurfaceLockReadOnly,NULL);
    }
    p2_vision_gl_release(frame.slot);
    return valid;
}

static int owned_target(SDL_Window *window,SDL_GLContext context) {
    void (*gen_fb)(int,unsigned *) = rt_host_gl_symbol(NULL,"glGenFramebuffers");
    void (*bind_fb)(unsigned,unsigned) = rt_host_gl_symbol(NULL,"glBindFramebuffer");
    void (*delete_fb)(int,const unsigned *) = rt_host_gl_symbol(NULL,"glDeleteFramebuffers");
    void (*gen_tex)(int,unsigned *) = rt_host_gl_symbol(NULL,"glGenTextures");
    void (*bind_tex)(unsigned,unsigned) = rt_host_gl_symbol(NULL,"glBindTexture");
    void (*delete_tex)(int,const unsigned *) = rt_host_gl_symbol(NULL,"glDeleteTextures");
    void (*image)(unsigned,int,int,int,int,int,unsigned,unsigned,const void *) = rt_host_gl_symbol(NULL,"glTexImage2D");
    void (*parameter)(unsigned,unsigned,int) = rt_host_gl_symbol(NULL,"glTexParameteri");
    void (*attach)(unsigned,unsigned,unsigned,unsigned,int) = rt_host_gl_symbol(NULL,"glFramebufferTexture2D");
    unsigned (*status)(unsigned) = rt_host_gl_symbol(NULL,"glCheckFramebufferStatus");
    void (*clear_color)(float,float,float,float) = rt_host_gl_symbol(NULL,"glClearColor");
    void (*clear)(unsigned) = rt_host_gl_symbol(NULL,"glClear");
    void (*enable)(unsigned) = rt_host_gl_symbol(NULL,"glEnable");
    void (*disable)(unsigned) = rt_host_gl_symbol(NULL,"glDisable");
    unsigned char (*is_enabled)(unsigned) = rt_host_gl_symbol(NULL,"glIsEnabled");
    void (*scissor)(int,int,int,int) = rt_host_gl_symbol(NULL,"glScissor");
    void (*blit)(int,int,int,int,int,int,int,int,unsigned,unsigned) = rt_host_gl_symbol(NULL,"glBlitFramebuffer");
    if (!gen_fb || !bind_fb || !delete_fb || !gen_tex || !bind_tex || !delete_tex || !image ||
        !parameter || !attach || !status || !clear_color || !clear || !enable || !disable ||
        !is_enabled || !scissor || !blit) return 0;
    unsigned framebuffer=0,texture=0;
    gen_tex(1,&texture); bind_tex(0x0de1,texture);
    parameter(0x0de1,0x2801,0x2600); parameter(0x0de1,0x2800,0x2600);
    image(0x0de1,0,0x1908,160,120,0,0x1908,0x1401,NULL);
    gen_fb(1,&framebuffer); bind_fb(0x8d40,framebuffer);
    attach(0x8d40,0x8ce0,0x0de1,texture,0);
    const unsigned char expected[2][4][4] = {
        {{0,0,255,255},{0,255,0,255},{255,0,0,255},{255,255,255,255}},
        {{255,255,0,255},{255,0,255,255},{0,255,255,255},{0,0,0,255}},
    };
    int valid = status(0x8d40) == 0x8cd5;
    for (unsigned eye=0; valid && eye<2; ++eye) {
        valid = !p2_vision_gl_begin_eye(eye);
        bind_fb(0x8d40,framebuffer);
        enable(0x0c11);
        for (unsigned corner=0; corner<4; ++corner) {
            const unsigned char *color = expected[eye][corner];
            scissor(corner&1 ? 80 : 0,corner&2 ? 60 : 0,80,60);
            clear_color(color[2]/255.0f,color[1]/255.0f,color[0]/255.0f,1);
            clear(0x4000);
        }
        // A tiny scissor must not crop the full eye capture. Its enabled
        // state must survive so gl4es/togl state caches remain correct.
        scissor(8,9,20,21);
        valid = !p2_vision_gl_end_eye(eye) && is_enabled(0x0c11) && valid;
    }
    disable(0x0c11);
    // togl Present reverses destination Y when it blits to its default FBO.
    bind_fb(0x8ca8,framebuffer); bind_fb(0x8ca9,0);
    // The first standalone blit also primes gl4es's default-FBO dimensions.
    blit(0,0,160,120,0,120,160,0,0x4000,0x2600);
    blit(0,0,160,120,0,120,160,0,0x4000,0x2600);
    valid = p2_vision_gl_mark_stereo(0,NULL,1) && valid;
    rt_ios_gl_swap_window(window);
    valid = check_captured_pair(expected) && valid;
    bind_fb(0x8d40,0); delete_fb(1,&framebuffer); bind_tex(0x0de1,0); delete_tex(1,&texture);
    P2VisionGLFrame before,after;
    if (p2_vision_gl_acquire(&before)) p2_vision_gl_release(before.slot); else return 0;
    valid = !p2_vision_gl_make_current(window,NULL) && valid;
    valid = p2_vision_gl_capture_target(0) == -1 && valid;
    p2_vision_gl_present();
    if (p2_vision_gl_acquire(&after)) {
        valid = after.sequence == before.sequence && valid;
        p2_vision_gl_release(after.slot);
    } else valid = 0;
    valid = !p2_vision_gl_make_current(window,context) && valid;
    fprintf(stderr,"[P2-GL-PROBE] %s: engine-owned FBO capture, scissor restoration, Present parity and missing-context rejection\n",valid ? "PASS" : "FAIL");
    return valid;
}

// Middle row of the newest mono frame at NDC x = -0.75, -0.25, 0.25, 0.75:
// 1 for the white quad, 0 for the black clear, -1 for anything else.
static int lit_columns(int lit[4]) {
    P2VisionGLFrame frame;
    if (!p2_vision_gl_acquire(&frame)) return 0;
    IOSurfaceRef storage = (IOSurfaceRef)frame.surface;
    IOSurfaceLock(storage,kIOSurfaceLockReadOnly,NULL);
    unsigned char *base = IOSurfaceGetBaseAddress(storage);
    unsigned char *row = base + IOSurfaceGetBytesPerRow(storage) * (frame.height / 2);
    for (unsigned i = 0; i < 4; ++i) {
        unsigned char green = row[(frame.width * (2 * i + 1) / 8) * 4 + 1];
        lit[i] = green >= 253 ? 1 : green <= 2 ? 0 : -1;
    }
    IOSurfaceUnlock(storage,kIOSurfaceLockReadOnly,NULL);
    p2_vision_gl_release(frame.slot);
    return frame.kind == P2_VISION_MONO;
}

// togl clips the view through a portal at the linked portal's plane: a user
// clip plane on programs whose vertex shader writes gl_ClipVertex. GLES has
// neither, so gl4es must discard the far side itself. The two directions of
// one link clip at planes facing opposite ways. Each must hide only what is
// behind its own exit, and nothing once the plane is disabled again.
static int clip_plane_sides(SDL_Window *window) {
    unsigned (*create_shader)(unsigned) = rt_host_gl_symbol(NULL,"glCreateShader");
    void (*shader_source)(unsigned,int,const char *const *,const int *) = rt_host_gl_symbol(NULL,"glShaderSource");
    void (*kept_source)(unsigned,int,int *,char *) = rt_host_gl_symbol(NULL,"glGetShaderSource");
    void (*compile)(unsigned) = rt_host_gl_symbol(NULL,"glCompileShader");
    unsigned (*create_program)(void) = rt_host_gl_symbol(NULL,"glCreateProgram");
    void (*attach)(unsigned,unsigned) = rt_host_gl_symbol(NULL,"glAttachShader");
    void (*bind_attribute)(unsigned,unsigned,const char *) = rt_host_gl_symbol(NULL,"glBindAttribLocation");
    void (*link)(unsigned) = rt_host_gl_symbol(NULL,"glLinkProgram");
    void (*program_status)(unsigned,unsigned,int *) = rt_host_gl_symbol(NULL,"glGetProgramiv");
    void (*use)(unsigned) = rt_host_gl_symbol(NULL,"glUseProgram");
    void (*delete_program)(unsigned) = rt_host_gl_symbol(NULL,"glDeleteProgram");
    void (*delete_shader)(unsigned) = rt_host_gl_symbol(NULL,"glDeleteShader");
    void (*gen_buffers)(int,unsigned *) = rt_host_gl_symbol(NULL,"glGenBuffers");
    void (*bind_buffer)(unsigned,unsigned) = rt_host_gl_symbol(NULL,"glBindBuffer");
    void (*buffer_data)(unsigned,long,const void *,unsigned) = rt_host_gl_symbol(NULL,"glBufferData");
    void (*delete_buffers)(int,const unsigned *) = rt_host_gl_symbol(NULL,"glDeleteBuffers");
    void (*attribute)(unsigned,int,unsigned,unsigned char,int,const void *) = rt_host_gl_symbol(NULL,"glVertexAttribPointer");
    void (*enable_attribute)(unsigned) = rt_host_gl_symbol(NULL,"glEnableVertexAttribArray");
    void (*disable_attribute)(unsigned) = rt_host_gl_symbol(NULL,"glDisableVertexAttribArray");
    void (*clip_plane)(unsigned,const double *) = rt_host_gl_symbol(NULL,"glClipPlane");
    void (*enable)(unsigned) = rt_host_gl_symbol(NULL,"glEnable");
    void (*disable)(unsigned) = rt_host_gl_symbol(NULL,"glDisable");
    void (*viewport)(int,int,int,int) = rt_host_gl_symbol(NULL,"glViewport");
    void (*clear_color)(float,float,float,float) = rt_host_gl_symbol(NULL,"glClearColor");
    void (*clear)(unsigned) = rt_host_gl_symbol(NULL,"glClear");
    void (*draw)(unsigned,int,int) = rt_host_gl_symbol(NULL,"glDrawArrays");
    if (!create_shader || !shader_source || !kept_source || !compile || !create_program || !attach ||
        !bind_attribute || !link || !program_status || !use || !delete_program || !delete_shader ||
        !gen_buffers || !bind_buffer || !buffer_data || !delete_buffers || !attribute || !enable_attribute ||
        !disable_attribute || !clip_plane || !enable || !disable || !viewport || !clear_color || !clear || !draw) {
        fprintf(stderr,"[P2-GL-PROBE] FAIL: gl4es lacks an entry point of the user clip plane check\n");
        return 0;
    }
    // The shape of togl's translated shaders: explicitly bound vN attributes,
    // gl_ClipVertex taken from the position before any fixup.
    const char *vertex_text = "#version 120\nattribute vec4 v0;\nvoid main()\n{\nvec4 vTempPos = v0;\n"
        "gl_ClipVertex = vTempPos;\ngl_Position = vTempPos;\n}\n";
    const char *fragment_text = "#version 120\nvoid main()\n{\ngl_FragColor = vec4(1.0, 1.0, 1.0, 1.0);\n}\n";
    unsigned vertex = create_shader(0x8b31), fragment = create_shader(0x8b30), program = create_program();
    shader_source(vertex,1,&vertex_text,NULL); compile(vertex);
    shader_source(fragment,1,&fragment_text,NULL); compile(fragment);
    attach(program,vertex); attach(program,fragment);
    bind_attribute(program,0,"v0");
    link(program);
    int linked = 0;
    program_status(program,0x8b82,&linked);
    // The gl4es patch (realize_glenv) reads this kept text to decide which
    // programs a clip plane applies to.
    char kept[4096] = {0};
    kept_source(vertex,sizeof(kept),NULL,kept);
    fprintf(stderr,"[P2-GL-PROBE] gl4es keeps the vertex source with gl_ClipVertex=%d gl4es_ClipVertex=%d linked=%d\n",
        strstr(kept,"gl_ClipVertex") != NULL,strstr(kept,"gl4es_ClipVertex") != NULL,linked);
    const float quad[] = {-1,-1, 1,-1, -1,1, 1,1};
    unsigned buffer = 0;
    gen_buffers(1,&buffer); bind_buffer(0x8892,buffer);
    buffer_data(0x8892,sizeof(quad),quad,0x88e4);
    use(program);
    attribute(0,2,0x1406,0,0,NULL); enable_attribute(0);
    int width = 0, height = 0;
    p2_vision_gl_drawable_size(&width,&height);
    viewport(0,0,width,height);
    // GL keeps dot(plane, gl_ClipVertex) >= 0: x >= -0.5 one way, x <= 0.5 the other.
    static const struct { const char *view; double plane[4]; int lit[4]; } cases[] = {
        {"no clip plane",{0,0,0,0},{1,1,1,1}},
        {"blue to orange",{1,0,0,0.5},{0,1,1,1}},
        {"orange to blue",{-1,0,0,0.5},{1,1,1,0}},
        {"clip plane disabled again",{0,0,0,0},{1,1,1,1}},
    };
    int valid = linked != 0;
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        int clipped = cases[i].plane[0] != 0, lit[4] = {-1,-1,-1,-1};
        if (clipped) { clip_plane(0x3000,cases[i].plane); enable(0x3000); }
        clear_color(0,0,0,1); clear(0x4000);
        draw(0x0005,0,4);
        if (clipped) disable(0x3000);
        rt_ios_gl_swap_window(window);
        int matches = lit_columns(lit) && !memcmp(lit,cases[i].lit,sizeof(lit));
        fprintf(stderr,"[P2-GL-PROBE] %s: lit at x=-0.75,-0.25,0.25,0.75 is %d,%d,%d,%d, expected %d,%d,%d,%d\n",
            cases[i].view,lit[0],lit[1],lit[2],lit[3],
            cases[i].lit[0],cases[i].lit[1],cases[i].lit[2],cases[i].lit[3]);
        valid = valid && matches;
    }
    disable_attribute(0); use(0); bind_buffer(0x8892,0);
    delete_buffers(1,&buffer); delete_program(program); delete_shader(vertex); delete_shader(fragment);
    fprintf(stderr,"[P2-GL-PROBE] %s: a gl_ClipVertex clip plane hides only its own far side, for both directions of a portal link\n",valid ? "PASS" : "FAIL");
    return valid;
}

int main(void) {
    @autoreleasepool {
        setenv("SDL_VIDEODRIVER", "dummy", 1);
        SDL_SetMainReady();
        if (SDL_Init(SDL_INIT_VIDEO)) { fprintf(stderr, "SDL init: %s\n", SDL_GetError()); return 1; }
        if (p2_vision_gl_load_library(NULL)) return 6;
        if (p2_vision_gl_set_attribute(SDL_GL_RED_SIZE,8) ||
            p2_vision_gl_set_attribute(SDL_GL_DEPTH_SIZE,24) ||
            p2_vision_gl_set_attribute(SDL_GL_STENCIL_SIZE,8) ||
            !p2_vision_gl_set_attribute(SDL_GL_MULTISAMPLESAMPLES,16)) return 7;
        SDL_Window *window = p2_vision_create_window("GL probe", 0, 0, 128, 96, SDL_WINDOW_OPENGL);
        if (!window || SDL_GetKeyboardFocus() != window ||
            !(SDL_GetWindowFlags(window) & SDL_WINDOW_INPUT_FOCUS)) {
            fprintf(stderr,"[P2-INPUT-PROBE] FAIL: engine bookkeeping window lacks input focus\n");
            return 8;
        }
        SDL_GLContext context = window ? rt_ios_gl_create_context(window) : NULL;
        if (!context) { fprintf(stderr, "GL context: %s\n", SDL_GetError()); return 2; }
        void (*clear_color)(float,float,float,float) = rt_host_gl_symbol(NULL, "glClearColor");
        void (*clear)(unsigned) = rt_host_gl_symbol(NULL, "glClear");
        if (!clear_color || !clear) return 3;
        clear_color(0.25f, 0.5f, 0.75f, 1);
        clear(0x4000); // GL_COLOR_BUFFER_BIT
        rt_ios_gl_swap_window(window);
        const unsigned char first[4] = {191,128,64,255}, resized[4] = {128,64,191,255};
        int valid = check_frame(128,96,first);
        p2_vision_set_window_size(window,160,120);
        P2VisionGLFrame old;
        if (p2_vision_gl_acquire(&old)) { valid = 0; p2_vision_gl_release(old.slot); }
        clear_color(0.75f,0.25f,0.5f,1);
        clear(0x4000);
        rt_ios_gl_swap_window(window);
        valid = check_frame(160,120,resized) && valid;
        // GL's bottom half is red, top half blue. Read physical IOSurface
        // rows to audit the Metal sampler orientation before displaying games.
        void (*enable)(unsigned) = rt_host_gl_symbol(NULL,"glEnable");
        void (*disable)(unsigned) = rt_host_gl_symbol(NULL,"glDisable");
        void (*scissor)(int,int,int,int) = rt_host_gl_symbol(NULL,"glScissor");
        clear_color(0,0,1,1); clear(0x4000);
        enable(0x0c11); scissor(0,0,160,60);
        clear_color(1,0,0,1); clear(0x4000); disable(0x0c11);
        rt_ios_gl_swap_window(window);
        P2VisionGLFrame oriented;
        if (p2_vision_gl_acquire(&oriented)) {
            IOSurfaceRef storage = (IOSurfaceRef)oriented.surface;
            IOSurfaceLock(storage,kIOSurfaceLockReadOnly,NULL);
            unsigned char *first = IOSurfaceGetBaseAddress(storage);
            unsigned char *last = first + IOSurfaceGetBytesPerRow(storage) * (oriented.height - 1);
            fprintf(stderr,"[P2-GL-PROBE] GL bottom=red top=blue; IOSurface row0 BGRA=%u,%u,%u,%u last=%u,%u,%u,%u\n",
                first[0],first[1],first[2],first[3],last[0],last[1],last[2],last[3]);
            const unsigned char bottom[4] = {0,0,255,255}, top[4] = {255,0,0,255};
            valid = valid && !oriented.flip_left_y && !memcmp(first,bottom,4) && !memcmp(last,top,4);
            IOSurfaceUnlock(storage,kIOSurfaceLockReadOnly,NULL);
            p2_vision_gl_release(oriented.slot);
        } else valid = 0;
        valid = owned_target(window,context) && valid;
        // Direct default-FBO eyes do not need the FBO capture correction.
        // Run after the captured pair to catch stale orientation metadata.
        valid = !p2_vision_gl_begin_eye(0) && valid;
        clear_color(0.2f,0.4f,0.6f,1); clear(0x4000);
        valid = !p2_vision_gl_end_eye(0) && valid;
        valid = !p2_vision_gl_begin_eye(1) && valid;
        clear_color(0.8f,0.6f,0.4f,1); clear(0x4000);
        valid = !p2_vision_gl_end_eye(1) && valid;
        valid = p2_vision_gl_mark_stereo(0,NULL,1) && valid;
        rt_ios_gl_swap_window(window);
        P2VisionGLFrame pair;
        if (p2_vision_gl_acquire(&pair)) {
            IOSurfaceRef left = (IOSurfaceRef)pair.surface, right = (IOSurfaceRef)pair.right_surface;
            IOSurfaceLock(left,kIOSurfaceLockReadOnly,NULL); IOSurfaceLock(right,kIOSurfaceLockReadOnly,NULL);
            unsigned char *l = IOSurfaceGetBaseAddress(left), *r = IOSurfaceGetBaseAddress(right);
            valid = valid && pair.eye_count == 2 && pair.kind == P2_VISION_DIAGNOSTIC_STEREO &&
                !pair.xr_session && !pair.render_pose.tracked && !pair.flip_left_y && left != right &&
                abs((int)l[0]-153)<=2 && abs((int)l[2]-51)<=2 && abs((int)r[0]-102)<=2 && abs((int)r[2]-204)<=2;
            fprintf(stderr,"[P2-GL-PROBE] paired left BGRA=%u,%u,%u right=%u,%u,%u eyes=%u kind=%u tracked=%u\n",
                l[0],l[1],l[2],r[0],r[1],r[2],pair.eye_count,pair.kind,pair.render_pose.tracked);
            IOSurfaceUnlock(left,kIOSurfaceLockReadOnly,NULL); IOSurfaceUnlock(right,kIOSurfaceLockReadOnly,NULL);
            p2_vision_gl_release(pair.slot);
        } else valid = 0;
        valid = clip_plane_sides(window) && valid;
        clear_color(0.75f,0.25f,0.5f,1); clear(0x4000);
        rt_ios_gl_swap_window(window);
        valid = check_frame(160,120,resized) && valid;
        p2_vision_gl_delete_context(context);
        valid = input_route() && valid;
        SDL_DestroyWindow(window); SDL_Quit();
        fprintf(stderr, "[P2-GL-PROBE] %s: gl4es -> ANGLE Metal -> leased IOSurface; resize preserves context and retires old storage\n", valid ? "PASS" : "FAIL");
        return valid ? 0 : 5;
    }
}
