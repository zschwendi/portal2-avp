#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include <SDL.h>
#include <stdio.h>
#include "gl_vision.h"
#if P2_VISION_GAME
#include "game_vision.h"
#include "view_vision.h"
#include "input_vision.h"
#endif

// Normally supplied by SDL's UIKit video driver, which this port does not
// build. A visionOS host is not an iPad.
SDL_bool SDL_IsIPad(void) { return SDL_FALSE; }

SDL_Window *p2_vision_create_window(const char *title, int x, int y, int w, int h, Uint32 flags) {
    // This is a host-side SDL bookkeeping object, not a UIKit window. Its GL
    // context/presentation are supplied by gl_vision.m, not a dummy GL driver.
    flags &= ~(SDL_WINDOW_OPENGL | SDL_WINDOW_VULKAN | SDL_WINDOW_METAL |
               SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_FULLSCREEN_DESKTOP);
    SDL_Window *window = SDL_CreateWindow(title, x, y, w, h, flags);
    if (window) fprintf(stderr,"[vision-window] SDL bookkeeping flags=%#x keyboard_focus=%d (native UI owned by SwiftUI)\n",
        SDL_GetWindowFlags(window),SDL_GetKeyboardFocus() == window);
    return window;
}
void p2_vision_set_window_size(SDL_Window *window, int width, int height) {
    if (!p2_vision_gl_resize(width,height)) SDL_SetWindowSize(window,width,height);
}

// ---- Virtual display ------------------------------------------------------
// One display larger than any size requested here (windowed 1280x720, eye
// sizes clamped to 2048 by the renderer). There is no physical desktop on
// visionOS; SwiftUI and CompositorServices scale the engine image.
enum { DESKTOP_WIDTH = 2560, DESKTOP_HEIGHT = 2560 };
static void virtual_mode(SDL_DisplayMode *mode) {
    static int logged;
    if (!logged++) fprintf(stderr,"[vision-window] Virtual display %dx%d (SDL dummy reports %dx%d)\n",
        DESKTOP_WIDTH,DESKTOP_HEIGHT,mode->w,mode->h);
    mode->w = DESKTOP_WIDTH; mode->h = DESKTOP_HEIGHT;
}
int p2_vision_get_desktop_display_mode(int display, SDL_DisplayMode *mode) {
    int result = SDL_GetDesktopDisplayMode(display,mode);
    if (!result && mode) virtual_mode(mode);
    return result;
}
int p2_vision_get_current_display_mode(int display, SDL_DisplayMode *mode) {
    int result = SDL_GetCurrentDisplayMode(display,mode);
    if (!result && mode) virtual_mode(mode);
    return result;
}
// SDL answers with the closest display mode at least the window's size; the
// virtual display has one mode, so that is it whenever the window fits.
int p2_vision_get_window_display_mode(SDL_Window *window, SDL_DisplayMode *mode) {
    if (!mode) return SDL_GetWindowDisplayMode(window,mode);
    int w = 0, h = 0;
    SDL_GetWindowSize(window,&w,&h);
    if (w > DESKTOP_WIDTH || h > DESKTOP_HEIGHT) return SDL_SetError("Couldn't find display mode match");
    int index = SDL_GetWindowDisplayIndex(window);
    int result = SDL_GetDesktopDisplayMode(index < 0 ? 0 : index,mode);
    if (!result) virtual_mode(mode);
    return result;
}
int p2_vision_get_display_bounds(int display, SDL_Rect *rect) {
    int result = SDL_GetDisplayBounds(display,rect);
    if (!result && rect) { rect->w = DESKTOP_WIDTH; rect->h = DESKTOP_HEIGHT; }
    return result;
}
int p2_vision_get_display_usable_bounds(int display, SDL_Rect *rect) {
    int result = SDL_GetDisplayUsableBounds(display,rect);
    if (!result && rect) { rect->w = DESKTOP_WIDTH; rect->h = DESKTOP_HEIGHT; }
    return result;
}

#if P2_VISION_GAME
// ---- Immersive eye render size -----------------------------------------------
// The immersive renderer asks for a near-square per-eye size while it owns the
// engine frames (game_vision.m); the windowed size returns when it lets go.
// engine.so `mat_setvideomode` (ArgC >= 4) calls IVideoMode::SetMode(w, h,
// windowed, current no-border); a windowed size missing from the mode list is
// used as given. The engine resizes its own window through SDL_SetWindowSize
// -> p2_vision_gl_resize, which swaps the IOSurface pool only after every
// compositor lease has retired. Engine render targets follow its mode.
//
// Changes run only here: the top of the engine's event pump, on the thread
// that owns the producer GL context, never inside RenderView. The eye size is
// applied only during steady tracked stereo gameplay (no menu, pause or
// loading screen renders stereo); the windowed size returns after a steady
// run of presents. A size that does not take is not retried in that session;
// immersive keeps the 16:9 cover crop (fail safe).
int rt_ios_console_command_now(const char *line);   // runtime/ios/game_state.c
// The windowed restore needs a longer steady run (~1.5 s): loading-screen
// refreshes are not steady that long, so no mode change lands mid-load.
enum { MODE_STEADY_FRAMES = 12, MODE_RESTORE_FRAMES = 90, MODE_POLL_MS = 100, MODE_SETTLE_MS = 3000,
       MODE_RETRY_MS = 2000, MODE_RESTORE_TRIES = 3 };
