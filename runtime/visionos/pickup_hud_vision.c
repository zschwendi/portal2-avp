#include <TargetConditionals.h>
#if TARGET_OS_VISION
#include "pickup_hud_vision.h"
#include "modules.h"
#include "../../build/visionos/xr-pickup-hud-profile.h"
#include <stdio.h>
#include <string.h>

#if P2_XR_PICKUP_HUD_PROFILE
enum {
    DRAW_COLOR_RGBA = 0x2c,
    TEXT_POS_X = 0x34,
    TEXT_POS_Y = 0x38,
    PANEL_X = 0x0c,
    PANEL_Y = 0x10,
    GLYPH_RENDER_INFO_SIZE = 0x30,
    GLYPH_VERTICES = 0x08,
    GLYPH_DRAW_TYPE = 0x24,
    MAX_CAPTION_CHARACTERS = 256,
};

static const char *const paint_name = "__p2_pickup_hud_paint";
static const char *const surface_names[] = {
    "__p2_pickup_hud_color", "__p2_pickup_hud_color_value",
    "__p2_pickup_hud_text", "__p2_pickup_hud_character",
};
enum { COLOR, COLOR_VALUE, TEXT, CHARACTER };

static const unsigned surface_offsets[] = {
    P2_XR_PICKUP_HUD_COLOR_SLOT, P2_XR_PICKUP_HUD_COLOR_VALUE_SLOT,
    P2_XR_PICKUP_HUD_TEXT_SLOT, P2_XR_PICKUP_HUD_CHARACTER_SLOT,
};

static struct {
    uint32_t client, surface_table, localize_table, find, symbol_text, target_paint, paint_import;
    uint32_t original[4], replacement[4];
    uint32_t glyph_info, draw_glyph, token, info;
    int ready, failed, active;
} hud;

static _Thread_local struct {
    CPU *cpu;
    uint32_t surface, caption, length;
    int have_wrap_origin, drew_caption;
    float wrap_x, wrap_y;
} paint;

static int guest_range(uint32_t address, unsigned bytes) {
    return address >= 0x10000 && address < RT_IMPORT_BASE &&
           bytes <= RT_IMPORT_BASE - address;
}

static uint32_t locate_pickup_caption(CPU *cpu, uint32_t localize) {
    const uint32_t args[] = {localize, hud.token};
    CPU saved = *cpu;
    uint32_t caption = rt_invoke(cpu, hud.find, args, 2);
    *cpu = saved;
    return caption;
}

static int same_caption(uint32_t expected, uint32_t actual, unsigned count) {
    if (!guest_range(expected, count * 4) || !guest_range(actual, count * 4)) return 0;
    for (unsigned i = 0; i < count; ++i) {
        uint32_t character = R32(actual + i * 4);
        if (R32(expected + i * 4) != character) return 0;
        if (!character) return i + 1 == count;
    }
    return 0;
}

static int use_binding_icon(CPU *cpu, uint32_t target) {
    const uint32_t symbol = target + P2_XR_PICKUP_HUD_ICON_SYMBOL;
    CPU saved = *cpu;
    uint32_t text = rt_invoke(cpu, hud.symbol_text, &symbol, 1);
    *cpu = saved;
    static const char use_binding[] = "use_binding";
    if (!guest_range(text, sizeof(use_binding))) return 0;
    for (unsigned i = 0; i < sizeof(use_binding); ++i)
        if (R8(text + i) != use_binding[i]) return 0;
    return 1;
}

static void text_origin(uint32_t surface, float *x, float *y) {
    *x = (float)(int32_t)R32(surface + TEXT_POS_X) + (float)(int32_t)R32(surface + PANEL_X);
    *y = (float)(int32_t)R32(surface + TEXT_POS_Y) + (float)(int32_t)R32(surface + PANEL_Y);
}

static void draw_half_glyph(CPU *cpu, uint32_t surface, uint32_t character,
                            uint32_t draw_type, float x, float y) {
    CPU saved = *cpu;
    const uint32_t info_args[] = {surface, character, hud.info};
    W32(hud.info + GLYPH_DRAW_TYPE, draw_type);
    if (rt_invoke(cpu, hud.glyph_info, info_args, 3) & 0xff) {
        // Same atlas, glyph bearings and stock VGUI draw state. Scale the
        // positions of the two Vertex_t corners before VGUI clips and queues them.
        uint32_t vertices = R32(hud.info + GLYPH_VERTICES);
        if (guest_range(vertices, 32)) {
            float quad[2][4];
            memcpy(quad, rt_span(cpu, vertices, sizeof(quad)), sizeof(quad));
            for (unsigned i = 0; i < 2; ++i) {
                quad[i][0] = x + (quad[i][0] - x) * 0.5f;
                quad[i][1] = y + (quad[i][1] - y) * 0.5f;
            }
            memcpy(rt_write_span(cpu, vertices, sizeof(quad)), quad, sizeof(quad));
            const uint32_t draw_args[] = {surface, hud.info};
            rt_invoke(cpu, hud.draw_glyph, draw_args, 2);
            paint.drew_caption = 1;
        }
    }
    *cpu = saved;
}

