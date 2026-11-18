// Réglages iOS (runtime/ios/settings.c) : traduction en variables P2_*,
// priorité des variables déjà posées, concordance avec ios/Settings.bundle.
#include "checks.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../runtime/ios/settings.c"

typedef struct { const char *key, *value; } Pref;
static int fake_get(void *ctx, const char *key, char *out, size_t size) {
    for (const Pref *p = ctx; p->key; ++p)
        if (!strcmp(p->key, key)) { snprintf(out, size, "%s", p->value); return 1; }
    return 0;
}
static void clear_env(void) {
    for (int i = 0; i < rt_ios_settings_count; ++i) unsetenv(rt_ios_settings[i].env);
}

RT_CHECK(ios_settings_become_environment) {
    clear_env();
    Pref prefs[] = {{"P2ResolutionScale", "1.5"}, {"P2ShowFPS", "0"}, {"P2BackTap", "1"}, {"P2TouchControls", "auto"},
                    {"P2PortalButtons", "1"}, {"P2Log", "0"}, {"P2BackTapInvert", "1"}, {NULL, NULL}};
    char summary[512];
    int n = rt_ios_settings_apply(fake_get, prefs, summary, sizeof(summary));
    assert(n == 5);
    assert(!strcmp(getenv("P2_IOS_RENDER_SCALE"), "1.5"));
    assert(!strcmp(getenv("P2_SHOW_FPS"), "0"));                 // interrupteur éteint
    assert(!strcmp(getenv("P2_BACKTAP"), "1"));
    assert(!strcmp(getenv("P2_BACKTAP_INVERT"), "1"));
    assert(!strcmp(getenv("P2_PORTAL_BUTTONS"), "1"));
    assert(!getenv("P2_TOUCH_CONTROLS"));                         // « auto » : défaut du code
    assert(!getenv("P2_LOG_FILE"));                               // journal éteint : aucune variable
    assert(!getenv("P2_IOS_MAX_FPS"));                            // jamais touché
    assert(strstr(summary, "P2_IOS_RENDER_SCALE=1.5") && strstr(summary, "P2_SHOW_FPS=0"));
    clear_env();
}

// Une variable déjà posée (devicectl, bancs) prime sur le réglage.
RT_CHECK(ios_settings_yield_to_existing_environment) {
    clear_env();
    setenv("P2_IOS_RENDER_SCALE", "native", 1);
    Pref prefs[] = {{"P2ResolutionScale", "1"}, {"P2Log", "1"}, {NULL, NULL}};
    char summary[256];
    assert(rt_ios_settings_apply(fake_get, prefs, summary, sizeof(summary)) == 1);
    assert(!strcmp(getenv("P2_IOS_RENDER_SCALE"), "native"));
    assert(!strcmp(getenv("P2_LOG_FILE"), "Documents/game.log"));
    clear_env();
}

RT_CHECK(ios_frame_rate_defaults_and_saved_choice) {
    clear_env();
    assert(rt_ios_requested_frame_rate(1, NULL) == 120);
    assert(rt_ios_requested_frame_rate(0, NULL) == 60);
    assert(rt_ios_requested_frame_rate(1, "auto") == 120);
    assert(rt_ios_requested_frame_rate(1, "broken") == 120);
    assert(rt_ios_requested_frame_rate(0, "120") == 120);

    Pref prefs[] = {{P2_IOS_FRAME_RATE_KEY, "60"}, {NULL, NULL}};
    assert(rt_ios_settings_apply(fake_get, prefs, NULL, 0) == 1);
    int requested = rt_ios_requested_frame_rate(1, getenv(P2_IOS_FRAME_RATE_ENV));
    assert(requested == 60);
    assert(rt_ios_frame_rate_for_screen(requested, 120) == 60);
    assert(rt_ios_frame_rate_for_screen(120, 60) == 60);
    assert(rt_ios_frame_rate_for_screen(120, 120) == 120);
    clear_env();
}

RT_CHECK(ios_fps_counter_defaults_and_saved_choice) {
    clear_env();
    assert(!rt_ios_show_fps(getenv(P2_IOS_SHOW_FPS_ENV)));
    assert(!rt_ios_show_fps("0"));
    assert(!rt_ios_show_fps("false"));
    assert(!rt_ios_show_fps("invalid"));
    assert(rt_ios_show_fps("true"));

    Pref prefs[] = {{P2_IOS_SHOW_FPS_KEY, "1"}, {NULL, NULL}};
    assert(rt_ios_settings_apply(fake_get, prefs, NULL, 0) == 1);
    assert(rt_ios_show_fps(getenv(P2_IOS_SHOW_FPS_ENV)));
    assert(!getenv(P2_IOS_FRAME_RATE_ENV));
    setenv(P2_IOS_SHOW_FPS_ENV, "0", 1);
    assert(rt_ios_settings_apply(fake_get, prefs, NULL, 0) == 0);
    assert(!rt_ios_show_fps(getenv(P2_IOS_SHOW_FPS_ENV)));
    clear_env();
}

// Chaque réglage de la page iOS est lu par le code, et inversement
// (P2TouchTrackpad est lu directement par touch_controls.m).
RT_CHECK(ios_settings_match_settings_bundle) {
    FILE *f = fopen("ios/Settings.bundle/Root.plist", "r");
    assert(f);
    static char plist[65536];
    size_t n = fread(plist, 1, sizeof(plist) - 1, f);
    fclose(f);
    plist[n] = 0;
    for (int i = 0; i < rt_ios_settings_count; ++i) {
        char needle[128];
        snprintf(needle, sizeof(needle), "<string>%s</string>", rt_ios_settings[i].key);
        assert(strstr(plist, needle));
    }
    int keys = 0;
    for (const char *p = plist; (p = strstr(p, "<key>Key</key>")); ++p) {
        const char *v = strstr(p, "<string>") + 8, *e = strstr(v, "</string>");
        char key[64];
        snprintf(key, sizeof(key), "%.*s", (int)(e - v), v);
        int known = !strcmp(key, "P2TouchTrackpad");
        for (int i = 0; i < rt_ios_settings_count; ++i) known |= !strcmp(key, rt_ios_settings[i].key);
        assert(known);
        ++keys;
    }
    assert(keys == rt_ios_settings_count + 1);
}
