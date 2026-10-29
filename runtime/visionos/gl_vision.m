// Native offscreen GLES -> Metal storage. EGL IOSurface attributes follow the
// public ANGLE extension; Klepton's MIT glfb implementation was a reference.
#include <TargetConditionals.h>
#if TARGET_OS_VISION
#import <Foundation/Foundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <SDL.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gl_vision.h"

// ANGLE vendor-extension tokens are not in SDL2's Khronos EGL headers.
// EGL_ANGLE_platform_angle + EGL_ANGLE_iosurface_client_buffer.
#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif
#ifndef EGL_IOSURFACE_ANGLE
#define EGL_IOSURFACE_ANGLE 0x3454
#define EGL_IOSURFACE_PLANE_ANGLE 0x345A
#define EGL_TEXTURE_TYPE_ANGLE 0x345C
#define EGL_TEXTURE_INTERNAL_FORMAT_ANGLE 0x345D
#endif
#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT 0x80E1
#endif

enum { SLOT_COUNT = 3 };
typedef struct {
    IOSurfaceRef storage;
    EGLSurface surface;
    unsigned leases;
    uint64_t sequence;
} SurfaceSlot;
typedef struct {
    EGLDisplay display;
    EGLConfig config;
    EGLContext context;
    SurfaceSlot slots[SLOT_COUNT];
    int writing, published;
    int width, height;
    uint64_t sequence;
} VisionContext;

static void *gles_library, *egl_library;
static VisionContext *host;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t available = PTHREAD_COND_INITIALIZER;
static PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform;
static EGLBoolean (*initialize)(EGLDisplay, EGLint *, EGLint *);
static EGLBoolean (*choose_config)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
static EGLContext (*create_context)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
static EGLSurface (*create_client_surface)(EGLDisplay, EGLenum, EGLClientBuffer, EGLConfig, const EGLint *);
static EGLBoolean (*make_current)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
static EGLBoolean (*destroy_surface)(EGLDisplay, EGLSurface);
static EGLBoolean (*destroy_context)(EGLDisplay, EGLContext);
static EGLContext (*get_current)(void);
static void (*finish)(void);
static EGLint (*get_error)(void);

static void *open_framework(NSString *name) {
    NSString *path = [[[NSBundle mainBundle] privateFrameworksPath] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.framework/%@", name, name]];
    return dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
}
static int load_angle(void) {
    if (gles_library && egl_library) return 1;
    gles_library = open_framework(@"libGLESv2");
    egl_library = open_framework(@"libEGL");
    if (!gles_library || !egl_library) {
        fprintf(stderr, "[gl-vision] ANGLE frameworks could not load: %s\n", dlerror());
        return 0;
    }
#define LOAD(variable, symbol) do { \
    variable = (__typeof__(variable))dlsym(egl_library, symbol); \
    if (!variable) { fprintf(stderr, "[gl-vision] ANGLE is missing %s\n", symbol); return 0; } \
} while (0)
    LOAD(get_platform, "eglGetPlatformDisplayEXT");
    LOAD(initialize, "eglInitialize"); LOAD(choose_config, "eglChooseConfig");
    LOAD(create_context, "eglCreateContext");
    LOAD(create_client_surface, "eglCreatePbufferFromClientBuffer");
    LOAD(make_current, "eglMakeCurrent"); LOAD(get_current, "eglGetCurrentContext");
    LOAD(destroy_surface, "eglDestroySurface"); LOAD(destroy_context, "eglDestroyContext");
    LOAD(get_error, "eglGetError");
#undef LOAD
    finish = (void (*)(void))dlsym(gles_library, "glFinish");
    return finish != NULL;
}
void *p2_vision_gles_library(void) { return gles_library; }
int p2_vision_gl_load_library(const char *path) {
    if (path) return SDL_SetError("visionOS only loads the bundled ANGLE frameworks");
    return load_angle() ? 0 : SDL_SetError("Bundled ANGLE frameworks could not load");
}
void p2_vision_gl_unload_library(void) { /* Shared frameworks live for this engine lifetime. */ }