int p2_vision_view_rendering(void);   // view_vision.c: inside the stereo RenderView pair
static struct {
    int windowed_w, windowed_h;  // the player's windowed size, to restore
    int target_w, target_h;      // size last commanded
    int failed_w, failed_h;      // eye size that did not take (this session)
    int changed;                 // we moved the engine away from windowed_w x h
    int pending, busy, restore_tries;
    uint64_t next_ms, deadline_ms;
} mode;

static int mode_steady(uint64_t now, int stereo, int frames) {
    P2VisionGLCadence cadence;
    p2_vision_gl_cadence(&cadence);
    return cadence.last_ms && now - cadence.last_ms <= MODE_POLL_MS && cadence.steady >= (unsigned)frames &&
        (!stereo || cadence.stereo >= (unsigned)frames);
}
static void mode_command(int width, int height, uint64_t now, const char *why) {
    char line[64];
    snprintf(line,sizeof(line),"mat_setvideomode %d %d 1",width,height);
    int w = 0, h = 0;
    p2_vision_gl_drawable_size(&w,&h);
    fprintf(stderr,"[vision-mode] %s: engine %dx%d -> %dx%d\n",why,w,h,width,height);
    mode.target_w = width; mode.target_h = height;
    mode.pending = 1;
    mode.busy = 1;  // SetMode may pump events itself
    int issued = rt_ios_console_command_now(line);
    mode.busy = 0;
    mode.deadline_ms = issued ? now + MODE_SETTLE_MS : now;
}
static void manage_video_mode(void) {
    if (mode.busy || p2_vision_view_rendering()) return;
    uint64_t now = SDL_GetTicks64();
    if (now < mode.next_ms) return;
    int w = 0, h = 0, eye_w = 0, eye_h = 0;
    p2_vision_requested_eye_size(&eye_w,&eye_h);
    if (!p2_vision_gl_on_producer_thread()) {
        static int reported;
        if (eye_w > 0 && !reported++)
            fprintf(stderr,"[vision-mode] Event pump without the producer GL context; mode changes wait for the render thread\n");
        return;
    }
    mode.next_ms = now + MODE_POLL_MS;
    p2_vision_gl_drawable_size(&w,&h);
    if (w <= 0 || h <= 0) return;
    int restoring_target = mode.target_w == mode.windowed_w && mode.target_h == mode.windowed_h;
    if (mode.pending) {
        if (w == mode.target_w && h == mode.target_h) {
            mode.pending = 0;
            if (restoring_target) { mode.changed = 0; mode.restore_tries = 0; }
            p2_vision_set_eye_mode(!restoring_target);
            fprintf(stderr,"[vision-mode] Engine renders %dx%d (%s)\n",w,h,restoring_target ? "windowed" : "immersive eye size");
            return;
        }
        if (now < mode.deadline_ms) return;
        mode.pending = 0;
        mode.next_ms = now + MODE_RETRY_MS;
        int at_windowed = w == mode.windowed_w && h == mode.windowed_h;
        fprintf(stderr,"[vision-mode] mat_setvideomode %dx%d did not take; engine stays %dx%d\n",
            mode.target_w,mode.target_h,w,h);
        if (!restoring_target) {
            // Not retried this session. Re-apply the windowed mode once, in
            // case the engine changed its mode but the surfaces did not follow.
            mode.failed_w = mode.target_w; mode.failed_h = mode.target_h;
            mode.changed = 1;
            mode.restore_tries = 0;
            p2_vision_set_eye_mode(!at_windowed);
            if (at_windowed) mode_command(mode.windowed_w,mode.windowed_h,now,"Re-applying the windowed size");
        } else if (++mode.restore_tries >= MODE_RESTORE_TRIES) {
            fprintf(stderr,"[vision-mode] Keeping %dx%d as the windowed size; the window follows its aspect\n",w,h);
            mode.windowed_w = w; mode.windowed_h = h;
            mode.changed = 0; mode.restore_tries = 0;
            p2_vision_set_eye_mode(0);
        }
        return;
    }
    if (!mode.changed) { mode.windowed_w = w; mode.windowed_h = h; }
    if (eye_w > 0 && eye_h > 0) {
        if ((w == eye_w && h == eye_h) || (eye_w == mode.failed_w && eye_h == mode.failed_h)) return;
        if (!mode_steady(now,1,MODE_STEADY_FRAMES)) return;
        mode.changed = 1;
        p2_vision_set_eye_mode(1);  // before the switch: the window must not adopt eye frames
        mode_command(eye_w,eye_h,now,"Immersive eye size");
        return;
    }
    mode.failed_w = mode.failed_h = 0;  // the next immersive session tries again
    if (!mode.changed) return;
    if (w == mode.windowed_w && h == mode.windowed_h) {
        mode.changed = 0; mode.restore_tries = 0;
        p2_vision_set_eye_mode(0);
        return;
    }
    if (!mode_steady(now,0,MODE_RESTORE_FRAMES)) return;
    mode_command(mode.windowed_w,mode.windowed_h,now,"Windowed size");
}
#endif

int p2_vision_poll_event(SDL_Event *event) {
#if P2_VISION_GAME
    p2_vision_view_poll();
    p2_vision_input_poll();
    manage_video_mode();
#endif
    return SDL_PollEvent(event);
}
#endif
