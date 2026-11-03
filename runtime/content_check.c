// Owned-content completeness gate (see content_check.h). Valve's VPK layout:
// header (v1: signature, version, tree size; v2 adds four section sizes),
// then a tree of extension / path / file-name strings, each file followed by
// an 18-byte entry: CRC32, preload size, archive index, offset, length and a
// 0xffff terminator, then the preload bytes. Archive index 0x7fff keeps the
// data in the directory file itself, after the tree; any other index names
// pak01_NNN.vpk next to it. The engine opens those archives lazily, so a
// missing one only fails deep inside a later read.
#include "content_check.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define VPK_SIGNATURE 0x55aa1234u
#define VPK_EMBEDDED 0x7fffu   // archive index of data stored in the directory file
#define VPK_ENTRY 18u
#define VPK_TREE_LIMIT (256u << 20)  // sanity bound before allocating a tree

static uint32_t le16(const unsigned char *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8; }
static uint32_t le32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

__attribute__((format(printf, 2, 3)))
static void note(P2ContentReport *report, const char *format, ...) {
    if (report->names >= P2_CONTENT_NAME_COUNT) return;
    va_list list;
    va_start(list, format);
    vsnprintf(report->name[report->names++], P2_CONTENT_NAME_SIZE, format, list);
    va_end(list);
}

// Size of a regular file (following links), or -1.
static int64_t file_size(const char *path) {
    struct stat st;
    if (!path || stat(path, &st) || !S_ISREG(st.st_mode)) return -1;
    return (int64_t)st.st_size;
}

static int read_at(int fd, void *buffer, size_t size, off_t offset) {
    unsigned char *at = buffer;
    while (size) {
        ssize_t got = pread(fd, at, size, offset);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return -1;
        at += got; size -= (size_t)got; offset += got;
    }
    return 0;
}

// One pass over the tree: furthest referenced byte per archive (extents) and
// in the directory file's own data section (*embedded). -1 when malformed or
// truncated. Entries without archive data (length 0, preload only) need no archive.
static int parse_tree(const unsigned char *p, size_t size, uint64_t *extents, uint64_t *embedded) {
    const unsigned char *end = p + size;
    for (int level = 0;;) {  // 0 extension, 1 path, 2 file name
        const unsigned char *zero = p < end ? memchr(p, 0, (size_t)(end - p)) : NULL;
        if (!zero) return -1;
        int empty = zero == p;
        p = zero + 1;
        if (empty) {
            if (level == 0) return 0;
            --level;
            continue;
        }
        if (level < 2) { ++level; continue; }
        if ((size_t)(end - p) < VPK_ENTRY) return -1;
        uint32_t preload = le16(p + 4), index = le16(p + 6);
        uint64_t offset = le32(p + 8), length = le32(p + 12);
        if (le16(p + 16) != 0xffffu || index > VPK_EMBEDDED) return -1;
        p += VPK_ENTRY;
        if ((size_t)(end - p) < preload) return -1;
        p += preload;
        if (!length) continue;
        uint64_t *extent = index == VPK_EMBEDDED ? embedded : &extents[index];
        if (offset + length > *extent) *extent = offset + length;
    }
}

// Parses one directory file. -1: unreadable or malformed. *shortfall: bytes
// of its own data section (embedded entries, v2 data section) beyond its end.
static int read_directory(const char *path, uint64_t *extents, uint64_t *shortfall) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    unsigned char header[28], *tree = NULL;
    struct stat st;
    int result = -1;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 12 || read_at(fd, header, 12, 0)) goto done;
    uint32_t version = le32(header + 4), tree_size = le32(header + 8);
    size_t header_size = version == 1 ? 12 : version == 2 ? 28 : 0;
    if (le32(header) != VPK_SIGNATURE || !header_size || !tree_size || tree_size > VPK_TREE_LIMIT) goto done;
    uint64_t data_section = 0, file = (uint64_t)st.st_size, data_start = header_size + (uint64_t)tree_size;
    if (version == 2) {
        if (file < 28 || read_at(fd, header + 12, 16, 12)) goto done;
        data_section = le32(header + 12);
    }
    if (data_start > file || !(tree = malloc(tree_size)) || read_at(fd, tree, tree_size, (off_t)header_size)) goto done;
    uint64_t embedded = 0;
    if (parse_tree(tree, tree_size, extents, &embedded)) goto done;
    if (embedded < data_section) embedded = data_section;
    *shortfall = data_start + embedded > file ? data_start + embedded - file : 0;
    result = 0;
