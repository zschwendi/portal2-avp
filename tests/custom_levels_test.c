// runtime/custom_levels.c sur des cartes VBSP synthétiques (aucune donnée du jeu).
// Usage : custom_levels_test <dossier de travail vide>. Code de sortie 0 = succès.
#include "custom_levels.h"
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char root[1024];
static const char *at(const char *relative) {
    static char paths[8][2048];
    static int next;
    char *path = paths[next++ % 8];
    snprintf(path, 2048, "%s/%s", root, relative);
    return path;
}
static void put(const char *relative, const void *data, size_t size) {
    FILE *f = fopen(at(relative), "wb");
    assert(f && fwrite(data, 1, size, f) == size && !fclose(f));
}
static size_t get(const char *relative, char *out, size_t capacity) {
    FILE *f = fopen(at(relative), "rb");
    if (!f) return (size_t)-1;
    size_t n = fread(out, 1, capacity, f);
    fclose(f);
    return n;
}
static int exists(const char *relative) { struct stat st; return !lstat(at(relative), &st); }
static void w32(unsigned char *p, int32_t v) { for (int i = 0; i < 4; ++i) p[i] = (unsigned char)((uint32_t)v >> (8 * i)); }

// Carte minimale : en-tête 1036 octets, lumps 0/1/5/14 non vides, pakfile facultatif.
static size_t make_bsp(unsigned char *out, int32_t version, int pakfile, unsigned char fill) {
    memset(out, 0, 1036);
    memcpy(out, "VBSP", 4);
    w32(out + 4, version);
    size_t size = 1036;
    const int lumps[] = {0, 1, 5, 14, 40};
    for (int i = 0; i < (pakfile ? 5 : 4); ++i) {
        w32(out + 8 + 16 * lumps[i], (int32_t)size);
        w32(out + 12 + 16 * lumps[i], 16);
        memset(out + size, fill + i, 16);
        size += 16;
    }
    w32(out + 8 + 64 * 16, 7);   // mapRevision
    return size;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    snprintf(root, sizeof(root), "%s", argv[1]);
    unsigned char bsp[2048], other[2048];
    size_t size = make_bsp(bsp, 21, 1, 0x10), other_size = make_bsp(other, 21, 0, 0x60);

    // ---- noms
    assert(p2cl_name_valid("sp_my-chamber_2") && !p2cl_name_valid("") && !p2cl_name_valid("-x"));
    assert(!p2cl_name_valid("../x") && !p2cl_name_valid("a/b") && !p2cl_name_valid("A") && !p2cl_name_valid("a b"));
    char name[80];
    char longname[100]; memset(longname, 'a', 65); longname[65] = 0;
    assert(!p2cl_name_valid(longname));
    assert(p2cl_name_from_path("/x/Downloads/My Chamber (v2).BSP", name, sizeof(name)) == P2CL_OK && !strcmp(name, "my_chamber__v2_"));
    assert(p2cl_name_from_path("--rm.bsp", name, sizeof(name)) == P2CL_OK && !strcmp(name, "rm"));
    assert(p2cl_name_from_path("dir/.bsp", name, sizeof(name)) == P2CL_ERR_NAME);

    // ---- en-tête VBSP
    put("ok.bsp", bsp, size);
    p2cl_bsp_info info;
    assert(p2cl_inspect_bsp(at("ok.bsp"), &info) == P2CL_OK);
    assert(info.version == 21 && info.map_revision == 7 && info.size == size && info.has_pakfile);
    put("plain.bsp", other, other_size);
    assert(p2cl_inspect_bsp(at("plain.bsp"), &info) == P2CL_OK && !info.has_pakfile);
    unsigned char bad[2048];
    memcpy(bad, bsp, size); memcpy(bad, "IBSP", 4); put("bad.bsp", bad, size);
    assert(p2cl_inspect_bsp(at("bad.bsp"), NULL) == P2CL_ERR_NOT_BSP);
    memcpy(bad, bsp, size); w32(bad + 4, 20); put("bad.bsp", bad, size);
    assert(p2cl_inspect_bsp(at("bad.bsp"), NULL) == P2CL_ERR_VERSION);
    put("bad.bsp", bsp, 600);                                   // tronqué dans l'en-tête
    assert(p2cl_inspect_bsp(at("bad.bsp"), NULL) == P2CL_ERR_CORRUPT);
    put("bad.bsp", bsp, size - 1);                              // dernier lump hors du fichier
    assert(p2cl_inspect_bsp(at("bad.bsp"), NULL) == P2CL_ERR_CORRUPT);
    memcpy(bad, bsp, size); w32(bad + 12 + 16 * 14, 0); put("bad.bsp", bad, size);   // modèles vides
    assert(p2cl_inspect_bsp(at("bad.bsp"), NULL) == P2CL_ERR_CORRUPT);
    memcpy(bad, bsp, size); w32(bad + 8 + 16 * 3, 100); w32(bad + 12 + 16 * 3, 4); put("bad.bsp", bad, size); // lump dans l'en-tête
    assert(p2cl_inspect_bsp(at("bad.bsp"), NULL) == P2CL_ERR_CORRUPT);
    memcpy(bad, bsp, size); w32(bad + 12 + 16 * 2, -5); put("bad.bsp", bad, size);
    assert(p2cl_inspect_bsp(at("bad.bsp"), NULL) == P2CL_ERR_CORRUPT);
    put("bad.bsp", "VB", 2);
    assert(p2cl_inspect_bsp(at("bad.bsp"), NULL) == P2CL_ERR_NOT_BSP);
    assert(!symlink(at("ok.bsp"), at("link.bsp")));
    assert(p2cl_inspect_bsp(at("link.bsp"), NULL) == P2CL_ERR_LINK);
    assert(p2cl_inspect_bsp(at("missing.bsp"), NULL) == P2CL_ERR_NOT_FOUND);

    // ---- installation : jeu absent, puis arbre du jeu avec campagne et sauvegarde
    char map[96];
    assert(mkdir(at("game"), 0755) == 0);
    assert(p2cl_install(at("game"), at("ok.bsp"), "mine", 0, map, sizeof(map)) == P2CL_ERR_NOT_FOUND);
    assert(!exists("game/portal2"));                            // rien de créé hors maps/custom
    assert(!mkdir(at("game/portal2"), 0755) && !mkdir(at("game/portal2/maps"), 0755) && !mkdir(at("game/portal2/SAVE"), 0755));
    put("game/portal2/maps/sp_a1_intro1.bsp", other, other_size);
    put("game/portal2/SAVE/quick.sav", "SAVE-DATA", 9);
    put("game/portal2/maps/custom.bsp", "STOCK", 5);            // homonyme hors du dossier custom
    assert(p2cl_list(at("game"), NULL, 0) == 0);
    assert(p2cl_install(at("game"), at("ok.bsp"), "../sp_a1_intro1", 1, map, sizeof(map)) == P2CL_ERR_NAME);
    assert(p2cl_install(at("game"), at("ok.bsp"), "sp_a1_intro1", 0, map, sizeof(map)) == P2CL_OK);
    assert(!strcmp(map, "custom/sp_a1_intro1"));               // même nom qu'une salle d'origine : dossier séparé
    char buffer[4096];
    assert(get("game/portal2/maps/custom/sp_a1_intro1.bsp", buffer, sizeof(buffer)) == size && !memcmp(buffer, bsp, size));
    assert(p2cl_install(at("game"), at("plain.bsp"), "sp_a1_intro1", 0, map, sizeof(map)) == P2CL_ERR_EXISTS);
    assert(get("game/portal2/maps/custom/sp_a1_intro1.bsp", buffer, sizeof(buffer)) == size && !memcmp(buffer, bsp, size));
    assert(p2cl_install(at("game"), at("plain.bsp"), "sp_a1_intro1", 1, NULL, 0) == P2CL_OK);   // remplacement demandé
    assert(get("game/portal2/maps/custom/sp_a1_intro1.bsp", buffer, sizeof(buffer)) == other_size && !memcmp(buffer, other, other_size));
    assert(p2cl_install(at("game"), at("bad.bsp"), "broken", 0, NULL, 0) == P2CL_ERR_NOT_BSP);
    assert(!exists("game/portal2/maps/custom/broken.bsp"));
    assert(p2cl_install(at("game"), at("link.bsp"), "linked", 0, NULL, 0) == P2CL_ERR_LINK);
    assert(p2cl_install(at("game"), at("ok.bsp"), "b-chamber", 0, NULL, 0) == P2CL_OK);
    // Destination remplacée par un lien vers une salle d'origine : refusée, cible intacte.
    assert(!symlink(at("game/portal2/maps/sp_a1_intro1.bsp"), at("game/portal2/maps/custom/evil.bsp")));
    assert(p2cl_install(at("game"), at("ok.bsp"), "evil", 1, NULL, 0) == P2CL_ERR_LINK);
    assert(p2cl_remove(at("game"), "evil") == P2CL_ERR_LINK);
    assert(get("game/portal2/maps/sp_a1_intro1.bsp", buffer, sizeof(buffer)) == other_size && !memcmp(buffer, other, other_size));
    put("game/portal2/maps/custom/notes.txt", "x", 1);
    put("game/portal2/maps/custom/Upper.bsp", bsp, size);
    put("game/portal2/maps/custom/.hidden.bsp.part-1-1", bsp, size);

    // ---- liste : triée, seulement les .bsp ordinaires à nom valide
    p2cl_entry entries[8];
    assert(p2cl_list(at("game"), entries, 8) == 2);
    assert(!strcmp(entries[0].name, "b-chamber") && entries[0].size == size);
    assert(!strcmp(entries[1].name, "sp_a1_intro1") && entries[1].size == other_size);
    assert(p2cl_list(at("game"), entries, 1) == 2 && !strcmp(entries[0].name, "b-chamber"));

    // ---- dossier custom remplacé par un lien : refusé, rien n'est écrit dans la cible
    assert(!mkdir(at("game2"), 0755) && !mkdir(at("game2/portal2"), 0755) && !mkdir(at("game2/portal2/maps"), 0755));
    assert(!mkdir(at("elsewhere"), 0755));
    assert(!symlink(at("elsewhere"), at("game2/portal2/maps/custom")));
    assert(p2cl_install(at("game2"), at("ok.bsp"), "mine", 0, NULL, 0) == P2CL_ERR_LINK);
    assert(!exists("elsewhere/mine.bsp"));
    assert(p2cl_list(at("game2"), entries, 8) == -1);

    // ---- launch.args : lignes du joueur gardées, un seul bloc, retrait exact
    assert(!mkdir(at("docs"), 0755));
    const char *original = "# player options\n-condebug\n+sv_cheats\n0";
    put("docs/launch.args", original, strlen(original));
    assert(p2cl_request_launch(at("docs"), at("game"), "missing") == P2CL_ERR_NOT_FOUND);
    assert(get("docs/launch.args", buffer, sizeof(buffer)) == strlen(original));
    assert(p2cl_request_launch(at("docs"), at("game"), "../evil") == P2CL_ERR_NAME);
    assert(p2cl_request_launch(at("docs"), at("game"), "evil") == P2CL_ERR_LINK);
    assert(p2cl_request_launch(at("docs"), at("game"), "b-chamber") == P2CL_OK);
    assert(p2cl_request_launch(at("docs"), at("game"), "sp_a1_intro1") == P2CL_OK);
    size_t n = get("docs/launch.args", buffer, sizeof(buffer) - 1);
    buffer[n] = 0;
    assert(!strncmp(buffer, "# player options\n-condebug\n+sv_cheats\n0\n# p2-custom-level begin", 62));
    assert(strstr(buffer, "\n+map\ncustom/sp_a1_intro1\n# p2-custom-level end\n") && !strstr(buffer, "b-chamber"));
    assert(!strstr(strstr(buffer, "# p2-custom-level begin") + 1, "# p2-custom-level begin"));   // un seul bloc
    assert(p2cl_clear_launch(at("docs")) == P2CL_OK);
    n = get("docs/launch.args", buffer, sizeof(buffer) - 1);
    buffer[n] = 0;
    assert(!strcmp(buffer, "# player options\n-condebug\n+sv_cheats\n0\n"));   // seule la fin de ligne finale est ajoutée
    assert(!mkdir(at("docs2"), 0755));
    assert(p2cl_request_launch(at("docs2"), at("game"), "b-chamber") == P2CL_OK);   // fichier absent : créé
    assert(p2cl_clear_launch(at("docs2")) == P2CL_OK);
    assert(get("docs2/launch.args", buffer, sizeof(buffer)) == 0);
    put("docs/real.args", "-x\n", 3);
    unlink(at("docs/launch.args"));
    assert(!symlink(at("docs/real.args"), at("docs/launch.args")));
    assert(p2cl_request_launch(at("docs"), at("game"), "b-chamber") == P2CL_ERR_LINK);
    assert(get("docs/real.args", buffer, sizeof(buffer)) == 3);

    // ---- suppression : seulement maps/custom
    assert(p2cl_remove(at("game"), "../sp_a1_intro1") == P2CL_ERR_NAME);
    assert(p2cl_remove(at("game"), "nothing") == P2CL_ERR_NOT_FOUND);
    assert(p2cl_remove(at("game"), "sp_a1_intro1") == P2CL_OK);
    assert(!exists("game/portal2/maps/custom/sp_a1_intro1.bsp"));

    // ---- préservation : campagne, homonyme et sauvegarde intacts, aucun fichier temporaire laissé
    assert(get("game/portal2/maps/sp_a1_intro1.bsp", buffer, sizeof(buffer)) == other_size && !memcmp(buffer, other, other_size));
    assert(get("game/portal2/maps/custom.bsp", buffer, sizeof(buffer)) == 5 && !memcmp(buffer, "STOCK", 5));
    assert(get("game/portal2/SAVE/quick.sav", buffer, sizeof(buffer)) == 9 && !memcmp(buffer, "SAVE-DATA", 9));
    const char *scanned[] = {"game/portal2/maps/custom", "docs", "docs2"};
    for (int i = 0; i < 3; ++i) {
        DIR *d = opendir(at(scanned[i]));
        assert(d);
        for (struct dirent *e; (e = readdir(d));)
            assert(!strstr(e->d_name, ".part-") || !strcmp(e->d_name, ".hidden.bsp.part-1-1"));   // seul le leurre planté
        closedir(d);
    }
    for (int i = 0; i <= (int)P2CL_ERR_NOT_FOUND; ++i) assert(*p2cl_status_text((p2cl_status)i));
    puts("custom levels: all checks passed");
    return 0;
}
