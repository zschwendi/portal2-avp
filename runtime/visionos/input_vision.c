#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include <SDL.h>
#include <math.h>
#include <stdio.h>
#include "input_vision.h"
#include "p2_xr.h"

static SDL_Joystick *pad;
static Sint16 stick(float v) { return (Sint16)lrintf(fmaxf(-1,fminf(1,v)) * 32767); }
static Sint16 trigger(float v) { return (Sint16)lrintf(fmaxf(0,fminf(1,v)) * 65535 - 32768); }

int p2_vision_input_init(void) {
    if (pad) return 0;
    // Native Swift GameController owns discovery and fixed-hand Sense input.
    // A single SDL virtual pad gives the unmodified guest its existing ABI,
    // without exposing the same hardware again as a second MFi device.
    SDL_SetHint(SDL_HINT_JOYSTICK_MFI,"0");
    // SDL's dummy window never owns native focus. SwiftUI controls session
    // suspension and clears snapshots when the real app loses focus.
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS,"1");
    if (SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER)) return -1;
    SDL_VirtualJoystickDesc description = {0};
    description.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    description.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    description.naxes = SDL_CONTROLLER_AXIS_MAX;
    description.nbuttons = SDL_CONTROLLER_BUTTON_MAX;
    description.axis_mask = (1u << SDL_CONTROLLER_AXIS_MAX) - 1;
    description.button_mask = (1u << SDL_CONTROLLER_BUTTON_MAX) - 1;
    description.name = "Portal 2 native controls";
    int index = SDL_JoystickAttachVirtualEx(&description);
    if (index >= 0) pad = SDL_JoystickOpen(index);
    fprintf(stderr,"[vision-input] SDL virtual gamepad: %s (index=%d mapped=%d)\n",
        pad ? "attached" : SDL_GetError(),index,index >= 0 ? SDL_IsGameController(index) : 0);
    if (!pad && index >= 0) SDL_JoystickDetachVirtual(index);
    return pad ? 0 : -1;
}
void p2_vision_input_poll(void) {
    if (!pad) return;
    P2XRInput input;
    p2_xr_read_controls(&input); // Invalid/retired/tracking-lost is neutral.
    const Sint16 axes[SDL_CONTROLLER_AXIS_MAX] = {
        stick(input.move_x),stick(-input.move_y),stick(input.turn_x),0,
        trigger(input.orange_trigger),trigger(input.blue_trigger)
    };
    for (int axis = 0; axis < SDL_CONTROLLER_AXIS_MAX; ++axis)
        SDL_JoystickSetVirtualAxis(pad,axis,axes[axis]);
    for (int button = 0; button < SDL_CONTROLLER_BUTTON_MAX; ++button) {
        uint32_t action = button == SDL_CONTROLLER_BUTTON_A ? P2_XR_JUMP :
            button == SDL_CONTROLLER_BUTTON_B ? P2_XR_CROUCH :
            button == SDL_CONTROLLER_BUTTON_X ? P2_XR_USE :
            button == SDL_CONTROLLER_BUTTON_START ? P2_XR_PAUSE : 0;
        SDL_JoystickSetVirtualButton(pad,button,(input.buttons & action) != 0);
    }
}
#endif
