#include "menu_input.h"
#include <assert.h>
#include <stdio.h>

static P2XRInput sense(float blue, float orange, uint32_t buttons) {
    return (P2XRInput){.connected=1,.spatial=1,.blue_trigger=blue,.orange_trigger=orange,.buttons=buttons};
}

static void menu_triggers(void) {
    P2MenuInput state = {0};
    P2XRInput in = sense(0.7f,0,0);
    assert(!p2_menu_input_map(&state,1,0,&in));
    assert(in.buttons == P2_XR_JUMP && in.blue_trigger == 0 && in.orange_trigger == 0);
    in = sense(0.5f,0,0); p2_menu_input_map(&state,1,0,&in);   // hysteresis: still held
    assert(in.buttons == P2_XR_JUMP);
    in = sense(0.2f,0,0); p2_menu_input_map(&state,1,0,&in);
    assert(!in.buttons);
    in = sense(0.5f,0,0); p2_menu_input_map(&state,1,0,&in);   // below press threshold
    assert(!in.buttons);
    in = sense(0,0.9f,0); p2_menu_input_map(&state,1,0,&in);
    assert(in.buttons == P2_XR_CROUCH && in.orange_trigger == 0);
    // Face buttons keep their mapping in menus.
    in = sense(0,0,P2_XR_JUMP); p2_menu_input_map(&state,1,0,&in);
    assert(in.buttons == P2_XR_JUMP);
    // A standard gamepad keeps its own triggers (it has A/B).
    P2MenuInput pad = {0};
    in = (P2XRInput){.connected=1,.blue_trigger=1};
    p2_menu_input_map(&pad,1,0,&in);
    assert(in.blue_trigger == 1 && !in.buttons);
    // In gameplay the triggers fire normally.
    P2MenuInput play = {0};
    in = sense(1,0.8f,0); p2_menu_input_map(&play,0,0,&in);
    assert(in.blue_trigger == 1 && in.orange_trigger == 0.8f && !in.buttons);
}

static void context_carry_over(void) {
    // Trigger held to select a chapter: the map starts with the trigger still
    // down; no portal is fired until it is released and pulled again.
    P2MenuInput state = {0};
    P2XRInput in = sense(1,0,0);
    p2_menu_input_map(&state,1,0,&in); assert(in.buttons == P2_XR_JUMP);
    in = sense(1,0,0); p2_menu_input_map(&state,0,0,&in);
    assert(in.blue_trigger == 0 && !in.buttons);
    in = sense(0.6f,0,0); p2_menu_input_map(&state,0,0,&in);   // not let go yet
    assert(in.blue_trigger == 0);
    in = sense(0.05f,0,0); p2_menu_input_map(&state,0,0,&in);
    in = sense(1,0,0); p2_menu_input_map(&state,0,0,&in);
    assert(in.blue_trigger == 1);
    // Cross held to select: no jump on arrival; a fresh press jumps.
    state = (P2MenuInput){0};
    in = sense(0,0,P2_XR_JUMP); p2_menu_input_map(&state,1,0,&in); assert(in.buttons == P2_XR_JUMP);
    in = sense(0,0,P2_XR_JUMP); p2_menu_input_map(&state,0,0,&in); assert(!in.buttons);
    in = sense(0,0,0); p2_menu_input_map(&state,0,0,&in);
    in = sense(0,0,P2_XR_JUMP); p2_menu_input_map(&state,0,0,&in); assert(in.buttons == P2_XR_JUMP);
    // Firing when a menu appears (death, level end): the held trigger never
    // selects, and a held jump never confirms.
    state = (P2MenuInput){0};
    in = sense(1,0,P2_XR_JUMP); p2_menu_input_map(&state,0,0,&in); assert(in.blue_trigger == 1);
    in = sense(1,0,P2_XR_JUMP); p2_menu_input_map(&state,1,0,&in);
    assert(!in.buttons && in.blue_trigger == 0);
    in = sense(0,0,0); p2_menu_input_map(&state,1,0,&in);
    in = sense(0.9f,0,0); p2_menu_input_map(&state,1,0,&in); assert(in.buttons == P2_XR_JUMP);
    // Pause pressed in gameplay reaches the guest; held into the menu it
    // reads released, so the menu is not dismissed by the same press.
    state = (P2MenuInput){0};
    in = sense(0,0,P2_XR_PAUSE); p2_menu_input_map(&state,0,0,&in); assert(in.buttons == P2_XR_PAUSE);
    in = sense(0,0,P2_XR_PAUSE); p2_menu_input_map(&state,1,0,&in); assert(!in.buttons);
    // Disconnect forgets everything.
    in = (P2XRInput){0}; p2_menu_input_map(&state,1,0,&in);
    in = sense(0,0,P2_XR_PAUSE); p2_menu_input_map(&state,1,0,&in); assert(in.buttons == P2_XR_PAUSE);
}

static void stick_dpad(void) {
    P2MenuInput state = {0};
    P2XRInput in = sense(0,0,0); in.move_y = 0.8f;
    assert(!p2_menu_input_map(&state,1,0,&in) && in.move_y == 0.8f);   // off by default
    in = sense(0,0,0); in.move_y = 0.8f;
    assert(p2_menu_input_map(&state,1,1,&in) == P2_MENU_DPAD_UP && in.move_y == 0 && in.move_x == 0);
    in = sense(0,0,0); in.move_y = 0.4f;
    assert(p2_menu_input_map(&state,1,1,&in) == P2_MENU_DPAD_UP);       // hysteresis
    in = sense(0,0,0); in.move_y = 0.1f;
    assert(!p2_menu_input_map(&state,1,1,&in));
    in = sense(0,0,0); in.move_y = -0.9f; in.move_x = 0.7f;
    assert(p2_menu_input_map(&state,1,1,&in) == (P2_MENU_DPAD_DOWN | P2_MENU_DPAD_RIGHT));
    in = sense(0,0,0); in.move_x = -0.7f;
    assert(p2_menu_input_map(&state,1,1,&in) == P2_MENU_DPAD_LEFT);
    in = sense(0,0,0); in.move_y = 0.9f;                                 // gameplay: stick moves
    assert(!p2_menu_input_map(&state,0,1,&in) && in.move_y == 0.9f);
}

int main(void) {
    menu_triggers(); context_carry_over(); stick_dpad();
    puts("Menu input passed: Sense trigger select/back, context latches, opt-in stick d-pad");
    return 0;
}
