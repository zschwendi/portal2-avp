#include "menu_input.h"
#include <string.h>

static int held(float value, int down, float press, float release) {
    return value > (down ? release : press);
}

uint32_t p2_menu_input_map(P2MenuInput *state, int ui_visible, int stick_dpad, P2XRInput *input) {
    if (!state || !input) return 0;
    ui_visible = ui_visible != 0;
    if (!input->connected) { memset(state, 0, sizeof(*state)); return 0; }
    if (state->known && state->ui != ui_visible) {
        // Context changed: whatever is held now belongs to the old context.
        state->latched |= input->buttons;
        state->blue_latched |= input->blue_trigger > P2_MENU_HELD_RELEASE;
        state->orange_latched |= input->orange_trigger > P2_MENU_HELD_RELEASE;
        state->blue_down = state->orange_down = 0;
        state->dpad = 0;
    }
    state->known = 1;
    state->ui = ui_visible;
    // A latched control is usable again once let go.
    state->latched &= input->buttons;
    if (input->blue_trigger <= P2_MENU_HELD_RELEASE) state->blue_latched = 0;
    if (input->orange_trigger <= P2_MENU_HELD_RELEASE) state->orange_latched = 0;
    input->buttons &= ~state->latched;
    if (state->blue_latched) input->blue_trigger = 0;
    if (state->orange_latched) input->orange_trigger = 0;
    if (!ui_visible) return 0;

    if (input->spatial) {
        state->blue_down = held(input->blue_trigger, state->blue_down, P2_MENU_TRIGGER_PRESS, P2_MENU_TRIGGER_RELEASE);
        state->orange_down = held(input->orange_trigger, state->orange_down, P2_MENU_TRIGGER_PRESS, P2_MENU_TRIGGER_RELEASE);
        if (state->blue_down) input->buttons |= P2_XR_JUMP;
        if (state->orange_down) input->buttons |= P2_XR_CROUCH;
        input->blue_trigger = input->orange_trigger = 0;
    }
    if (!stick_dpad) return 0;
    uint32_t dpad = 0;
    // Guest stick up is P2XRInput move_y > 0 (input_vision.c negates for SDL).
    if (held(input->move_y, state->dpad & P2_MENU_DPAD_UP, P2_MENU_STICK_PRESS, P2_MENU_STICK_RELEASE)) dpad |= P2_MENU_DPAD_UP;
    if (held(-input->move_y, state->dpad & P2_MENU_DPAD_DOWN, P2_MENU_STICK_PRESS, P2_MENU_STICK_RELEASE)) dpad |= P2_MENU_DPAD_DOWN;
    if (held(-input->move_x, state->dpad & P2_MENU_DPAD_LEFT, P2_MENU_STICK_PRESS, P2_MENU_STICK_RELEASE)) dpad |= P2_MENU_DPAD_LEFT;
    if (held(input->move_x, state->dpad & P2_MENU_DPAD_RIGHT, P2_MENU_STICK_PRESS, P2_MENU_STICK_RELEASE)) dpad |= P2_MENU_DPAD_RIGHT;
    state->dpad = dpad;
    input->move_x = input->move_y = 0;
    return dpad;
}
