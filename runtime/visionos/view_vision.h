#pragma once
// Call on the guest game thread while its runtime lock is held.
void p2_vision_view_poll(void);
// Guest game thread, after p2_vision_view_poll: nonzero while the head drives
// the engine view angles for the current tracked immersive session. The
// guest pad's right stick (turn_x/look_y) must then stay centered; snap or
// smooth turning reads P2XRInput.turn_x on the engine side instead.
int p2_vision_head_aim_active(void);
// Any thread: nonzero while the tracked right PSVR2 Sense controller's aim
// ray places portals (and the portal gun viewmodel follows that controller)
// in the current tracked immersive session: audited server.so profile, Sense
// pair owning input, head and right controller tracked, head aim recent,
// game UI hidden. Zero means portals follow the head (or nothing fires).
// Assumes the game was lifted with the TraceFirePortal NATIVE_OVERRIDES entry;
// P2_NATIVE_TRACE_FIRE_PORTAL=0 turns the feature off. Implemented in
// aim_vision.c.
int p2_vision_controller_aim_active(void);
// Nonzero while the stereo RenderView pair is in progress (guest thread).
int p2_vision_view_rendering(void);
