// Pont Steam : méthodes Workshop à SteamParamStringArray_t (runtime/steam_workshop.c).
// Appel invité par la vtable du mandataire -> method_shim -> marshalling manuel ->
// vraie fonction flat de la libsteam_api.dylib officielle -> objet hôte de test.
// Avant ce pont, ces emplacements finissaient en rt_trap (abort du jeu en
// ouvrant les salles de la communauté).
#include "checks.h"
#include "steam.h"
#include <stdio.h>

#define STACK 0x2001c000u
#define SCRATCH 0x2001d000u

typedef struct { const char **strings; int32_t count; } HostStrings;
typedef struct { void **vtable; } FakeStorage;
static void *workshop_vtable[64];
static FakeStorage fake_workshop = {workshop_vtable};

static int32_t seen_type; static uint32_t seen_start, seen_count, seen_days;
static uint64_t seen_id;
static char seen_tags[4][32]; static int32_t seen_tag_count = -1, seen_second_count = -1;
static void record(const HostStrings *tags, const HostStrings *second) {
    seen_tag_count = tags ? tags->count : -1;
    for (int32_t i = 0; tags && i < tags->count && i < 4; ++i) snprintf(seen_tags[i], sizeof(seen_tags[i]), "%s", tags->strings[i]);
    seen_second_count = second ? second->count : -1;
}
static uint64_t fake_enumerate(FakeStorage *self, int32_t type, uint32_t start, uint32_t count, uint32_t days,
                               HostStrings *tags, HostStrings *user_tags) {
    assert(self == &fake_workshop);
    seen_type = type; seen_start = start; seen_count = count; seen_days = days; record(tags, user_tags);
    return UINT64_C(0x0123456789abcdef);
}
static uint64_t fake_shared(FakeStorage *self, uint64_t user, uint32_t start, HostStrings *required, HostStrings *excluded) {
    assert(self == &fake_workshop);
    seen_id = user; seen_start = start; record(required, excluded);
    return UINT64_C(0x00000000fedcba98);
}
static bool fake_tags(FakeStorage *self, uint64_t handle, HostStrings *tags) {
    assert(self == &fake_workshop);
    seen_id = handle; record(tags, NULL);
    return true;
}

static const SteamMethodInfo *workshop_method(const char *name) {
    for (size_t i = 0; i < steam_method_count; ++i)
        if (!strcmp(steam_methods[i].name, name)) return &steam_methods[i];
    assert(!"Steam method missing from the generated table");
    return NULL;
}
static CPU workshop_call(uint32_t proxy, const char *name, unsigned count, const uint32_t *args) {
    const SteamMethodInfo *m = workshop_method(name);
    CPU c; rt_cpu_reset(&c); c.esp = STACK;
    for (unsigned i = count; i; --i) PUSH(&c, args[i - 1]);
    PUSH(&c, proxy);
    uint32_t before = c.esp;
    rt_call(&c, R32(R32(proxy) + 4 * m->slot), RT_RETURN_SENTINEL);
    assert(c.eip == RT_RETURN_SENTINEL && c.esp == before);
    return c;
}
static uint32_t put_string(uint32_t at, const char *s) { memcpy(GPTR(at), s, strlen(s) + 1); return at; }

RT_CHECK(steam_workshop_string_arrays_are_bridged) {
    static const char *const names[] = {
        "STEAMREMOTESTORAGE_INTERFACE_VERSION016::EnumeratePublishedWorkshopFiles",
        "STEAMREMOTESTORAGE_INTERFACE_VERSION016::EnumerateUserSharedWorkshopFiles",
        "STEAMREMOTESTORAGE_INTERFACE_VERSION016::UpdatePublishedFileTags"};
    for (int i = 0; i < 3; ++i) {
        assert(!workshop_method(names[i])->fn);           // toujours absent du code généré
        assert(steam_manual_method(names[i]));            // mais servi par steam_workshop.c
    }
    assert(!steam_manual_method("STEAMUGC_INTERFACE_VERSION016::GetQueryUGCResult"));   // reste un piège nommé
    if (!steam_dylib_available()) { printf("skip steam workshop marshalling: %s not loadable\n", steam_dylib_path()); return; }

    workshop_vtable[workshop_method(names[0])->slot] = (void *)fake_enumerate;
    workshop_vtable[workshop_method(names[1])->slot] = (void *)fake_shared;
    workshop_vtable[workshop_method(names[2])->slot] = (void *)fake_tags;
    CPU cpu; rt_cpu_reset(&cpu);
    uint32_t storage = steam_proxy(&cpu, &fake_workshop, "STEAMREMOTESTORAGE_INTERFACE_VERSION016");

    // Forme du site d'appel de client.so (0x1613f515) : type, début, min(n, 50), 7 jours, étiquettes, NULL.
    uint32_t list = SCRATCH + 0x100, array = SCRATCH + 0x80;
    W32(list, put_string(SCRATCH + 0x200, "Singleplayer"));
    W32(list + 4, put_string(SCRATCH + 0x220, "Cooperative"));
    W32(array, list); W32(array + 4, 2);
    uint32_t enumerate[] = {3, 50, 50, 7, array, 0};
    CPU c = workshop_call(storage, names[0], 6, enumerate);
    assert(c.eax == 0x89abcdefu && c.edx == 0x01234567u);   // SteamAPICall_t dans edx:eax
    assert(seen_type == 3 && seen_start == 50 && seen_count == 50 && seen_days == 7);
    assert(seen_tag_count == 2 && !strcmp(seen_tags[0], "Singleplayer") && !strcmp(seen_tags[1], "Cooperative"));
    assert(seen_second_count == -1);                         // pointeur invité nul -> NULL hôte

    // Tableau vide (pointeur de chaînes nul, compte 0) accepté.
    uint32_t empty = SCRATCH + 0x90; W32(empty, 0); W32(empty + 4, 0);
    uint32_t shared[] = {0x00000007u, 0x01100001u, 12, array, empty};   // CSteamID par valeur : 8 octets
    c = workshop_call(storage, names[1], 5, shared);
    assert(c.eax == 0xfedcba98u && c.edx == 0);
    assert(seen_id == UINT64_C(0x0110000100000007) && seen_start == 12 && seen_tag_count == 2 && seen_second_count == 0);

    W32(array + 4, 1);
    uint32_t update[] = {0x55667788u, 0x11223344u, array};
    c = workshop_call(storage, names[2], 3, update);
    assert(c.eax == 1 && seen_id == UINT64_C(0x1122334455667788) && seen_tag_count == 1);
    assert(!strcmp(seen_tags[0], "Singleplayer"));
}