static IOSurfaceRef new_storage(int width, int height) {
    NSDictionary *properties = @{
        (__bridge NSString *)kIOSurfaceWidth: @(width),
        (__bridge NSString *)kIOSurfaceHeight: @(height),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @4,
        (__bridge NSString *)kIOSurfacePixelFormat: @((uint32_t)0x42475241)
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)properties);
}
static void free_slots(VisionContext *context, SurfaceSlot *slots) {
    for (int i = 0; i < SLOT_COUNT; ++i) {
        if (slots[i].surface) destroy_surface(context->display,slots[i].surface);
        if (slots[i].storage) CFRelease(slots[i].storage);
    }
}
static int new_slots(VisionContext *context, int width, int height, SurfaceSlot *slots) {
    const EGLint attributes[] = {EGL_WIDTH,width,EGL_HEIGHT,height,
        EGL_IOSURFACE_PLANE_ANGLE,0,EGL_TEXTURE_TARGET,EGL_TEXTURE_2D,EGL_TEXTURE_FORMAT,EGL_TEXTURE_RGBA,
        EGL_TEXTURE_TYPE_ANGLE,GL_UNSIGNED_BYTE,EGL_TEXTURE_INTERNAL_FORMAT_ANGLE,GL_BGRA_EXT,EGL_NONE};
    for (int i = 0; i < SLOT_COUNT; ++i) {
        slots[i].storage = new_storage(width,height);
        if (!slots[i].storage) return 0;
        slots[i].surface = create_client_surface(context->display,EGL_IOSURFACE_ANGLE,
            (EGLClientBuffer)slots[i].storage,context->config,attributes);
        if (!slots[i].surface) return 0;
    }
    return 1;
}
static void destroy(VisionContext *context) {
    if (!context) return;
    make_current(context->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    free_slots(context,context->slots);
    if (context->context) destroy_context(context->display, context->context);
    free(context);
}
SDL_GLContext p2_vision_gl_create_context(int width, int height) {
    if (host || width <= 0 || height <= 0 || width > 8192 || height > 8192 || !load_angle()) {
        SDL_SetError("visionOS currently supports one ANGLE context with dimensions up to 8192");
        return NULL;
    }
    VisionContext *context = calloc(1, sizeof(*context));
    if (!context) return NULL;
    context->width = width; context->height = height; context->published = -1;
    const EGLint display_attributes[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
    context->display = get_platform(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, display_attributes);
    if (!context->display || !initialize(context->display, NULL, NULL)) goto fail;
    const EGLint config_attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8, EGL_NONE};
    EGLint count = 0;
    if (!choose_config(context->display, config_attributes, &context->config, 1, &count) || !count) goto fail;
    const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    context->context = create_context(context->display, context->config, EGL_NO_CONTEXT, context_attributes);
    if (!context->context) goto fail;
    if (!new_slots(context,width,height,context->slots)) goto fail;
    if (!make_current(context->display, context->slots[0].surface, context->slots[0].surface, context->context)) goto fail;
    pthread_mutex_lock(&lock); host = context; pthread_mutex_unlock(&lock);
    fprintf(stderr, "[gl-vision] Native ANGLE/Metal IOSurface pool created (%dx%d, %d slots)\n", width, height, SLOT_COUNT);
    return context;
fail:
    fprintf(stderr, "[gl-vision] Context creation failed: EGL error %#x\n", get_error());
    destroy(context);
    SDL_SetError("ANGLE Metal IOSurface context creation failed");
    return NULL;
}
void *p2_vision_gl_current_context(void) { return get_current ? get_current() : NULL; }
void *p2_vision_gl_share_group(void *context) { return context && host ? host->context : NULL; }
int p2_vision_gl_make_current(SDL_Window *window, SDL_GLContext opaque) {
    (void)window;
    VisionContext *context = opaque;
    if (!context) return host && make_current(host->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) ? 0 : -1;
    EGLSurface surface = context->slots[context->writing].surface;
    return make_current(context->display, surface, surface, context->context) ? 0 : -1;
}
int p2_vision_gl_swap_interval(int interval) { (void)interval; return 0; }
void p2_vision_gl_drawable_size(int *width, int *height) {
    if (width) *width = host ? host->width : 0;
    if (height) *height = host ? host->height : 0;
}
int p2_vision_gl_resize(int width, int height) {
    VisionContext *context = host;
    if (!context || (width == context->width && height == context->height)) return 0;
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192)
        return SDL_SetError("Unsupported visionOS surface dimensions");
    SurfaceSlot replacement[SLOT_COUNT] = {0}, previous[SLOT_COUNT];
    if (!new_slots(context,width,height,replacement)) {
        free_slots(context,replacement);
        return SDL_SetError("Could not allocate resized ANGLE IOSurfaces");
    }
    finish();
    pthread_mutex_lock(&lock);
    int published = context->published;
    context->published = -1; // No new leases while old GPU readers retire.
    for (;;) {
        unsigned leases = 0;
        for (int i = 0; i < SLOT_COUNT; ++i) leases += context->slots[i].leases;
        if (!leases) break;
        pthread_cond_wait(&available,&lock);
    }
    if (!make_current(context->display,replacement[0].surface,replacement[0].surface,context->context)) {
        context->published = published;
        pthread_mutex_unlock(&lock);
        free_slots(context,replacement);
        return SDL_SetError("Could not bind resized ANGLE surface");
    }
    memcpy(previous,context->slots,sizeof(previous));
    memcpy(context->slots,replacement,sizeof(replacement));
    context->width = width; context->height = height; context->writing = 0;
    pthread_mutex_unlock(&lock);
    free_slots(context,previous);
    fprintf(stderr,"[gl-vision] Resized native IOSurface pool to %dx%d\n",width,height);
    return 0;
}
void p2_vision_gl_present(void) {
    VisionContext *context = host;
    if (!context) return;
    finish(); // Producer GPU writes must finish before another Metal queue samples the storage.
    pthread_mutex_lock(&lock);
    context->slots[context->writing].sequence = ++context->sequence;
    context->published = context->writing;
    int next = -1;
    while (next < 0) {
        for (int i = 0; i < SLOT_COUNT; ++i)
            if (i != context->published && !context->slots[i].leases) { next = i; break; }
        if (next < 0) pthread_cond_wait(&available, &lock);
    }
    context->writing = next;
    pthread_mutex_unlock(&lock);
    EGLSurface surface = context->slots[next].surface;
    if (!make_current(context->display, surface, surface, context->context))
        fprintf(stderr, "[gl-vision] Could not switch producer slot: EGL error %#x\n", get_error());
}
int p2_vision_gl_acquire(P2VisionGLFrame *frame) {
    if (!frame) return 0;
    memset(frame, 0, sizeof(*frame)); frame->slot = -1;
    pthread_mutex_lock(&lock);
    int ready = host && host->published >= 0;
    if (ready) {
        SurfaceSlot *slot = &host->slots[host->published];
        ++slot->leases;
        *frame = (P2VisionGLFrame){slot->sequence, (uint32_t)host->width, (uint32_t)host->height,
            (void *)slot->storage, host->published};
    }
    pthread_mutex_unlock(&lock);
    return ready;
}
void p2_vision_gl_release(int32_t slot) {
    pthread_mutex_lock(&lock);
    if (host && slot >= 0 && slot < SLOT_COUNT && host->slots[slot].leases) {
        --host->slots[slot].leases;
        pthread_cond_broadcast(&available);
    }
    pthread_mutex_unlock(&lock);
}
void p2_vision_gl_delete_context(SDL_GLContext opaque) {
    VisionContext *context = opaque;
    if (!context) return;
    pthread_mutex_lock(&lock);
    context->published = -1; // Stop new leases before waiting for readers.
    // Wait for compositor command buffers to retire before releasing storage.
    for (;;) {
        unsigned leases = 0;
        for (int i = 0; i < SLOT_COUNT; ++i) leases += context->slots[i].leases;
        if (!leases) break;
        pthread_cond_wait(&available, &lock);
    }
    if (host == context) host = NULL;
    pthread_mutex_unlock(&lock);
    destroy(context);
}
#endif
