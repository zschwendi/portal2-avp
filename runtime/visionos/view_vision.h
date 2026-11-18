#pragma once
// Call on the guest game thread while its runtime lock is held.
void p2_vision_view_poll(void);
// Guest game thread, after p2_vision_view_poll: nonzero while the head drives
// the engine view angles for the current tracked immersive session. The
// guest pad's right stick (turn_x/look_y) must then stay centered; snap or
// smooth turning reads P2XRInput.turn_x on the engine side instead.
int p2_vision_head_aim_active(void);
// Nonzero while the stereo RenderView pair is in progress (guest thread).
int p2_vision_view_rendering(void);
