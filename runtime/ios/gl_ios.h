// OpenGL hôte sur iOS : gl4es fournit l'OpenGL 2.1 de bureau qu'attend togl,
// au-dessus d'OpenGL ES 2 (OpenGLES.framework). Inclus par runtime/host_gl.h.
//
// - Les fonctions GL viennent de gl4es_GetProcAddress ; sous Darwin, les
//   en-têtes de gl4es renomment aussi tout appel direct glX en gl4es_glX.
// - CGL (contexte courant, groupe de partage) est remplacé par EAGL.
// - SDL_GL_CreateContext force un contexte ES 2 puis initialise gl4es ;
//   SDL_GL_SwapWindow vide d'abord le tampon de gl4es (gl4es_pre_swap).
#pragma once
#include <GL/gl.h>
#include <GL/glext.h>
#include <SDL.h>
#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include "../visionos/sdl_vision.h"
#else
#include "sdl_ios.h"   // tailles en pixels pour le jeu
#endif

typedef void *CGLContextObj;
typedef void *CGLShareGroupObj;
void *rt_ios_gl_current_context(void);
void *rt_ios_gl_share_group(void *context);
#define CGLGetCurrentContext rt_ios_gl_current_context
#define CGLGetShareGroup rt_ios_gl_share_group

extern _Thread_local int rt_ios_gl_unsync_next;   // gl.c -> gl_ios.m : prochain glBufferSubData d'ES sans synchronisation
void *rt_host_gl_open(void);
void *rt_host_gl_symbol(void *library, const char *name);

SDL_GLContext rt_ios_gl_create_context(SDL_Window *window);
void rt_ios_gl_swap_window(SDL_Window *window);
#define SDL_GL_CreateContext rt_ios_gl_create_context
#define SDL_GL_SwapWindow rt_ios_gl_swap_window
