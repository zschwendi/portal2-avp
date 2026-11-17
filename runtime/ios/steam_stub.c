// Stub Steam hôte pour le build iOS seulement (pas de client Steam sur iOS).
// Décision de l'utilisateur du 25 octobre 2026 : stub maison minimal, pour sa
// propre copie du jeu et un usage personnel ; jamais compilé dans le build Mac
// (qui parle au vrai client Steam), jamais fusionné dans feat/tier0-spike.
//
// Il remplace libsteam_api.dylib derrière le pont runtime/steam.c, qui le
// trouve par dlsym (P2_STEAM_API_DYLIB désigne l'exécutable lui-même). Mode
// hors ligne : utilisateur connecté qui possède l'app, aucun callback, pas de
// succès, de statistiques, de nuage ni de multijoueur. Les fonctions plates
// sans réponse particulière sont générées (steam_stub_generated.c) et
// renvoient 0, false, NULL ou "".
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default"), used))

// ---- objets d'interface : une vtable de méthodes qui renvoient 0 ----
// Le pont n'appelle la vtable hôte que pour quelques interfaces hors API
// plate (GameCoordinator, GameStats, GetCSERIPPort) : « rien » leur convient.
static uint64_t zero_method(void) { return 0; }
static void *zero_vtable[64];
typedef struct { void **vtable; char version[64]; } StubInterface;
static StubInterface interfaces[64];
static int interface_count;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

void *steam_stub_interface(const char *version) {
    if (!version) return NULL;
    pthread_mutex_lock(&lock);
    if (!zero_vtable[0]) for (int i = 0; i < 64; ++i) zero_vtable[i] = (void *)zero_method;
    StubInterface *found = NULL;
    for (int i = 0; i < interface_count && !found; ++i)
        if (!strcmp(interfaces[i].version, version)) found = &interfaces[i];
    if (!found && interface_count < 64) {
        found = &interfaces[interface_count++];
        found->vtable = zero_vtable;
        snprintf(found->version, sizeof(found->version), "%s", version);
        fprintf(stderr, "[steam-stub] interface %s\n", version);
    }
    pthread_mutex_unlock(&lock);
    return found;
}

// ---- cycle de vie ----
EXPORT bool SteamAPI_InitSafe(void) { fprintf(stderr, "[steam-stub] hors ligne : stub iOS, app 620\n"); return true; }
EXPORT void SteamAPI_Shutdown(void) {}
EXPORT bool SteamAPI_RestartAppIfNecessary(uint32_t app) { (void)app; return false; }
EXPORT int32_t SteamAPI_GetHSteamPipe(void) { return 1; }
EXPORT int32_t SteamAPI_GetHSteamUser(void) { return 1; }
EXPORT void SteamAPI_SetTryCatchCallbacks(bool on) { (void)on; }
EXPORT const char *SteamAPI_GetSteamInstallPath(void) { return ""; }
EXPORT int32_t SteamGameServer_GetHSteamPipe(void) { return 0; }
EXPORT int32_t SteamGameServer_GetHSteamUser(void) { return 0; }
EXPORT uint32_t SteamGameServer_GetIPCCallCount(void) { return 0; }
EXPORT void SteamGameServer_Shutdown(void) {}
EXPORT bool SteamInternal_GameServer_Init(uint32_t ip, uint16_t a, uint16_t b, uint16_t q, int32_t mode, const char *v) {
    (void)ip; (void)a; (void)b; (void)q; (void)mode; (void)v; return false;
}

// ---- callbacks : aucun ----
EXPORT void SteamAPI_ManualDispatch_Init(void) {}
EXPORT void SteamAPI_ManualDispatch_RunFrame(int32_t pipe) { (void)pipe; }
EXPORT bool SteamAPI_ManualDispatch_GetNextCallback(int32_t pipe, void *message) { (void)pipe; (void)message; return false; }
EXPORT void SteamAPI_ManualDispatch_FreeLastCallback(int32_t pipe) { (void)pipe; }
EXPORT bool SteamAPI_ManualDispatch_GetAPICallResult(int32_t pipe, uint64_t call, void *out, int32_t size, int32_t expected, bool *failed) {
    (void)pipe; (void)call; (void)out; (void)size; (void)expected; if (failed) *failed = true; return false;
}