static int surface_call(CPU *cpu, const char *name) {
    unsigned method = 0;
    while (method < sizeof(surface_names) / sizeof(surface_names[0]) &&
           strcmp(name, surface_names[method])) ++method;
    if (method == sizeof(surface_names) / sizeof(surface_names[0])) return 0;
    uint32_t args[] = {R32(cpu->esp + 4), R32(cpu->esp + 8), 0, 0, 0};
    unsigned count = method == COLOR ? 5 : method == COLOR_VALUE ? 2 : 3;
    for (unsigned i = 2; i < count; ++i) args[i] = R32(cpu->esp + 4 + i * 4);
    if (paint.cpu != cpu || args[0] != paint.surface) {
        cpu->eax = rt_invoke(cpu, hud.original[method], args, count);
        return 1;
    }
    switch (method) {
    case COLOR:
        args[4] = 0;
        cpu->eax = rt_invoke(cpu, hud.original[method], args, count);
        return 1;
    case COLOR_VALUE:
        args[1] &= 0xffffffu;
        cpu->eax = rt_invoke(cpu, hud.original[method], args, count);
        return 1;
    case TEXT:
        // The caption's shadow and foreground use the target's own buffer.
        // Text uses a separate surface color, including the controller glyph.
        if (args[1] == paint.caption) {
            float x, y;
            text_origin(paint.surface, &x, &y);
            for (unsigned i = 0; i < paint.length; ++i)
                draw_half_glyph(cpu, paint.surface, R32(paint.caption + 4 * i), args[2], x, y);
        }
        break;
    case CHARACTER:
        // The locator's line-wrap path draws one caption character at a time.
        if (R32(cpu->esp) == hud.client + P2_XR_PICKUP_HUD_CAPTION_CHAR_RETURN) {
            if (!paint.have_wrap_origin) {
                text_origin(paint.surface, &paint.wrap_x, &paint.wrap_y);
                paint.have_wrap_origin = 1;
            }
            draw_half_glyph(cpu, paint.surface, args[1], args[2], paint.wrap_x, paint.wrap_y);
        }
        break;
    }
    cpu->eax = 0;
    return 1;
}
RT_SHIM_PROVIDER(surface_call)

static int paint_target(CPU *cpu, const char *name) {
    if (strcmp(name, paint_name)) return 0;
    const uint32_t args[] = {R32(cpu->esp + 4), R32(cpu->esp + 8)};
    uint32_t target = args[1];
    if (!paint.cpu && guest_range(target, P2_XR_PICKUP_HUD_CAPTION_COUNT + 4)) {
        uint32_t caption = R32(target + P2_XR_PICKUP_HUD_CAPTION);
        uint32_t count = R32(target + P2_XR_PICKUP_HUD_CAPTION_COUNT);
        uint32_t localize = R32(hud.client + P2_XR_PICKUP_HUD_LOCALIZE_GLOBAL);
        uint32_t surface = R32(hud.client + P2_XR_PICKUP_HUD_SURFACE_GLOBAL);
        if (count > 1 && count <= MAX_CAPTION_CHARACTERS &&
            guest_range(localize, 4) && R32(localize) == hud.localize_table &&
            guest_range(surface, TEXT_POS_Y + 4) && R32(surface) == hud.surface_table &&
            same_caption(locate_pickup_caption(cpu, localize), caption, count) &&
            use_binding_icon(cpu, target)) {
            const uint32_t color = R32(surface + DRAW_COLOR_RGBA);
            paint.cpu = cpu;
            paint.surface = surface;
            paint.caption = caption;
            paint.length = count - 1;
            paint.have_wrap_origin = 0;
            paint.drew_caption = 0;
            // Hide the image, its background and its outline only while this
            // one hint draws. Text and all other hints still use stock paint.
            W32(surface + DRAW_COLOR_RGBA, color & 0xffffffu);
            for (unsigned i = 0; i < sizeof(surface_offsets) / sizeof(surface_offsets[0]); ++i)
                W32(hud.surface_table + surface_offsets[i], hud.replacement[i]);
            cpu->eax = rt_invoke(cpu, hud.target_paint, args, 2);
            for (unsigned i = 0; i < sizeof(surface_offsets) / sizeof(surface_offsets[0]); ++i)
                W32(hud.surface_table + surface_offsets[i], hud.original[i]);
            W32(surface + DRAW_COLOR_RGBA, color);
            paint.cpu = NULL;
            static int reported;
            if (!reported && paint.drew_caption) {
                reported = 1;
                fprintf(stderr, "[vision-pickup-hud] Painted stock pickup caption at 50%%\n");
            }
            return 1;
        }
    }
    cpu->eax = rt_invoke(cpu, hud.target_paint, args, 2);
    return 1;
}
RT_SHIM_PROVIDER(paint_target)

