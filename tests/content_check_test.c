// Host checks for runtime/content_check.c on synthetic VPK directories built
// here (no game data). Usage: content-check <empty scratch directory>.
// Writes <scratch>/status/portal2-setup-status.json for the Python side.
#include "content_check.h"
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;
#define CHECK(condition) do { if (!(condition)) { ++failures; \
    fprintf(stderr, "%s:%d: %s failed\n", __FILE__, __LINE__, #condition); } } while (0)

static char scratch[1024];

static void make_dirs(const char *path) {
    char copy[1024];
    snprintf(copy, sizeof(copy), "%s", path);
    for (char *c = copy + 1; *c; ++c)
        if (*c == '/') { *c = 0; mkdir(copy, 0755); *c = '/'; }
    mkdir(copy, 0755);
}

static void write_bytes(const char *path, const void *data, size_t size) {
    char folder[1024];
    snprintf(folder, sizeof(folder), "%s", path);
    *strrchr(folder, '/') = 0;
    make_dirs(folder);
    FILE *file = fopen(path, "wb");
    if (!file) { perror(path); exit(2); }
    if (size && fwrite(data, 1, size, file) != size) { perror(path); exit(2); }
    fclose(file);
}

static void write_size(const char *path, size_t size) {
    unsigned char *data = calloc(1, size ? size : 1);
    write_bytes(path, data, size);
    free(data);
}

static const char *at(const char *root, const char *relative) {
    static char buffers[4][1024];
    static int next;
    char *buffer = buffers[next++ % 4];
    snprintf(buffer, 1024, "%s/%s", root, relative);
    return buffer;
}

// ---- Synthetic VPK builder ---------------------------------------------------

typedef struct { const char *ext, *path, *name; uint16_t index; uint32_t offset, length; uint16_t preload; } Entry;
typedef struct { unsigned char data[8192]; size_t used; } Buffer;

static void put(Buffer *b, const void *data, size_t size) {
    if (b->used + size > sizeof(b->data)) { fputs("builder overflow\n", stderr); exit(2); }
    memcpy(b->data + b->used, data, size);
    b->used += size;
}
static void put_string(Buffer *b, const char *s) { put(b, s, strlen(s) + 1); }
static void put16(Buffer *b, uint32_t v) { unsigned char x[2] = {(unsigned char)v, (unsigned char)(v >> 8)}; put(b, x, 2); }
static void put32(Buffer *b, uint32_t v) {
    unsigned char x[4] = {(unsigned char)v, (unsigned char)(v >> 8), (unsigned char)(v >> 16), (unsigned char)(v >> 24)};
    put(b, x, 4);
}

// Entries grouped by extension then path, as Valve's writer emits them.
// `data` bytes follow the tree (v2: also declared as the data section).
static size_t build_vpk(Buffer *out, int version, const Entry *entries, int count, uint32_t data) {
    Buffer tree = {0};
    const char *ext = NULL, *path = NULL;
    for (int i = 0; i < count; ++i) {
        const Entry *e = &entries[i];
        if (!ext || strcmp(ext, e->ext)) {
            if (ext) { put_string(&tree, ""); put_string(&tree, ""); }
            put_string(&tree, e->ext);
            ext = e->ext;
            path = NULL;
        }
        if (!path || strcmp(path, e->path)) {
            if (path) put_string(&tree, "");
            put_string(&tree, e->path);
            path = e->path;
        }
        put_string(&tree, e->name);
        put32(&tree, 0x12345678u);
        put16(&tree, e->preload);
        put16(&tree, e->index);
        put32(&tree, e->offset);
        put32(&tree, e->length);
        put16(&tree, 0xffff);
        for (uint16_t p = 0; p < e->preload; ++p) put(&tree, "p", 1);
    }
    if (ext) { put_string(&tree, ""); put_string(&tree, ""); }
    put_string(&tree, "");
    out->used = 0;
    put32(out, 0x55aa1234u);
    put32(out, (uint32_t)version);
    put32(out, (uint32_t)tree.used);
    if (version == 2) { put32(out, data); put32(out, 0); put32(out, 0); put32(out, 0); }
    put(out, tree.data, tree.used);
    for (uint32_t i = 0; i < data; ++i) put(out, "d", 1);
    return out->used;
}

// game/portal2 (v1): archive 0 up to 1000, archive 2 up to 3000 (archive 1
// unreferenced), a preload-only entry naming archive 9, an embedded entry.
// game/portal2_dlc1 (v2): archive 0 up to 500 plus a 16-byte data section.
static const Entry base_entries[] = {
    {"txt", "scripts", "a", 0, 0, 600, 0},
    {"txt", "scripts", "b", 0, 600, 400, 4},
    {"txt", "scripts/sub", "c", 2, 2000, 1000, 0},
    {"vtf", "materials/console", "d", 9, 64, 0, 12},      // preload only: archive 9 not needed
    {"vtf", "materials/console", "e", 0x7fff, 0, 8, 0},   // in the directory file
};
static const Entry dlc_entries[] = {
    {"res", "resource", "x", 0, 100, 400, 0},
    {"res", "resource", "y", 0x7fff, 4, 12, 2},
};

static void make_complete(const char *root) {
    Buffer vpk;
    build_vpk(&vpk, 1, base_entries, 5, 8);
    write_bytes(at(root, "game/portal2/pak01_dir.vpk"), vpk.data, vpk.used);
    write_size(at(root, "game/portal2/pak01_000.vpk"), 1000);
    write_size(at(root, "game/portal2/pak01_002.vpk"), 3200);  // trailing bytes are fine
    build_vpk(&vpk, 2, dlc_entries, 2, 16);
    write_bytes(at(root, "game/portal2_dlc1/pak01_dir.vpk"), vpk.data, vpk.used);
    write_size(at(root, "game/portal2_dlc1/pak01_000.vpk"), 500);
    write_size(at(root, "game/bin/libsomething.so"), 10);       // folder without a VPK
    write_size(at(root, "game/.staging/pak01_dir.vpk"), 3);     // hidden: ignored
    write_size(at(root, "linux/portal2_linux"), 64);
    write_bytes(at(root, "prep/layout.json"), "{}", 2);
}

static const char *scenario(const char *name) {
    static char root[1024];
    snprintf(root, sizeof(root), "%s/%s", scratch, name);
    make_complete(root);
    return root;
}

static int has_name(const P2ContentReport *r, const char *name) {
    for (int i = 0; i < r->names; ++i) if (!strcmp(p2_content_report_name(r, i), name)) return 1;
    return 0;
}

static void test_complete(void) {
    P2ContentReport r;
    const char *root = scenario("complete");
    CHECK(p2_content_check(root, &r) == 1);
    CHECK(r.complete == 1 && r.required_missing == 0 && r.bad_directories == 0);
    CHECK(r.directories == 2);
    CHECK(r.archives == 3);  // portal2 000 and 002, dlc1 000
    CHECK(r.missing_archives == 0 && r.short_archives == 0 && r.missing_bytes == 0 && r.names == 0);
    CHECK(r.volume_available == -1 && r.volume_total == -1);
    CHECK(r.elapsed_us >= 0);
    CHECK(!strcmp(p2_content_report_name(&r, 0), "") && !strcmp(p2_content_report_name(&r, -1), ""));
    // Same through explicit roots (iOS --game-dir/--linux-root/--images).
    char game[1024], linux_root[1024], prep[1024];
    snprintf(game, sizeof(game), "%s/game", root);
    snprintf(linux_root, sizeof(linux_root), "%s/linux", root);
    snprintf(prep, sizeof(prep), "%s/prep", root);
    CHECK(p2_content_check_roots(game, linux_root, prep, &r) == 1);
    CHECK(p2_content_check_roots(game, NULL, prep, &r) == 0 && r.required_missing == 1 && has_name(&r, "linux/portal2_linux"));
}

static void test_missing_archive(void) {
    P2ContentReport r;
    const char *root = scenario("missing");
    unlink(at(root, "game/portal2/pak01_002.vpk"));
    unlink(at(root, "game/portal2_dlc1/pak01_000.vpk"));
    CHECK(p2_content_check(root, &r) == 0);
    CHECK(r.missing_archives == 2 && r.short_archives == 0 && r.archives == 3);
    CHECK(r.missing_bytes == 3000 + 500);
    CHECK(r.names == 2 && !strcmp(r.name[0], "game/portal2/pak01_002.vpk") &&
          !strcmp(r.name[1], "game/portal2_dlc1/pak01_000.vpk"));
    // A folder in place of an archive is not an archive.
    make_dirs(at(root, "game/portal2/pak01_002.vpk"));
    CHECK(p2_content_check(root, &r) == 0 && r.missing_archives == 2);
}

static void test_short_archive(void) {
    P2ContentReport r;
    const char *root = scenario("short");
    CHECK(truncate(at(root, "game/portal2/pak01_000.vpk"), 990) == 0);
    CHECK(p2_content_check(root, &r) == 0);
    CHECK(r.short_archives == 1 && r.missing_archives == 0 && r.missing_bytes == 10);
    CHECK(r.names == 1 && has_name(&r, "game/portal2/pak01_000.vpk"));
}

static void test_data_in_directory(void) {
    P2ContentReport r;
    const char *root = scenario("embedded");
    // Only embedded and preload-only entries: no archive needed at all.
    static const Entry only[] = {{"cfg", "cfg", "a", 0x7fff, 0, 20, 0}, {"cfg", "cfg", "b", 3, 0, 0, 5}};
    Buffer vpk;
    build_vpk(&vpk, 1, only, 2, 20);
    write_bytes(at(root, "game/update/pak01_dir.vpk"), vpk.data, vpk.used);
    CHECK(p2_content_check(root, &r) == 1 && r.directories == 3 && r.archives == 3);
    // Cut the directory's own data: 6 bytes short of the embedded entry.
    CHECK(truncate(at(root, "game/update/pak01_dir.vpk"), (off_t)vpk.used - 6) == 0);
    CHECK(p2_content_check(root, &r) == 0);
    CHECK(r.bad_directories == 1 && r.missing_bytes == 6 && has_name(&r, "game/update/pak01_dir.vpk"));
    // v2: the declared data section (24) counts even beyond the last embedded entry (16).
    build_vpk(&vpk, 2, dlc_entries, 2, 24);
    write_bytes(at(root, "game/portal2_dlc1/pak01_dir.vpk"), vpk.data, vpk.used - 1);
    CHECK(p2_content_check(root, &r) == 0 && r.bad_directories == 2);
}

static void expect_bad(const char *name, const unsigned char *data, size_t size) {
    P2ContentReport r;
    const char *root = scenario(name);
    write_bytes(at(root, "game/portal2_dlc1/pak01_dir.vpk"), data, size);
    int complete = p2_content_check(root, &r);
    if (complete || r.bad_directories != 1 || !has_name(&r, "game/portal2_dlc1/pak01_dir.vpk") || r.directories != 2) {
        ++failures;
        fprintf(stderr, "malformed case %s: complete=%d bad=%d dirs=%d\n", name, complete, r.bad_directories, r.directories);
    }
}

static void test_malformed(void) {
    Buffer vpk;
    size_t size = build_vpk(&vpk, 2, dlc_entries, 2, 16);
    unsigned char copy[8192];

    expect_bad("empty", copy, 0);
    expect_bad("header-only", vpk.data, 10);
    memcpy(copy, vpk.data, size); copy[0] ^= 0xff;
    expect_bad("signature", copy, size);
    memcpy(copy, vpk.data, size); copy[4] = 3;
    expect_bad("version", copy, size);
    memcpy(copy, vpk.data, size); copy[8] = 0; copy[9] = 0; copy[10] = 0; copy[11] = 0;
    expect_bad("zero-tree", copy, size);
    memcpy(copy, vpk.data, size); copy[10] = 0x10;  // tree size beyond the file
    expect_bad("tree-beyond-file", copy, size);
    expect_bad("v2-header-cut", vpk.data, 20);
    expect_bad("tree-cut", vpk.data, 28 + 9);
    // Entry terminator corrupted: first entry follows "res\0resource\0x\0".
    memcpy(copy, vpk.data, size);
    size_t entry = 28 + 4 + 9 + 2;
    CHECK(copy[entry + 16] == 0xff && copy[entry + 17] == 0xff);
    copy[entry + 16] = 0;
    expect_bad("terminator", copy, size);
    // Archive index above 0x7fff.
    memcpy(copy, vpk.data, size); copy[entry + 7] = 0x80;
    expect_bad("index", copy, size);
    // Preload running past the tree.
    memcpy(copy, vpk.data, size); copy[entry + 5] = 0x7f;
    expect_bad("preload", copy, size);
    // Tree without its final terminator (tree size one byte short).
    memcpy(copy, vpk.data, size);
    uint32_t tree = (uint32_t)copy[8] | (uint32_t)copy[9] << 8;
    --tree; copy[8] = (unsigned char)tree; copy[9] = (unsigned char)(tree >> 8);
    expect_bad("unterminated", copy, size);
    // Directory path that is a folder, not a file: no VPK, the engine loads loose files.
    P2ContentReport r;
    const char *root = scenario("folder-dir");
    unlink(at(root, "game/portal2_dlc1/pak01_dir.vpk"));
    make_dirs(at(root, "game/portal2_dlc1/pak01_dir.vpk"));
    CHECK(p2_content_check(root, &r) == 1 && r.directories == 1);
}

static void test_required(void) {
    P2ContentReport r;
    const char *root = scenario("required");
    unlink(at(root, "linux/portal2_linux"));
    CHECK(truncate(at(root, "prep/layout.json"), 0) == 0);
    CHECK(p2_content_check(root, &r) == 0);
    CHECK(r.required_missing == 2 && r.names == 2 && has_name(&r, "linux/portal2_linux") && has_name(&r, "prep/layout.json"));
    CHECK(r.missing_archives == 0 && r.bad_directories == 0);
    // Nothing imported yet.
    char empty[1024];
    snprintf(empty, sizeof(empty), "%s/nothing", scratch);
    make_dirs(empty);
    CHECK(p2_content_check(empty, &r) == 0 && r.required_missing == 3 && r.directories == 0 && r.archives == 0);
    CHECK(!strcmp(r.name[0], "game/portal2/pak01_dir.vpk"));
    CHECK(p2_content_check(NULL, &r) == 0 && r.required_missing == 3);
    // Only the game index, no archives.
    root = scenario("index-only");
    unlink(at(root, "game/portal2/pak01_000.vpk"));
    unlink(at(root, "game/portal2/pak01_002.vpk"));
    CHECK(p2_content_check(root, &r) == 0 && r.missing_archives == 2 && r.missing_bytes == 4000);
}

static void test_many_names(void) {
    P2ContentReport r;
    const char *root = scenario("many");
    Entry many[12];
    for (int i = 0; i < 12; ++i) many[i] = (Entry){"bin", "data", "f", (uint16_t)(10 + i), 0, 100, 0};
    static const char *names[12] = {"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"};
    for (int i = 0; i < 12; ++i) many[i].name = names[i];
    Buffer vpk;
    build_vpk(&vpk, 1, many, 12, 0);
    write_bytes(at(root, "game/portal2_dlc2/pak01_dir.vpk"), vpk.data, vpk.used);
    CHECK(p2_content_check(root, &r) == 0);
    CHECK(r.missing_archives == 12 && r.archives == 15 && r.missing_bytes == 1200);
    CHECK(r.names == P2_CONTENT_NAME_COUNT && !strcmp(r.name[0], "game/portal2_dlc2/pak01_010.vpk"));
    CHECK(!strcmp(p2_content_report_name(&r, P2_CONTENT_NAME_COUNT), ""));
}

static void test_status_file(void) {
    P2ContentReport r;
    const char *root = scenario("status");
    unlink(at(root, "game/portal2/pak01_002.vpk"));
    p2_content_check(root, &r);
    r.volume_available = 1234567;
    r.volume_total = -1;
    snprintf(r.name[1], P2_CONTENT_NAME_SIZE, "game/we\"ird\\\x01\xc3\xa9");
    r.names = 2;
    char folder[1024], path[1024];
    snprintf(folder, sizeof(folder), "%s/status", scratch);
    make_dirs(folder);
    snprintf(path, sizeof(path), "%s/%s", folder, P2_CONTENT_STATUS_FILE);
    P2ContentStatus status = {"test", "1.2", NULL, "check-again", 0};
    CHECK(p2_content_write_status(path, &r, &status) == 0);
    CHECK(p2_content_write_status(path, &r, &status) == 0);  // replaces it
    CHECK(p2_content_write_status(NULL, &r, &status) == -1 && errno == EINVAL);
    char bad[1024];
    snprintf(bad, sizeof(bad), "%s/no/such/folder/status.json", scratch);
    CHECK(p2_content_write_status(bad, &r, &status) == -1);
}

int main(int argc, char **argv) {
    if (argc != 2) { fputs("usage: content-check <scratch>\n", stderr); return 2; }
    snprintf(scratch, sizeof(scratch), "%s", argv[1]);
    test_complete();
    test_missing_archive();
    test_short_archive();
    test_data_in_directory();
    test_malformed();
    test_required();
    test_many_names();
    test_status_file();
    if (failures) { fprintf(stderr, "%d content check failures\n", failures); return 1; }
    puts("content checks passed");
    return 0;
}
