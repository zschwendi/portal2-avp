// Salles de test personnalisées locales : voir custom_levels.h.
// Tout passe par des descripteurs de dossier ouverts sans suivre les liens
// (O_NOFOLLOW à chaque composant) : un lien symbolique placé dans maps/custom,
// à la place de maps/ ou de la source ne fait jamais écrire ailleurs.
#include "custom_levels.h"
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#define HEADER_BYTES (8 + 64 * 16 + 4)
#define LUMP_PAKFILE 40
#define LAUNCH_MAX (64 * 1024)
static const char begin_marker[] = "# p2-custom-level begin: one-shot, removed by the launcher after start";
static const char end_marker[] = "# p2-custom-level end";

const char *p2cl_status_text(p2cl_status status) {
    switch (status) {
    case P2CL_OK: return "ok";
    case P2CL_ERR_IO: return "file error";
    case P2CL_ERR_NAME: return "invalid map name (use a-z, 0-9, _ and -, at most 64 characters)";
    case P2CL_ERR_NOT_BSP: return "not a compiled Source map (VBSP header missing)";
    case P2CL_ERR_VERSION: return "not a Portal 2 map (VBSP version is not 21)";
    case P2CL_ERR_CORRUPT: return "damaged or incomplete map (lump table out of range or essential lumps empty)";
    case P2CL_ERR_TOO_LARGE: return "map file too large";
    case P2CL_ERR_LINK: return "symbolic links are refused";
    case P2CL_ERR_NOT_FILE: return "not a regular file or folder";
    case P2CL_ERR_EXISTS: return "a custom map with this name already exists";
    case P2CL_ERR_NOT_FOUND: return "map or game folder not found";
    }
    return "unknown";
}

