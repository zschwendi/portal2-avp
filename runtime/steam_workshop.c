// Pont Steam : méthodes ISteamRemoteStorage016 à SteamParamStringArray_t que
// tools/gen_steam.py ne sait pas marshaller (tableau de chaînes sans taille
// déclarée). Sans elles, l'énumération des salles de la communauté
// (client.so, CBaseModPanel : EnumeratePublishedWorkshopFiles, emplacement 53,
// étiquettes « Singleplayer »/« Cooperative ») tombait sur le piège nommé de
// method_shim et le jeu s'arrêtait (abort).
//
// SteamParamStringArray_t { const char **m_ppStrings; int32 m_nNumStrings; } :
// i386 = deux mots ; hôte ARM64 = pointeur 8 octets puis int32 (mêmes champs,
// passés par pointeur, donc l'alignement de la structure n'importe pas).
// Le résultat est celui de la fonction flat chargée : vrai client Steam sur Mac,
// stub hors ligne sur iOS/visionOS (k_uAPICallInvalid, que l'invité traite comme
// un échec). Rien n'est inventé ici.
#include "steam.h"
#include <stdlib.h>
#include <string.h>

#define MAX_STRINGS 1024u   // bien au-delà des étiquettes du Workshop

typedef struct { const char **strings; int32_t count; } HostStringArray;

// Copie hôte d'un SteamParamStringArray_t invité ; NULL si l'adresse est nulle.
// Les chaînes restent en mémoire invitée (pointeurs hôtes vers elles), valides
// le temps de l'appel. *owned est libéré par l'appelant.
static HostStringArray *host_array(CPU *c, uint32_t guest, HostStringArray *out, const char ***owned) {
    *owned = NULL;
    if (!guest) return NULL;
    rt_span(c, guest, 8);
    uint32_t strings = R32(guest);
    int32_t count = (int32_t)R32(guest + 4);
    if (count < 0 || (uint32_t)count > MAX_STRINGS)
        rt_trap(c, c->eip, "Steam: SteamParamStringArray_t with an invalid string count");
    if (count && !strings)
        rt_trap(c, c->eip, "Steam: SteamParamStringArray_t with strings missing");
    const char **host = NULL;
    if (count) {
        const uint32_t *table = steam_in_buffer(c, strings, count, 4);
        if (!(host = calloc((size_t)count, sizeof(*host)))) rt_trap(c, c->eip, "Steam: out of memory");
        for (int32_t i = 0; i < count; ++i) {
            uint32_t item;
            memcpy(&item, table + i, 4);
            host[i] = steam_in_string(c, item);
        }
    }
    *owned = host;
    *out = (HostStringArray){host, count};
    return out;
}

static uint64_t arg64(uint32_t at) { return (uint64_t)R32(at) | (uint64_t)R32(at + 4) << 32; }

// EnumeratePublishedWorkshopFiles(EWorkshopEnumerationType, uint32 start, uint32 count,
//                                 uint32 days, SteamParamStringArray_t *tags, SteamParamStringArray_t *userTags)
static void enumerate_published(CPU *c, void *self, uint32_t args, uint32_t sret) {
    (void)sret;
    typedef uint64_t (*F)(void *, int32_t, uint32_t, uint32_t, uint32_t, HostStringArray *, HostStringArray *);
    F fn = (F)steam_flat(c, "SteamAPI_ISteamRemoteStorage_EnumeratePublishedWorkshopFiles");
    HostStringArray tags, user_tags;
    const char **owned_tags, **owned_user;
    HostStringArray *a = host_array(c, R32(args + 16), &tags, &owned_tags);
    HostStringArray *b = host_array(c, R32(args + 20), &user_tags, &owned_user);
    uint64_t r = fn(self, (int32_t)R32(args), R32(args + 4), R32(args + 8), R32(args + 12), a, b);
    free(owned_tags); free(owned_user);
    steam_ret64(c, r);
}

// EnumerateUserSharedWorkshopFiles(CSteamID (8 octets par valeur), uint32 start,
//                                  SteamParamStringArray_t *required, SteamParamStringArray_t *excluded)
static void enumerate_shared(CPU *c, void *self, uint32_t args, uint32_t sret) {
    (void)sret;
    typedef uint64_t (*F)(void *, uint64_t, uint32_t, HostStringArray *, HostStringArray *);
    F fn = (F)steam_flat(c, "SteamAPI_ISteamRemoteStorage_EnumerateUserSharedWorkshopFiles");
    HostStringArray required, excluded;
    const char **owned_required, **owned_excluded;
    HostStringArray *a = host_array(c, R32(args + 12), &required, &owned_required);
    HostStringArray *b = host_array(c, R32(args + 16), &excluded, &owned_excluded);
    uint64_t r = fn(self, arg64(args), R32(args + 8), a, b);
    free(owned_required); free(owned_excluded);
    steam_ret64(c, r);
}

// UpdatePublishedFileTags(PublishedFileUpdateHandle_t (uint64), SteamParamStringArray_t *tags) -> bool
static void update_tags(CPU *c, void *self, uint32_t args, uint32_t sret) {
    (void)sret;
    typedef bool (*F)(void *, uint64_t, HostStringArray *);
    F fn = (F)steam_flat(c, "SteamAPI_ISteamRemoteStorage_UpdatePublishedFileTags");
    HostStringArray tags;
    const char **owned;
    HostStringArray *a = host_array(c, R32(args + 8), &tags, &owned);
    bool r = fn(self, arg64(args), a);
    free(owned);
    c->eax = r ? 1u : 0u;
}

static const struct { const char *name; steam_method_fn fn; } manual[] = {
    {"STEAMREMOTESTORAGE_INTERFACE_VERSION016::EnumeratePublishedWorkshopFiles", enumerate_published},
    {"STEAMREMOTESTORAGE_INTERFACE_VERSION016::EnumerateUserSharedWorkshopFiles", enumerate_shared},
    {"STEAMREMOTESTORAGE_INTERFACE_VERSION016::UpdatePublishedFileTags", update_tags},
};

steam_method_fn steam_manual_method(const char *name) {
    for (size_t i = 0; i < sizeof(manual) / sizeof(*manual); ++i)
        if (!strcmp(manual[i].name, name)) return manual[i].fn;
    return NULL;
}
