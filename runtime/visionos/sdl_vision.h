#pragma once
#include <SDL.h>
#include "gl_vision.h"

SDL_Window *p2_vision_create_window(const char *title, int x, int y, int w, int h, Uint32 flags);
void p2_vision_set_window_size(SDL_Window *window, int width, int height);
int p2_vision_poll_event(SDL_Event *event);

#define SDL_CreateWindow p2_vision_create_window
#define SDL_SetWindowSize p2_vision_set_window_size
#define SDL_PollEvent p2_vision_poll_event
#define SDL_GL_GetDrawableSize SDL_GetWindowSize
#define SDL_GL_DeleteContext p2_vision_gl_delete_context
#define SDL_GL_MakeCurrent p2_vision_gl_make_current
#define SDL_GL_SetSwapInterval p2_vision_gl_swap_interval
#define SDL_GL_LoadLibrary p2_vision_gl_load_library
#define SDL_GL_UnloadLibrary p2_vision_gl_unload_library
#define SDL_GL_SetAttribute p2_vision_gl_set_attribute
