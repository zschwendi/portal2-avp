// Engine video config (portal2-userdata/update/cfg/video.txt) repair.
//
// On first launch the engine derives its video config from the 2560x2560
// virtual display (sdl_vision.c) and writes "setting.defaultres" 2560,
// "setting.defaultresheight" 2560, "setting.fullscreen" 1. It then runs a
// 2560x720 (32:9) window despite -w 1280 -h 720 (physical log, Nov 17 2026),
// which the immersive menu panel shows as a thin strip.
//
// p2_video_config_prepare runs before the engine starts:
//  - absent file: seeds the engine's own format, windowed 1280x720;
//  - exactly the generated 2560x2560 pair: rewrites only those values (and a
//    fullscreen "1" to "0") in place, after a one-time backup of the original
//    next to it (<path>.pre-1280x720); every other byte is kept;
//  - anything else (a player's own size, already repaired, malformed or
//    ambiguous data): left untouched.
// Valve KeyValues tokens: quoted or bare, any whitespace, // comments, keys
// case-insensitive. Writes are temp file + rename; failures leave the
// original in place and are reported. Pure C, host tested.
#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    P2_VIDEO_CONFIG_UNCHANGED = 0,  // custom or already repaired
    P2_VIDEO_CONFIG_SEEDED = 1,
    P2_VIDEO_CONFIG_REPAIRED = 2,
    P2_VIDEO_CONFIG_SKIPPED = 3,    // malformed/ambiguous: untouched
    P2_VIDEO_CONFIG_FAILED = -1     // I/O failure: original untouched
} P2VideoConfigResult;

#define P2_VIDEO_CONFIG_BACKUP_SUFFIX ".pre-1280x720"

// path: .../portal2-userdata/update/cfg/video.txt. Missing parent folders are
// created only when seeding. message receives one human-readable line.
P2VideoConfigResult p2_video_config_prepare(const char *path, char *message, size_t message_size);

// Text-only core (no I/O): repaired copy in *out (malloc, caller frees) when
// the result is REPAIRED; otherwise *out is NULL.
P2VideoConfigResult p2_video_config_repair_text(const char *text, size_t length, char **out, size_t *out_length);

#ifdef __cplusplus
}
#endif
