#pragma once
#include <stdint.h>
// P2XRInput.connected value published by PortalHandControls.swift. Hand input
// is otherwise an ordinary connected, non-spatial snapshot.
#define P2_VISION_INPUT_HANDS 2u
int p2_vision_input_init(void);
void p2_vision_input_poll(void);
// Guest game thread, after stock pickup accepted the local Use. Returns a
// fresh edge only once, and writes 0 for left Sense or 1 for right Sense.
int p2_vision_take_grip_use(uint64_t session, unsigned *hand);
