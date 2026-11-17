// Menu/gameplay context rules for the guest virtual pad. Pure C (no SDL), so
// host tests exercise exactly what input_vision.c applies.
#pragma once
#include <stdint.h>
#include "p2_xr.h"

#ifdef __cplusplus
extern "C" {
#endif

// D-pad bits produced by p2_menu_input_map (only with stick_dpad enabled).
enum { P2_MENU_DPAD_UP = 1u, P2_MENU_DPAD_DOWN = 2u, P2_MENU_DPAD_LEFT = 4u, P2_MENU_DPAD_RIGHT = 8u };

#define P2_MENU_TRIGGER_PRESS 0.65f
#define P2_MENU_TRIGGER_RELEASE 0.35f
#define P2_MENU_HELD_RELEASE 0.1f
#define P2_MENU_STICK_PRESS 0.6f
#define P2_MENU_STICK_RELEASE 0.3f

typedef struct {
    int known, ui;           // last game-UI state seen (known: one sample taken)
    uint32_t latched;        // buttons held across a menu<->gameplay change
    int blue_latched, orange_latched;
    int blue_down, orange_down;   // menu trigger hysteresis
    uint32_t dpad;           // menu stick->d-pad hysteresis
} P2MenuInput;

// Applies, in order:
//  1. Context latch: every control held when the game UI appears or hides
//     stays released for the guest until it is let go, so a menu selection
//     never becomes a jump/shot and a shot never selects a menu item.
//  2. In menus, for a Sense pair (input->spatial): right trigger selects
//     (P2_XR_JUMP, guest A) and left trigger goes back (P2_XR_CROUCH, guest
//     B); triggers then read zero (they are bound to +attack/+attack2).
//  3. Optional (stick_dpad): in menus the left stick becomes d-pad presses
//     and the stick axes read zero, so the menu never sees both.
// Hand input (connected == P2_VISION_INPUT_HANDS) is left to the hand gate.
// Returns the d-pad mask for the guest pad.
uint32_t p2_menu_input_map(P2MenuInput *state, int ui_visible, int stick_dpad, P2XRInput *input);

#ifdef __cplusplus
}
#endif