static int same_signature(CPU *cpu, uint32_t address, const unsigned char *prefix, size_t bytes) {
    return !memcmp(rt_span(cpu, address, bytes), prefix, bytes);
}

static int resolve_hud(CPU *cpu) {
    const GuestModule *client = rt_find_module("client.so");
    const GuestModule *surface = rt_find_module("vguimatsurface.so");
    const GuestModule *localize = rt_find_module("localize.so");
    if (!cpu || !client || !surface || !localize) return 0;
    hud.client = client->base;
    hud.surface_table = surface->base + P2_XR_PICKUP_HUD_SURFACE_TABLE;
    hud.localize_table = localize->base + P2_XR_PICKUP_HUD_LOCALIZE_TABLE;
    hud.target_paint = hud.client + P2_XR_PICKUP_HUD_TARGET_PAINT;
    hud.find = localize->base + P2_XR_PICKUP_HUD_FIND;
    hud.symbol_text = hud.client + P2_XR_PICKUP_HUD_SYMBOL_TEXT;
    hud.glyph_info = surface->base + P2_XR_PICKUP_HUD_GLYPH_INFO;
    hud.draw_glyph = surface->base + P2_XR_PICKUP_HUD_DRAW_GLYPH;
    static const struct {
        uint32_t offset, rva;
        const unsigned char *signature;
        unsigned size;
    } methods[] = {
#define SURFACE_METHOD(upper, lower) {P2_XR_PICKUP_HUD_##upper##_SLOT, P2_XR_PICKUP_HUD_##upper, \
                pickup_hud_sig_##lower, sizeof(pickup_hud_sig_##lower)}
        SURFACE_METHOD(COLOR, color), SURFACE_METHOD(COLOR_VALUE, color_value),
        SURFACE_METHOD(TEXT, text), SURFACE_METHOD(CHARACTER, character),
        SURFACE_METHOD(GLYPH_INFO, glyph_info), SURFACE_METHOD(DRAW_GLYPH, draw_glyph),
#undef SURFACE_METHOD
    };
    if (R32(hud.client + P2_XR_PICKUP_HUD_TARGET_SLOT) != hud.target_paint ||
        R32(hud.localize_table + 0x28) != hud.find ||
        !same_signature(cpu, hud.target_paint, pickup_hud_sig_target_paint, sizeof(pickup_hud_sig_target_paint)) ||
        !same_signature(cpu, hud.symbol_text, pickup_hud_sig_symbol_text, sizeof(pickup_hud_sig_symbol_text)) ||
        !same_signature(cpu, hud.find, pickup_hud_sig_find, sizeof(pickup_hud_sig_find))) return -1;
    for (unsigned i = 0; i < sizeof(methods) / sizeof(methods[0]); ++i) {
        uint32_t address = surface->base + methods[i].rva;
        if (R32(hud.surface_table + methods[i].offset) != address ||
            !same_signature(cpu, address, methods[i].signature, methods[i].size)) return -1;
        if (i < sizeof(surface_names) / sizeof(surface_names[0])) {
            hud.original[i] = address;
            hud.replacement[i] = rt_dynamic_import(surface_names[i]);
            if (!hud.replacement[i]) return -1;
        }
    }
    hud.paint_import = rt_dynamic_import(paint_name);
    if (!hud.paint_import) return -1;
    static const char token[] = "#Instructor_Pick_Up";
    hud.info = rt_alloc(GLYPH_RENDER_INFO_SIZE + sizeof(token));
    if (!hud.info) return -1;
    hud.token = hud.info + GLYPH_RENDER_INFO_SIZE;
    memcpy(rt_write_span(cpu, hud.token, sizeof(token)), token, sizeof(token));
    fprintf(stderr, "[vision-pickup-hud] Verified stock pickup caption hooks\n");
    return 1;
}
#endif

void p2_vision_pickup_hud_set_active(CPU *cpu, int active) {
#if P2_XR_PICKUP_HUD_PROFILE
    if (hud.active == active || hud.failed) return;
    if (active && !hud.ready) {
        int result = resolve_hud(cpu);
        if (result <= 0) {
            hud.failed = result < 0;
            if (hud.failed) fprintf(stderr, "[vision-pickup-hud] Stock caption profile mismatch\n");
            return;
        }
        hud.ready = 1;
    }
    W32(hud.client + P2_XR_PICKUP_HUD_TARGET_SLOT, active ? hud.paint_import : hud.target_paint);
    hud.active = active;
#else
    (void)cpu;
    (void)active;
#endif
}
#endif