int p2cl_name_valid(const char *name) {
    if (!name || !*name || *name == '-') return 0;
    size_t n = 0;
    for (const char *p = name; *p; ++p, ++n) {
        if (n >= P2CL_NAME_MAX) return 0;
        if (!((*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '_' || *p == '-')) return 0;
    }
    return 1;
}

p2cl_status p2cl_name_from_path(const char *path, char *out, size_t size) {
    if (!path || !out || size < 2) return P2CL_ERR_NAME;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    size_t length = strlen(base);
    if (length >= 4 && !strcasecmp(base + length - 4, ".bsp")) length -= 4;
    size_t used = 0;
    for (size_t i = 0; i < length && used + 1 < size && used < P2CL_NAME_MAX; ++i) {
        unsigned char ch = (unsigned char)tolower((unsigned char)base[i]);
        out[used++] = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-' ? (char)ch : '_';
    }
    out[used] = 0;
    while (used && out[0] == '-') memmove(out, out + 1, used--);   // pas d'option déguisée
    return p2cl_name_valid(out) ? P2CL_OK : P2CL_ERR_NAME;
}

// ---------------------------------------------------------------- en-tête VBSP
static int32_t le32(const unsigned char *p) { return (int32_t)((uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24); }

static int read_full(int fd, void *buffer, size_t size, off_t offset) {
    size_t done = 0;
    while (done < size) {
        ssize_t n = pread(fd, (char *)buffer + done, size - done, offset + (off_t)done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}

static p2cl_status inspect_fd(int fd, p2cl_bsp_info *info) {
    struct stat st;
    if (fstat(fd, &st)) return P2CL_ERR_IO;
    if (!S_ISREG(st.st_mode)) return P2CL_ERR_NOT_FILE;
    if ((uint64_t)st.st_size > P2CL_BSP_MAX_BYTES) return P2CL_ERR_TOO_LARGE;
    if (st.st_size < HEADER_BYTES) return st.st_size >= 4 ? P2CL_ERR_CORRUPT : P2CL_ERR_NOT_BSP;
    unsigned char header[HEADER_BYTES];
    if (read_full(fd, header, sizeof(header), 0)) return P2CL_ERR_IO;
    if (memcmp(header, "VBSP", 4)) return P2CL_ERR_NOT_BSP;
    int32_t version = le32(header + 4);
    if (version != P2CL_BSP_VERSION) return P2CL_ERR_VERSION;
    uint64_t size = (uint64_t)st.st_size;
    int32_t lengths[64];
    for (int i = 0; i < 64; ++i) {
        int32_t offset = le32(header + 8 + 16 * i), length = le32(header + 12 + 16 * i);
        lengths[i] = length;
        if (offset < 0 || length < 0) return P2CL_ERR_CORRUPT;
        if (length && ((uint64_t)offset < HEADER_BYTES || (uint64_t)offset + (uint64_t)length > size)) return P2CL_ERR_CORRUPT;
    }
    // Entités, plans, nœuds, modèles : vides = pas une carte jouable.
    if (!lengths[0] || !lengths[1] || !lengths[5] || !lengths[14]) return P2CL_ERR_CORRUPT;
    if (info) *info = (p2cl_bsp_info){version, le32(header + 8 + 64 * 16), size, lengths[LUMP_PAKFILE] > 0};
    return P2CL_OK;
}

static p2cl_status open_status(void) {
    return errno == ELOOP || errno == EMLINK ? P2CL_ERR_LINK : errno == ENOENT ? P2CL_ERR_NOT_FOUND
         : errno == ENOTDIR ? P2CL_ERR_NOT_FILE : P2CL_ERR_IO;
}

p2cl_status p2cl_inspect_bsp(const char *path, p2cl_bsp_info *info) {
    if (!path) return P2CL_ERR_NOT_FOUND;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return open_status();
    p2cl_status status = inspect_fd(fd, info);
    close(fd);
    return status;
}

// ---------------------------------------------------------------- dossiers
// Descripteur de <game>/portal2/maps/custom (créé si absent, jamais via un lien).
static p2cl_status open_custom(const char *game_dir, int create, int *out) {
    *out = -1;
    if (!game_dir || !*game_dir) return P2CL_ERR_NOT_FOUND;
    int root = open(game_dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (root < 0) return open_status();
    static const char *const parts[] = {"portal2", "maps", "custom"};
    int fd = root;
    for (int i = 0; i < 3; ++i) {
        int next = openat(fd, parts[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0 && errno == ENOENT && i == 2 && create) {
            if (mkdirat(fd, parts[i], 0755) && errno != EEXIST) { close(fd); return P2CL_ERR_IO; }
            next = openat(fd, parts[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        }
        if (next < 0) {
            p2cl_status status = open_status();
            struct stat st;   // O_NOFOLLOW|O_DIRECTORY sur un lien : ENOTDIR ou ELOOP selon le système
            if (!fstatat(fd, parts[i], &st, AT_SYMLINK_NOFOLLOW) && S_ISLNK(st.st_mode)) status = P2CL_ERR_LINK;
            close(fd);
            return status;
        }
        close(fd);
        fd = next;
    }
    *out = fd;
    return P2CL_OK;
}

static int copy_fd(int from, int to, uint64_t expected) {
    char buffer[1 << 16];
    uint64_t total = 0;
    off_t offset = 0;
    for (;;) {
        ssize_t n = pread(from, buffer, sizeof(buffer), offset);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return -1;
        if (n == 0) break;
        for (ssize_t done = 0; done < n;) {
            ssize_t w = write(to, buffer + done, (size_t)(n - done));
            if (w < 0 && errno == EINTR) continue;
            if (w <= 0) return -1;
            done += w;
        }
        offset += n;
        total += (uint64_t)n;
        if (total > expected) { errno = EFBIG; return -1; }   // la source a grandi pendant la copie
    }
    if (total != expected) { errno = EIO; return -1; }
    return fsync(to);
}

p2cl_status p2cl_install(const char *game_dir, const char *source, const char *name, int replace,
                         char *map_out, size_t map_size) {
    if (!p2cl_name_valid(name)) return P2CL_ERR_NAME;
    if (!source) return P2CL_ERR_NOT_FOUND;
    int in = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (in < 0) return open_status();
    p2cl_bsp_info info;
    p2cl_status status = inspect_fd(in, &info);
    int dir = -1;
    if (status == P2CL_OK) status = open_custom(game_dir, 1, &dir);
    char final[P2CL_NAME_MAX + 8], temp[P2CL_NAME_MAX + 48];
    snprintf(final, sizeof(final), "%s.bsp", name);
    struct stat st;
    if (status == P2CL_OK && !fstatat(dir, final, &st, AT_SYMLINK_NOFOLLOW)) {
        if (S_ISLNK(st.st_mode)) status = P2CL_ERR_LINK;
        else if (!S_ISREG(st.st_mode)) status = P2CL_ERR_NOT_FILE;
        else if (!replace) status = P2CL_ERR_EXISTS;
    }
    if (status != P2CL_OK) { if (dir >= 0) close(dir); close(in); return status; }

    static unsigned counter;
    int out = -1;
    for (int attempt = 0; attempt < 16 && out < 0; ++attempt) {
        snprintf(temp, sizeof(temp), ".%s.bsp.part-%d-%u", name, (int)getpid(), __atomic_add_fetch(&counter, 1, __ATOMIC_RELAXED));
        out = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (out < 0 && errno != EEXIST) break;
    }
    if (out < 0) { close(dir); close(in); return P2CL_ERR_IO; }
    int failed = copy_fd(in, out, info.size);
    int saved = errno;
    if (close(out) && !failed) { failed = 1; saved = errno; }
    close(in);
    if (!failed) {
        // Sans remplacement : link échoue si la destination est apparue entre-temps (pas d'écrasement).
        if (replace ? renameat(dir, temp, dir, final) : linkat(dir, temp, dir, final, 0)) {
            saved = errno; failed = 1;
            if (saved == EEXIST) status = P2CL_ERR_EXISTS;
        }
    }
    if (failed || !replace) unlinkat(dir, temp, 0);
    close(dir);
    if (failed) { errno = saved; return status == P2CL_OK ? P2CL_ERR_IO : status; }
    if (map_out && map_size) snprintf(map_out, map_size, "custom/%s", name);
    return P2CL_OK;
}

static int compare_entries(const void *a, const void *b) {
    return strcmp(((const p2cl_entry *)a)->name, ((const p2cl_entry *)b)->name);
}

int p2cl_list(const char *game_dir, p2cl_entry *entries, int capacity) {
    int dir;
    p2cl_status status = open_custom(game_dir, 0, &dir);
    if (status == P2CL_ERR_NOT_FOUND) return 0;   // aucune carte personnalisée
    if (status != P2CL_OK) return -1;
    DIR *listing = fdopendir(dir);
    if (!listing) { close(dir); return -1; }
    int count = 0, failed = 0;
    p2cl_entry *all = NULL;
    struct dirent *item;
    while ((item = readdir(listing))) {
        size_t length = strlen(item->d_name);
        if (length < 5 || length - 4 > P2CL_NAME_MAX || strcmp(item->d_name + length - 4, ".bsp")) continue;
        p2cl_entry entry;
        memcpy(entry.name, item->d_name, length - 4);
        entry.name[length - 4] = 0;
        struct stat st;
        if (!p2cl_name_valid(entry.name) || fstatat(dirfd(listing), item->d_name, &st, AT_SYMLINK_NOFOLLOW) || !S_ISREG(st.st_mode))
            continue;
        entry.size = (uint64_t)st.st_size;
        p2cl_entry *grown = realloc(all, (size_t)(count + 1) * sizeof(*all));
        if (!grown) { failed = 1; break; }
        all = grown;
        all[count++] = entry;
    }
    closedir(listing);
    if (failed) { free(all); return -1; }
    if (count) qsort(all, (size_t)count, sizeof(*all), compare_entries);   // ordre stable quelle que soit la capacité
    if (entries && capacity > 0) memcpy(entries, all, (size_t)(count < capacity ? count : capacity) * sizeof(*all));
    free(all);
    return count;
}

p2cl_status p2cl_remove(const char *game_dir, const char *name) {
    if (!p2cl_name_valid(name)) return P2CL_ERR_NAME;
    int dir;
    p2cl_status status = open_custom(game_dir, 0, &dir);
    if (status != P2CL_OK) return status;
    char file[P2CL_NAME_MAX + 8];
    snprintf(file, sizeof(file), "%s.bsp", name);
    struct stat st;
    if (fstatat(dir, file, &st, AT_SYMLINK_NOFOLLOW)) status = P2CL_ERR_NOT_FOUND;
    else if (!S_ISREG(st.st_mode)) status = S_ISLNK(st.st_mode) ? P2CL_ERR_LINK : P2CL_ERR_NOT_FILE;
    else if (unlinkat(dir, file, 0)) status = P2CL_ERR_IO;
    close(dir);
    return status;
}

// ---------------------------------------------------------------- launch.args
// Lit launch.args (absent = vide) et retire l'éventuel bloc géré ; rend la longueur gardée.
static p2cl_status launch_without_block(int documents, char *out, size_t size, size_t *used) {
    *used = 0;
    int fd = openat(documents, "launch.args", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? P2CL_OK : open_status();
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size >= (off_t)size || (size_t)st.st_size > LAUNCH_MAX) {
        close(fd);
        return P2CL_ERR_NOT_FILE;
    }
    char *text = malloc((size_t)st.st_size + 1);
    if (!text || (st.st_size && read_full(fd, text, (size_t)st.st_size, 0))) { free(text); close(fd); return P2CL_ERR_IO; }
    close(fd);
    text[st.st_size] = 0;
    int inside = 0;
    for (char *line = text; *line;) {
        char *end = strchr(line, '\n');
        size_t length = end ? (size_t)(end - line) : strlen(line);
        size_t bare = length && line[length - 1] == '\r' ? length - 1 : length;
        if (bare == strlen(begin_marker) && !memcmp(line, begin_marker, bare)) inside = 1;
        else if (inside && bare == strlen(end_marker) && !memcmp(line, end_marker, bare)) inside = 0;
        else if (!inside) {
            memcpy(out + *used, line, length);
            *used += length;
            out[(*used)++] = '\n';
        }
        line += length + (end ? 1 : 0);
    }
    free(text);
    return P2CL_OK;
}

static p2cl_status write_launch(int documents, const char *text, size_t length) {
    char temp[64];
    snprintf(temp, sizeof(temp), ".launch.args.part-%d", (int)getpid());
    unlinkat(documents, temp, 0);
    int fd = openat(documents, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) return P2CL_ERR_IO;
    size_t done = 0;
    while (done < length) {
        ssize_t n = write(fd, text + done, length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        done += (size_t)n;
    }
    int failed = done != length || fsync(fd);
    failed |= close(fd) != 0;
    if (failed || renameat(documents, temp, documents, "launch.args")) { unlinkat(documents, temp, 0); return P2CL_ERR_IO; }
    return P2CL_OK;
}

static p2cl_status update_launch(const char *documents, const char *name) {
    if (!documents) return P2CL_ERR_NOT_FOUND;
    int dir = open(documents, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dir < 0) return open_status();
    struct stat st;
    if (!fstatat(dir, "launch.args", &st, AT_SYMLINK_NOFOLLOW) && S_ISLNK(st.st_mode)) { close(dir); return P2CL_ERR_LINK; }
    size_t capacity = LAUNCH_MAX + 512, used;
    char *text = malloc(capacity);
    if (!text) { close(dir); return P2CL_ERR_IO; }
    p2cl_status status = launch_without_block(dir, text, capacity, &used);
    if (status == P2CL_OK && name)
        used += (size_t)snprintf(text + used, capacity - used, "%s\n+map\ncustom/%s\n%s\n", begin_marker, name, end_marker);
    if (status == P2CL_OK) status = write_launch(dir, text, used);
    free(text);
    close(dir);
    return status;
}

p2cl_status p2cl_request_launch(const char *documents, const char *game_dir, const char *name) {
    if (!p2cl_name_valid(name)) return P2CL_ERR_NAME;
    int dir;
    p2cl_status status = open_custom(game_dir, 0, &dir);
    if (status != P2CL_OK) return status;
    char file[P2CL_NAME_MAX + 8];
    snprintf(file, sizeof(file), "%s.bsp", name);
    int fd = openat(dir, file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    close(dir);
    if (fd < 0) return open_status();
    status = inspect_fd(fd, NULL);   // la carte doit toujours être valide au moment du lancement
    close(fd);
    return status == P2CL_OK ? update_launch(documents, name) : status;
}

p2cl_status p2cl_clear_launch(const char *documents) { return update_launch(documents, NULL); }
