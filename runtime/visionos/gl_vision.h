#pragma once
#include <stdint.h>
#include <SDL.h>
#include "p2_vision_frame.h"

// ANGLE and SDL APIs below are used only by the visionOS guest worker.
void *p2_vision_gles_library(void);
int p2_vision_gl_load_library(const char *path);
void p2_vision_gl_unload_library(void);
int p2_vision_gl_set_attribute(SDL_GLattr attribute, int value);
int p2_vision_gl_resize(int width, int height);
void p2_vision_gl_drawable_size(int *width, int *height);
SDL_GLContext p2_vision_gl_create_context(int width, int height);
void *p2_vision_gl_current_context(void);
void *p2_vision_gl_share_group(void *context);
int p2_vision_gl_make_current(SDL_Window *window, SDL_GLContext context);
void p2_vision_gl_delete_context(SDL_GLContext context);
int p2_vision_gl_swap_interval(int interval);
void p2_vision_gl_present(void);
int p2_vision_gl_select_eye(uint32_t eye);
int p2_vision_gl_begin_eye(uint32_t eye);
int p2_vision_gl_end_eye(uint32_t eye);
int p2_vision_gl_capture_target(uint32_t eye);
int p2_vision_gl_mark_stereo(uint64_t session, const P2XRFrame *pose, int diagnostic);
// Engine (producer) thread only. Nonzero when the producer EGL context is
// current on the calling thread, i.e. the engine's render thread.
int p2_vision_gl_on_producer_thread(void);
// Recent presentation cadence: `steady` consecutive presents no more than
// 100 ms apart, `stereo` consecutive tracked-stereo presents, `last_ms` the
// SDL_GetTicks64 time of the last present. A pool resize resets both counts.
typedef struct { unsigned steady, stereo; uint64_t last_ms; } P2VisionGLCadence;
void p2_vision_gl_cadence(P2VisionGLCadence *cadence);
