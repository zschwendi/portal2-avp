#pragma once
// P2XRInput.connected value published by PortalHandControls.swift. Hand input
// is otherwise an ordinary connected, non-spatial snapshot.
#define P2_VISION_INPUT_HANDS 2u
int p2_vision_input_init(void);
void p2_vision_input_poll(void);
