// Owned-content completeness gate (see content_check.h). Valve's VPK layout:
// header (v1: signature, version, tree size; v2 adds four section sizes),
// then a tree of extension / path / file-name strings, each file followed by
// an 18-byte entry: CRC32, preload size, archive index, offset, length and a
// 0xffff terminator, then the preload bytes. Archive index 0x7fff keeps the
// data in the directory file itself, after the tree; any other index names
// pak01_NNN.vpk next to it. The engine opens those archives lazily, so a
// missing one only fails deep inside a later read. Loose files (maps, ...)
// appear in no tree: the content manifest lists them (content_check.h).
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
#define MANIFEST_LIMIT (16 << 20)    // a full install's manifest is about 0.2 MB

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

// note() unless already listed: a missing archive is found by both the VPK
// and the manifest checks.
static void note_once(P2ContentReport *report, const char *name) {
    for (int i = 0; i < report->names && i < P2_CONTENT_NAME_COUNT; ++i)
        if (!strncmp(report->name[i], name, P2_CONTENT_NAME_SIZE - 1)) return;
    note(report, "%s", name);
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

static void start_report(P2ContentReport *report) {
    memset(report, 0, sizeof(*report));
    report->volume_available = report->volume_total = -1;
}

// Required files and every VPK directory tree under game/*.
static void check_roots(const char *game, const char *linux_root, const char *prep, P2ContentReport *report) {
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
}

// ---- Content manifest --------------------------------------------------------

static int64_t add_bytes(int64_t total, int64_t more) { return more > INT64_MAX - total ? INT64_MAX : total + more; }

// Next line of [*at, end) without its LF or CRLF; NULL at the end. A last
// line without a line break counts.
static const char *next_line(const char **at, const char *end, size_t *length) {
    if (*at >= end) return NULL;
    const char *line = *at, *newline = memchr(line, '\n', (size_t)(end - line)), *stop = newline ? newline : end;
    *at = newline ? newline + 1 : end;
    if (stop > line && stop[-1] == '\r') --stop;
    *length = (size_t)(stop - line);
    return line;
}

// "<decimal size>\t<relative path>": copies the path, NUL terminated, into
// path[PATH_MAX]. -1 when malformed or unsafe: absolute, empty, "." or ".."
// components, control bytes or backslashes, outside prep/, linux/ and
// game/<folder>/.
static int manifest_entry(const char *line, size_t length, int64_t *size, char *path) {
    size_t at = 0;
    int64_t value = 0;
    for (; at < length && line[at] >= '0' && line[at] <= '9'; ++at) {
        int digit = line[at] - '0';
        if (value > (INT64_MAX - digit) / 10) return -1;
        value = value * 10 + digit;
    }
    if (!at || at >= length || line[at] != '\t') return -1;
    const char *name = line + at + 1;
    size_t name_length = length - at - 1, start = 0;
    int components = 0, top = 0;  // top: 1 prep or linux, 2 game
    if (!name_length || name_length >= PATH_MAX) return -1;
    for (size_t i = 0; i <= name_length; ++i) {
        if (i < name_length) {
            unsigned char c = (unsigned char)name[i];
            if (c < 0x20 || c == 0x7f || c == '\\') return -1;
            if (c != '/') continue;
        }
        const char *part = name + start;
        size_t size_of_part = i - start;
        if (!size_of_part || (part[0] == '.' && (size_of_part == 1 || (size_of_part == 2 && part[1] == '.')))) return -1;
        if (!components++) {
            if ((size_of_part == 4 && !memcmp(part, "prep", 4)) || (size_of_part == 5 && !memcmp(part, "linux", 5))) top = 1;
            else if (size_of_part == 4 && !memcmp(part, "game", 4)) top = 2;
            else return -1;
        }
        start = i + 1;
    }
    if (components < top + 1) return -1;  // a file inside prep/ or linux/, or inside game/<folder>/
    memcpy(path, name, name_length);
    path[name_length] = 0;
    *size = value;
    return 0;
}

// 1: read into *text (NUL terminated), 0: absent, -1: present but not a
// readable regular file of reasonable size (a dangling link is present).
static int read_manifest(int folder, char **text, size_t *size) {
    int fd = openat(folder, P2_CONTENT_MANIFEST_FILE, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) {
        struct stat st;
        return errno == ENOENT && fstatat(folder, P2_CONTENT_MANIFEST_FILE, &st, AT_SYMLINK_NOFOLLOW) ? 0 : -1;
    }
    struct stat st;
    int result = -1;
    if (!fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_size <= MANIFEST_LIMIT &&
        (*text = malloc((size_t)st.st_size + 1))) {
        if (!read_at(fd, *text, (size_t)st.st_size, 0)) {
            (*text)[st.st_size] = 0;
            *size = (size_t)st.st_size;
            result = 1;
        } else {
            free(*text);
            *text = NULL;
        }
    }
    close(fd);
    return result;
}

// Documents/portal2-content-manifest.txt: validated whole first (a bad
// manifest vouches for nothing), then one stat per listed file. Without one,
// the sentinel campaign map stands in for the loose files.
static void check_manifest(const char *documents, P2ContentReport *report) {
    int folder = documents && *documents ? open(documents, O_RDONLY | O_DIRECTORY | O_CLOEXEC) : -1;
    char *text = NULL, path[PATH_MAX];
    size_t size = 0, length;
    int found = folder >= 0 ? read_manifest(folder, &text, &size) : 0;
    struct stat st;
    if (!found) {
        if (folder < 0 || fstatat(folder, P2_CONTENT_SENTINEL_MAP, &st, 0) || !S_ISREG(st.st_mode) || st.st_size <= 0) {
            report->maps_missing = 1;
            note_once(report, P2_CONTENT_SENTINEL_MAP);
        }
        if (folder >= 0) close(folder);
        return;
    }
    report->manifest = 1;
    const char *at = text, *end = text + size, *line;
    int64_t bytes;
    int bad = found < 0 ? -1 : 0, number = 1, files = 0;  // bad: -1 whole file, else first bad line
    static const char header[] = P2_CONTENT_MANIFEST_HEADER;
    if (!bad && (!(line = next_line(&at, end, &length)) || length != sizeof(header) - 1 || memcmp(line, header, length)))
        bad = 1;
    while (!bad && (line = next_line(&at, end, &length))) {
        ++number;
        if (!length) continue;
        if (manifest_entry(line, length, &bytes, path)) bad = number;
        else ++files;
    }
    if (!bad && !files) bad = -1;
    if (bad) {
        report->manifest_bad = 1;
        if (bad > 0) note(report, P2_CONTENT_MANIFEST_FILE ":%d", bad);
        else note(report, P2_CONTENT_MANIFEST_FILE);
    } else {
        report->manifest_files = files;
        int64_t listed = 0;
        at = text;
        next_line(&at, end, &length);  // header
        while ((line = next_line(&at, end, &length))) {
            if (!length || manifest_entry(line, length, &bytes, path)) continue;
            if (fstatat(folder, path, &st, 0) || !S_ISREG(st.st_mode)) ++report->manifest_missing;
            else if ((int64_t)st.st_size != bytes) ++report->manifest_wrong_size;
            else continue;
            listed = add_bytes(listed, bytes);  // a wrong-size file is copied again in full
            note_once(report, path);
        }
        // The archive estimate covers the same missing archives: the larger of the two.
        if (listed > report->missing_bytes) report->missing_bytes = listed;
    }
    free(text);
    close(folder);
}

static int finish(P2ContentReport *report, int64_t started) {
    report->complete = !report->required_missing && !report->bad_directories && !report->missing_archives &&
                       !report->short_archives && !report->maps_missing &&
                       (!report->manifest || (!report->manifest_bad && report->manifest_files > 0 &&
                                              !report->manifest_missing && !report->manifest_wrong_size));
    report->elapsed_us = now_us() - started;
    return report->complete;
}

int p2_content_check_roots(const char *game, const char *linux_root, const char *prep, P2ContentReport *report) {
    int64_t started = now_us();
    start_report(report);
    check_roots(game, linux_root, prep, report);
    return finish(report, started);
}

int p2_content_check(const char *documents, P2ContentReport *report) {
    int64_t started = now_us();
    char game[PATH_MAX], linux_root[PATH_MAX], prep[PATH_MAX];
    start_report(report);
    check_roots(joined(game, sizeof(game), documents, "game"), joined(linux_root, sizeof(linux_root), documents, "linux"),
                joined(prep, sizeof(prep), documents, "prep"), report);
    check_manifest(documents, report);
    return finish(report, started);
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
              "  \"missing_bytes_estimate\": %lld,\n",
        report->required_missing, report->directories, report->bad_directories, report->archives,
        report->missing_archives, report->short_archives, (long long)report->missing_bytes);
    put(text, "  \"manifest\": %s,\n  \"manifest_bad\": %s,\n  \"manifest_files\": %d,\n"
              "  \"manifest_missing\": %d,\n  \"manifest_wrong_size\": %d,\n  \"maps_missing\": %s,\n"
              "  \"missing_names\": [",
        report->manifest ? "true" : "false", report->manifest_bad ? "true" : "false", report->manifest_files,
        report->manifest_missing, report->manifest_wrong_size, report->maps_missing ? "true" : "false");
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
