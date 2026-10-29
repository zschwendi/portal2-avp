#pragma once
#include <stdint.h>
#include "p2_xr.h"
enum P2VisionFrameKind {
    P2_VISION_MONO = 1, P2_VISION_TRACKED_STEREO = 2,
    P2_VISION_DIAGNOSTIC_STEREO = 3
};
typedef struct {
    uint64_t sequence;
    uint32_t width, height;
    // Borrowed IOSurfaceRef, valid until release. Keep the lease until the
    // consuming Metal command buffer completes.
    void *surface;
    void *right_surface;
    uint32_t eye_count, kind;
    uint64_t xr_session;
    P2XRFrame render_pose;
    int32_t slot;
} P2VisionGLFrame;
int p2_vision_gl_acquire(P2VisionGLFrame *frame);
void p2_vision_gl_release(int32_t slot);
