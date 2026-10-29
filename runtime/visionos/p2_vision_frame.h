#pragma once
#include <stdint.h>
typedef struct {
    uint64_t sequence;
    uint32_t width, height;
    // Borrowed IOSurfaceRef, valid until release. Keep the lease until the
    // consuming Metal command buffer completes.
    void *surface;
    int32_t slot;
} P2VisionGLFrame;
int p2_vision_gl_acquire(P2VisionGLFrame *frame);
void p2_vision_gl_release(int32_t slot);