done:
    free(tree);
    close(fd);
    return result;
}

static void check_directory(const char *game, const char *folder, uint64_t *extents, P2ContentReport *report) {
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%s/pak01_dir.vpk", game, folder) >= (int)sizeof(path)) return;
    if (file_size(path) < 0) return;  // no VPK here; the engine mounts loose files only
    ++report->directories;
    memset(extents, 0, VPK_EMBEDDED * sizeof(*extents));
    uint64_t shortfall = 0;
    if (read_directory(path, extents, &shortfall) || shortfall) {
        ++report->bad_directories;
        report->missing_bytes += (int64_t)shortfall;
        note(report, "game/%s/pak01_dir.vpk", folder);
        if (shortfall == 0) return;  // malformed: its archives are unknown
    }
    for (uint32_t index = 0; index < VPK_EMBEDDED; ++index) {
        if (!extents[index]) continue;
        ++report->archives;
        if (snprintf(path, sizeof(path), "%s/%s/pak01_%03u.vpk", game, folder, index) >= (int)sizeof(path)) {
            ++report->missing_archives;
            continue;
        }
        int64_t size = file_size(path);
        if (size < 0) {
            ++report->missing_archives;
            report->missing_bytes += (int64_t)extents[index];
            note(report, "game/%s/pak01_%03u.vpk", folder, index);
        } else if ((uint64_t)size < extents[index]) {
            ++report->short_archives;
            report->missing_bytes += (int64_t)(extents[index] - (uint64_t)size);
            note(report, "game/%s/pak01_%03u.vpk", folder, index);
        }
    }
}

static int visible_folder(const struct dirent *entry) { return entry->d_name[0] != '.'; }

static int64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static const char *joined(char *buffer, size_t size, const char *root, const char *name) {
    if (!root || !*root || snprintf(buffer, size, "%s/%s", root, name) >= (int)size) return NULL;
    return buffer;
}

int p2_content_check_roots(const char *game, const char *linux_root, const char *prep, P2ContentReport *report) {
    int64_t started = now_us();
    memset(report, 0, sizeof(*report));
    report->volume_available = report->volume_total = -1;
    char path[PATH_MAX];
    if (file_size(joined(path, sizeof(path), game, "portal2/pak01_dir.vpk")) < 0) {
        ++report->required_missing;
        note(report, "game/portal2/pak01_dir.vpk");
    }
    if (file_size(joined(path, sizeof(path), linux_root, "portal2_linux")) <= 0) {
        ++report->required_missing;
        note(report, "linux/portal2_linux");
    }
    if (file_size(joined(path, sizeof(path), prep, "layout.json")) <= 0) {
        ++report->required_missing;
        note(report, "prep/layout.json");
    }
    // Every game/* folder with a pak01_dir.vpk (portal2, DLC, update): the
    // engine mounts each one it finds.
    struct dirent **folders = NULL;
    int count = game && *game ? scandir(game, &folders, visible_folder, alphasort) : -1;
    uint64_t *extents = count > 0 ? calloc(VPK_EMBEDDED, sizeof(*extents)) : NULL;
    if (count > 0 && !extents) {
        ++report->bad_directories;  // fail closed
        note(report, "game");
    }
    for (int i = 0; i < count; ++i) {
        struct stat st;
        if (extents && joined(path, sizeof(path), game, folders[i]->d_name) && !stat(path, &st) && S_ISDIR(st.st_mode))
            check_directory(game, folders[i]->d_name, extents, report);
        free(folders[i]);
    }
    free(folders);
    free(extents);
    report->complete = !report->required_missing && !report->bad_directories && !report->missing_archives &&
                       !report->short_archives;
    report->elapsed_us = now_us() - started;
    return report->complete;
}

int p2_content_check(const char *documents, P2ContentReport *report) {
    char game[PATH_MAX], linux_root[PATH_MAX], prep[PATH_MAX];
    return p2_content_check_roots(joined(game, sizeof(game), documents, "game"),
                                  joined(linux_root, sizeof(linux_root), documents, "linux"),
                                  joined(prep, sizeof(prep), documents, "prep"), report);
}

