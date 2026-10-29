#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include <SDL.h>
#include <stdio.h>
#include "gl_vision.h"
#if P2_VISION_GAME
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
    return SDL_CreateWindow(title, x, y, w, h, flags | SDL_WINDOW_HIDDEN);
}
void p2_vision_set_window_size(SDL_Window *window, int width, int height) {
    if (!p2_vision_gl_resize(width,height)) SDL_SetWindowSize(window,width,height);
}
int p2_vision_poll_event(SDL_Event *event) {
#if P2_VISION_GAME
    p2_vision_view_poll();
    p2_vision_input_poll();
#endif
    return SDL_PollEvent(event);
}
#endif
