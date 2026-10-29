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
    int valid = frame.width == (unsigned)width && frame.height == (unsigned)height;
    for (int i = 0; i < 4; ++i) valid = valid && abs((int)pixel[i] - expected[i]) <= 2;
    return valid;
}
static int input_route(void) {
    if (p2_vision_input_init()) return 0;
    SDL_GameController *controller = SDL_GameControllerOpen(0);
    if (!controller) return 0;
    uint64_t session = p2_xr_begin_window_session();
    P2XRInput input = {.connected=1,.move_x=0.5f,.move_y=-0.25f,
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
    fprintf(stderr,"[P2-INPUT-PROBE] %s: synthetic native snapshot -> SDL gamepad, trigger polarity and disconnect release; physical controls unverified\n",valid ? "PASS" : "FAIL");
    return valid;
}

int main(void) {
    @autoreleasepool {
        setenv("SDL_VIDEODRIVER", "dummy", 1);
        SDL_SetMainReady();
        if (SDL_Init(SDL_INIT_VIDEO)) { fprintf(stderr, "SDL init: %s\n", SDL_GetError()); return 1; }
        if (p2_vision_gl_load_library(NULL)) return 6;
        SDL_Window *window = p2_vision_create_window("GL probe", 0, 0, 128, 96, SDL_WINDOW_OPENGL);
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
            valid = valid && first[3] == 255 && last[3] == 255 && first[0] != last[0] && first[2] != last[2];
            IOSurfaceUnlock(storage,kIOSurfaceLockReadOnly,NULL);
            p2_vision_gl_release(oriented.slot);
        } else valid = 0;
        p2_vision_gl_delete_context(context);
        valid = input_route() && valid;
        SDL_DestroyWindow(window); SDL_Quit();
        fprintf(stderr, "[P2-GL-PROBE] %s: gl4es -> ANGLE Metal -> leased IOSurface; resize preserves context and retires old storage\n", valid ? "PASS" : "FAIL");
        return valid ? 0 : 5;
    }
}