const char *p2_content_report_name(const P2ContentReport *report, int index) {
    return report && index >= 0 && index < report->names && index < P2_CONTENT_NAME_COUNT ? report->name[index] : "";
}

// ---- Status file -------------------------------------------------------------

typedef struct { char data[4096]; size_t used; int overflow; } Text;

__attribute__((format(printf, 2, 3)))
static void put(Text *text, const char *format, ...) {
    if (text->overflow) return;
    va_list list;
    va_start(list, format);
    int wrote = vsnprintf(text->data + text->used, sizeof(text->data) - text->used, format, list);
    va_end(list);
    if (wrote < 0 || (size_t)wrote >= sizeof(text->data) - text->used) text->overflow = 1;
    else text->used += (size_t)wrote;
}

// JSON string (ASCII; other bytes become '?', so the file always parses), or null.
static void put_string(Text *text, const char *value) {
    if (!value) { put(text, "null"); return; }
    put(text, "\"");
    for (const unsigned char *c = (const unsigned char *)value; *c && !text->overflow; ++c) {
        if (*c == '"' || *c == '\\') put(text, "\\%c", *c);
        else if (*c < 0x20) put(text, "\\u%04x", *c);
        else put(text, "%c", *c < 0x80 ? *c : '?');
    }
    put(text, "\"");
}

static void put_size(Text *text, int64_t value) {
    if (value < 0) put(text, "null");
    else put(text, "%lld", (long long)value);
}

int p2_content_write_status(const char *path, const P2ContentReport *report, const P2ContentStatus *status) {
    if (!path || !report || !status) { errno = EINVAL; return -1; }
    Text *text = calloc(1, sizeof(*text));
    if (!text) return -1;
    time_t now = time(NULL);
    struct tm utc;
    char stamp[32] = "";
    if (gmtime_r(&now, &utc)) strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%SZ", &utc);
    put(text, "{\n  \"schema\": 1,\n  \"timestamp\": ");
    put_string(text, stamp);
    put(text, ",\n  \"unix_time\": %lld,\n  \"platform\": ", (long long)now);
    put_string(text, status->platform);
    put(text, ",\n  \"app_version\": ");
    put_string(text, status->app_version);
    put(text, ",\n  \"app_build\": ");
    put_string(text, status->app_build);
    put(text, ",\n  \"trigger\": ");
    put_string(text, status->trigger);
    put(text, ",\n  \"complete\": %s,\n  \"engine_started\": %s,\n", report->complete ? "true" : "false",
        status->engine_started ? "true" : "false");
    put(text, "  \"required_missing\": %d,\n  \"directories\": %d,\n  \"bad_directories\": %d,\n"
              "  \"archives\": %d,\n  \"missing_archives\": %d,\n  \"short_archives\": %d,\n"
              "  \"missing_bytes_estimate\": %lld,\n  \"missing_names\": [",
        report->required_missing, report->directories, report->bad_directories, report->archives,
        report->missing_archives, report->short_archives, (long long)report->missing_bytes);
    for (int i = 0; i < report->names && i < P2_CONTENT_NAME_COUNT; ++i) {
        if (i) put(text, ", ");
        put_string(text, p2_content_report_name(report, i));
    }
    put(text, "],\n  \"volume_available_important_usage_bytes\": ");
    put_size(text, report->volume_available);
    put(text, ",\n  \"volume_total_bytes\": ");
    put_size(text, report->volume_total);
    put(text, ",\n  \"check_microseconds\": %lld\n}\n", (long long)report->elapsed_us);
    int result = -1, saved = EOVERFLOW;
    char temporary[PATH_MAX];
    if (!text->overflow && snprintf(temporary, sizeof(temporary), "%s.XXXXXX", path) < (int)sizeof(temporary)) {
        int fd = mkstemp(temporary);
        if (fd >= 0) {
            const char *at = text->data;
            size_t left = text->used;
            while (left) {
                ssize_t wrote = write(fd, at, left);
                if (wrote < 0 && errno == EINTR) continue;
                if (wrote <= 0) break;
                at += wrote; left -= (size_t)wrote;
            }
            fchmod(fd, 0644);
            if (!close(fd) && !left && !rename(temporary, path)) result = 0;
            saved = errno;
            if (result) unlink(temporary);
        } else saved = errno;
    }
    free(text);
    if (result) errno = saved;
    return result;
}
