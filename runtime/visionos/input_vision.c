#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include <SDL.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "input_vision.h"
#include "p2_xr.h"

static SDL_Joystick *pad;
static SDL_JoystickID pad_id = -1;
static Sint16 stick(float v) { return (Sint16)lrintf(fmaxf(-1,fminf(1,v)) * 32767); }
static Sint16 trigger(float v) { return (Sint16)lrintf(fmaxf(0,fminf(1,v)) * 65535 - 32768); }

#if P2_VISION_GAME
void rt_ios_game_state_poll(void);
int rt_ios_game_ui_visible(void);
void rt_ios_console_command(const char *line);

// Explicit simulator development audit, never enabled by the player UI.
// Exercise the actual guest SDL pad path after loading a controllable map.
// This is synthetic input and cannot establish physical controller support.
static void audit_input(P2XRInput *input) {
    static int enabled = -1, stage = -1, cancelled;
    static uint64_t started, previous, elapsed;
    if (enabled < 0) {
        const char *value = getenv("P2_VISION_INPUT_AUDIT");
        enabled = TARGET_OS_SIMULATOR && value && !strcmp(value,"1");
    }
    if (!enabled || cancelled) return;
    if (input->connected) {
        cancelled = 1;
        fprintf(stderr,"[vision-input-audit] Cancelled: native controller connected (spatial=%u move=%.2f/%.2f look=%.2f/%.2f buttons=%u)\n",
            input->spatial,input->move_x,input->move_y,input->turn_x,input->look_y,input->buttons);
        return;
    }
    rt_ios_game_state_poll();
    if (!started && rt_ios_game_ui_visible()) return;
    uint64_t now = SDL_GetTicks64();
    if (!started) { started = previous = now; }
    uint64_t interval = now - previous;
    previous = now;
    // Cold shader work can stall a frame for seconds. Keep each test action
    // long enough to reach the guest instead of skipping whole stages.
    elapsed += interval > 100 ? 100 : interval;
    int next = elapsed < 5000 ? 0 : elapsed < 8000 ? 1 : elapsed < 10000 ? 2 :
        elapsed < 11500 ? 3 : elapsed < 14500 ? 4 : elapsed < 16000 ? 5 :
        elapsed < 17500 ? 6 : elapsed < 19000 ? 7 : elapsed < 20000 ? 8 :
        elapsed < 20200 ? 9 : elapsed < 22000 ? 10 : elapsed < 22200 ? 11 : 12;
    if (stage != next) {
        static const char *names[] = {"settle","move forward","neutral","look right",
            "neutral","jump","primary fire","secondary fire","neutral",
            "pause","neutral","resume","finished neutral"};
        stage = next;
        fprintf(stderr,"[vision-input-audit] stage=%d %s time_ms=%llu (SYNTHETIC)\n",
            stage,names[stage],(unsigned long long)elapsed);
        SDL_Window *focused = SDL_GetKeyboardFocus();
        fprintf(stderr,"[vision-input-audit] focus=%d flags=%#x joystick_attached=%d\n",
            focused != NULL,focused ? SDL_GetWindowFlags(focused) : 0,SDL_JoystickGetAttached(pad));
        rt_ios_console_command("getpos");
    }
    memset(input,0,sizeof(*input));
    input->connected = 1;
    if (stage == 1) input->move_y = 1;
    if (stage == 3) { input->turn_x = 0.6f; input->look_y = 0.35f; }
    if (stage == 5 && elapsed < 14700) input->buttons = P2_XR_JUMP;
    if (stage == 6) input->blue_trigger = 1;
    if (stage == 7) input->orange_trigger = 1;
    if (stage == 9 || stage == 11) input->buttons = P2_XR_PAUSE;
}
#endif

int p2_vision_input_init(void) {
    SDL_Joystick *live = pad_id < 0 ? NULL : SDL_JoystickFromInstanceID(pad_id);
    if (pad && live == pad && SDL_JoystickGetAttached(pad)) return 0;
    if (pad) {
        fprintf(stderr,"[vision-input] Retiring detached native pad id=%d; SDL count=%d initialized=%#x\n",
            pad_id,SDL_NumJoysticks(),SDL_WasInit(0));
        // A guest SDL subsystem shutdown may have freed the old pointer.
        // Only close it when SDL still owns this exact instance.
        if (live == pad) SDL_JoystickClose(pad);
        pad = NULL; pad_id = -1;
    }
    // Native Swift GameController owns discovery and fixed-hand Sense input.
    // A single SDL virtual pad gives the unmodified guest its existing ABI,
    // without exposing the same hardware again as a second MFi device.
    SDL_SetHint(SDL_HINT_JOYSTICK_MFI,"0");
    // SDL's dummy window never owns native focus. SwiftUI controls session
    // suspension and clears snapshots when the real app loses focus.
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS,"1");
    if (!(SDL_WasInit(SDL_INIT_GAMECONTROLLER) & SDL_INIT_GAMECONTROLLER) &&
        SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER)) return -1;
    SDL_VirtualJoystickDesc description = {0};
    description.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    description.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    description.naxes = SDL_CONTROLLER_AXIS_MAX;
    description.nbuttons = SDL_CONTROLLER_BUTTON_MAX;
    description.axis_mask = (1u << SDL_CONTROLLER_AXIS_MAX) - 1;
    description.button_mask = (1u << SDL_CONTROLLER_BUTTON_MAX) - 1;
    description.name = "Portal 2 native controls";
    int index = -1;
    for (int i = 0; i < SDL_NumJoysticks(); ++i) {
        const char *name = SDL_JoystickNameForIndex(i);
        if (SDL_JoystickIsVirtual(i) && name && !strcmp(name,description.name)) { index = i; break; }
    }
    int attached = index < 0;
    if (attached) index = SDL_JoystickAttachVirtualEx(&description);
    if (index >= 0) pad = SDL_JoystickOpen(index);
    if (pad) pad_id = SDL_JoystickInstanceID(pad);
    fprintf(stderr,"[vision-input] SDL virtual gamepad: %s (index=%d mapped=%d)\n",
        pad ? "attached" : SDL_GetError(),index,index >= 0 ? SDL_IsGameController(index) : 0);
    if (!pad && attached && index >= 0) SDL_JoystickDetachVirtual(index);
    return pad ? 0 : -1;
}
void p2_vision_input_poll(void) {
    static uint64_t retry_at;
    SDL_Joystick *live = pad_id < 0 ? NULL : SDL_JoystickFromInstanceID(pad_id);
    if (!pad || live != pad || !SDL_JoystickGetAttached(pad)) {
        uint64_t now = SDL_GetTicks64();
        if (now < retry_at) return;
        if (p2_vision_input_init()) { retry_at = now + 1000; return; }
        retry_at = 0;
    }
    P2XRInput input;
    p2_xr_read_controls(&input); // Invalid/retired/tracking-lost is neutral.
#if P2_VISION_GAME
    audit_input(&input);
#endif
    const Sint16 axes[SDL_CONTROLLER_AXIS_MAX] = {
        stick(input.move_x),stick(-input.move_y),stick(input.turn_x),stick(-input.look_y),
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
