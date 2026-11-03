#pragma once
#include <SDL.h>
#include "gl_vision.h"

SDL_Window *p2_vision_create_window(const char *title, int x, int y, int w, int h, Uint32 flags);
void p2_vision_set_window_size(SDL_Window *window, int width, int height);
int p2_vision_poll_event(SDL_Event *event);
// SDL's dummy video driver reports one fixed 1024x768 display, and the engine
// keeps windowed modes inside the desktop (-w 1280 -h 720 became 1024x720).
// The guest sees one larger virtual display instead (sdl_vision.c), so the
// 16:9 window and the near-square immersive eye size are both accepted.
int p2_vision_get_desktop_display_mode(int display, SDL_DisplayMode *mode);
int p2_vision_get_current_display_mode(int display, SDL_DisplayMode *mode);
int p2_vision_get_window_display_mode(SDL_Window *window, SDL_DisplayMode *mode);
int p2_vision_get_display_bounds(int display, SDL_Rect *rect);
int p2_vision_get_display_usable_bounds(int display, SDL_Rect *rect);

#define SDL_CreateWindow p2_vision_create_window
#define SDL_SetWindowSize p2_vision_set_window_size
#define SDL_PollEvent p2_vision_poll_event
#define SDL_GetDesktopDisplayMode p2_vision_get_desktop_display_mode
#define SDL_GetCurrentDisplayMode p2_vision_get_current_display_mode
#define SDL_GetWindowDisplayMode p2_vision_get_window_display_mode
#define SDL_GetDisplayBounds p2_vision_get_display_bounds
#define SDL_GetDisplayUsableBounds p2_vision_get_display_usable_bounds
#define SDL_GL_GetDrawableSize SDL_GetWindowSize
#define SDL_GL_DeleteContext p2_vision_gl_delete_context
#define SDL_GL_MakeCurrent p2_vision_gl_make_current
#define SDL_GL_SetSwapInterval p2_vision_gl_swap_interval
#define SDL_GL_LoadLibrary p2_vision_gl_load_library
#define SDL_GL_UnloadLibrary p2_vision_gl_unload_library
#define SDL_GL_SetAttribute p2_vision_gl_set_attribute
