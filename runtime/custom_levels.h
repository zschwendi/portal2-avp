// Salles de test personnalisées locales : cartes Portal 2 compilées (.bsp) que
// le joueur possède déjà (fichiers importés à la main), sans Steam Workshop.
//
// Emplacement : <game>/portal2/maps/custom/<nom>.bsp, où <game> est le dossier
// passé au jeu par --game-dir (Documents/game sur iOS/visionOS). Ce dossier est
// dans le chemin de recherche « Game |gameinfo_path|. » du gameinfo.txt d'origine :
// « +map custom/<nom> » charge la carte. Le contenu d'origine, les sauvegardes
// et les autres chemins ne sont jamais modifiés : on n'écrit que dans
// maps/custom/ et dans un bloc délimité de Documents/launch.args.
//
// Une .bsp autonome (contenu embarqué dans son pakfile, comme les salles de
// l'éditeur de la communauté) suffit. Le contenu compagnon en fichiers libres
// passe par tools/custom_levels.py (vérifie qu'il ne masque aucun fichier d'origine).
// Ceci ne fournit pas l'éditeur de salles (Puzzle Maker) : voir docs.
#pragma once
#include <stddef.h>
#include <stdint.h>

#define P2CL_NAME_MAX 64
#define P2CL_BSP_VERSION 21                       // VBSP de Portal 2
#define P2CL_BSP_MAX_BYTES (1024ull * 1024 * 1024)

typedef enum {
    P2CL_OK = 0,
    P2CL_ERR_IO,          // errno conservé
    P2CL_ERR_NAME,        // nom hors [a-z0-9_-], vide ou trop long
    P2CL_ERR_NOT_BSP,     // pas d'en-tête VBSP
    P2CL_ERR_VERSION,     // VBSP d'une autre version que 21
    P2CL_ERR_CORRUPT,     // table des lumps hors du fichier, lumps essentiels vides
    P2CL_ERR_TOO_LARGE,
    P2CL_ERR_LINK,        // lien symbolique refusé (source, dossier ou destination)
    P2CL_ERR_NOT_FILE,    // pas un fichier ordinaire
    P2CL_ERR_EXISTS,      // destination déjà présente (sans remplacement demandé)
    P2CL_ERR_NOT_FOUND,   // carte ou dossier du jeu absent
} p2cl_status;

typedef struct {
    int32_t version;
    int32_t map_revision;
    uint64_t size;
    int has_pakfile;      // lump 40 non vide : contenu embarqué
} p2cl_bsp_info;

typedef struct {
    char name[P2CL_NAME_MAX + 1];
    uint64_t size;
} p2cl_entry;

const char *p2cl_status_text(p2cl_status status);
// Nom de carte accepté : 1 à 64 caractères [a-z0-9_-], ne commence pas par '-'.
int p2cl_name_valid(const char *name);
// Nom proposé depuis un chemin de fichier : base sans .bsp, minuscules, autres caractères -> '_'.
p2cl_status p2cl_name_from_path(const char *path, char *out, size_t size);
// Vérifie un fichier .bsp (sans suivre de lien symbolique).
p2cl_status p2cl_inspect_bsp(const char *path, p2cl_bsp_info *info);
// Copie atomique de source vers <game>/portal2/maps/custom/<name>.bsp. replace = 0 : refuse
// d'écraser. map_out (facultatif) reçoit « custom/<name> » pour la commande map.
p2cl_status p2cl_install(const char *game_dir, const char *source, const char *name, int replace,
                         char *map_out, size_t map_size);
// Cartes installées, triées par nom ; rend leur nombre total (peut dépasser capacity), -1 si erreur.
int p2cl_list(const char *game_dir, p2cl_entry *entries, int capacity);
p2cl_status p2cl_remove(const char *game_dir, const char *name);
// Bloc « +map custom/<name> » à la fin de <documents>/launch.args (les autres lignes sont gardées) ;
// p2cl_clear_launch le retire. Le lanceur l'appelle après avoir lu launch.args : lancement unique.
p2cl_status p2cl_request_launch(const char *documents, const char *game_dir, const char *name);
p2cl_status p2cl_clear_launch(const char *documents);
