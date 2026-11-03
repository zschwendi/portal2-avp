#pragma once
#include "../content_check.h"
// One engine lifetime per app process. 0 idle, 1 starting/running, 2 returned,
// -1 owned content missing or incomplete. Displayed GPU frames are tracked separately.
// Starts only when the owned content under Documents is complete
// (content_check.h); otherwise returns -1 and p2_vision_content_last has the
// reason. Returns 0 when it started it, or when it is already running or
// returned. `trigger` ("launch", "check-again", ...) is recorded with every
// check in Documents/portal2-setup-status.json. Any thread.
int p2_vision_game_start(const char *trigger);
int p2_vision_game_state(void);
// Runs the completeness check without starting the engine (also writes the
// status file, and remembers the report). Returns report->complete. Any thread.
int p2_vision_content_check(const char *trigger, P2ContentReport *report);
// The last check's report, with the volume sizes; 0 when none ran yet.
int p2_vision_content_last(P2ContentReport *report);
// IEngineVGui::IsGameUIVisible (menus, pause, loading) as last polled on the
// game thread; 0 unless the engine is running. Safe from any thread. The poll
// runs from the engine's own render/input paths, so the value may lag.
int p2_vision_game_ui_visible(void);

// ---- Immersive eye render size (any thread) --------------------------------
// The immersive renderer asks for a per-eye engine size (pixels) while it owns
// engine frames; 0x0 withdraws it (back to the windowed size). The engine
// thread applies it with `mat_setvideomode W H 1` only at a steady frame
// boundary (sdl_vision.c); a mode that does not take leaves 16:9 in place.
void p2_vision_request_eye_size(int width, int height);
// 1 for up to 2.5 s after the request was withdrawn while the engine still
// renders an immersive eye size: the window keeps its last picture instead of
// showing (and adopting the aspect of) eye-sized frames. 0 otherwise.
int p2_vision_display_restoring(void);
// Engine thread (sdl_vision.c): the pending request and the current state.
void p2_vision_requested_eye_size(int *width, int *height);
void p2_vision_set_eye_mode(int active);

// Sense controller portal aim is driving the engine (nonzero), off (0), or
// unknown (-1: the engine-side aim code is not linked yet). The strong
// definition belongs to the engine aim code; game_vision.m holds a weak -1
// fallback. Must be safe to call from the compositor render thread.
int p2_vision_controller_aim_active(void);
