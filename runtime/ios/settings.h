// Réglages iOS (app Réglages) traduits en variables P2_* : runtime/ios/settings.c.
#pragma once
#include <stddef.h>

#define P2_IOS_FRAME_RATE_KEY "P2MaxFPS"
#define P2_IOS_FRAME_RATE_ENV "P2_IOS_MAX_FPS"

typedef struct { const char *key, *env, *on, *off; } rt_ios_setting;
extern const rt_ios_setting rt_ios_settings[];
extern const int rt_ios_settings_count;

// Lit la valeur d'un réglage (« 1 »/« 0 » pour un interrupteur) ; 0 si absent.
typedef int (*rt_ios_settings_get)(void *ctx, const char *key, char *out, size_t size);
// Pose les variables des réglages présents, sauf celles déjà définies ; rend
// leur nombre et, dans summary, la liste « VAR=valeur, ... ».
int rt_ios_settings_apply(rt_ios_settings_get get, void *ctx, char *summary, size_t size);
// Sur iOS : depuis les préférences de l'app.
int rt_ios_settings_load(char *summary, size_t size);
// The stored choice is independent of the maximum refresh rate of the current screen.
int rt_ios_requested_frame_rate(int ipad, const char *preference);
int rt_ios_frame_rate_for_screen(int requested, int screen_maximum);
int rt_ios_is_ipad(void);
int rt_ios_display_frame_rate(void);
int rt_ios_uses_native_resolution_by_default(void);
// Taille de rendu (pixels, paysage) : écran en points × échelle de rendu (sdl_ios.m).
void rt_ios_render_size(int *w, int *h);