// ---- tickets d'authentification ----
// En solo, le client se connecte quand même au serveur local et exige un
// ticket non vide (« STEAM certificate length error 0/2048 »). Ticket
// factice, reconnu par le côté serveur du stub ; jamais envoyé ailleurs.
int32_t steam_stub_ticket(void *buffer, int32_t capacity) {
    static const unsigned char magic[16] = "P2-iOS-offline";
    if (!buffer || capacity < (int32_t)sizeof(magic) + 8) return 0;
    memcpy(buffer, magic, sizeof(magic));
    uint64_t id = 76561197960265729ull;
    memcpy((unsigned char *)buffer + sizeof(magic), &id, sizeof(id));
    return (int32_t)sizeof(magic) + 8;
}

// ---- Workshop (salles de la communauté) : pas de service hors ligne ----
// Marshallées à la main par runtime/steam_workshop.c, donc absentes du code
// généré. k_uAPICallInvalid / false : l'invité prend son chemin d'échec
// (aucun abonnement, téléchargement ni nuage simulé). Les salles locales
// passent par runtime/custom_levels.c, pas par Steam.
static void workshop_unavailable(const char *method) {
    static int logged;
    if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED))
        fprintf(stderr, "[steam-stub] Workshop indisponible hors ligne (%s) : appel refusé\n", method);
}
EXPORT uint64_t SteamAPI_ISteamRemoteStorage_EnumeratePublishedWorkshopFiles(void *self, int32_t type, uint32_t start,
        uint32_t count, uint32_t days, void *tags, void *user_tags) {
    (void)self; (void)type; (void)start; (void)count; (void)days; (void)tags; (void)user_tags;
    workshop_unavailable("EnumeratePublishedWorkshopFiles"); return 0;
}
EXPORT uint64_t SteamAPI_ISteamRemoteStorage_EnumerateUserSharedWorkshopFiles(void *self, uint64_t user, uint32_t start,
        void *required, void *excluded) {
    (void)self; (void)user; (void)start; (void)required; (void)excluded;
    workshop_unavailable("EnumerateUserSharedWorkshopFiles"); return 0;
}
EXPORT bool SteamAPI_ISteamRemoteStorage_UpdatePublishedFileTags(void *self, uint64_t handle, void *tags) {
    (void)self; (void)handle; (void)tags;
    workshop_unavailable("UpdatePublishedFileTags"); return false;
}

// ---- crochets d'avertissement (appelés par steam.c hors code généré) ----
EXPORT void SteamAPI_ISteamClient_SetWarningMessageHook(void *self, void *hook) { (void)self; (void)hook; }
EXPORT void SteamAPI_ISteamUtils_SetWarningMessageHook(void *self, void *hook) { (void)self; (void)hook; }

// ---- accès aux interfaces ----
// SteamInternal_ContextInit(ctx) : ctx = {pFn, compteur, contexte} ; pFn
// remplit le contexte quand le compteur global a changé.
typedef struct { void (*fn)(void *); uintptr_t counter; void *context[32]; } Context;
EXPORT void *SteamInternal_ContextInit(void *data) {
    Context *ctx = data;
    if (ctx->counter != 1) { ctx->counter = 1; ctx->fn(ctx->context); }
    return ctx->context;
}
EXPORT void *SteamInternal_CreateInterface(const char *version) { return steam_stub_interface(version); }
EXPORT void *SteamInternal_FindOrCreateUserInterface(int32_t user, const char *version) {
    (void)user; return steam_stub_interface(version);
}
EXPORT void *SteamInternal_FindOrCreateGameServerInterface(int32_t user, const char *version) {
    (void)user; return steam_stub_interface(version);
}
#endif
