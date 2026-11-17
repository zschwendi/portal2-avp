#include "video_config.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Byte-for-byte the file the physical headset wrote on Nov 17 2026
// (build/nov17-avp/preservation/A/.../update/cfg/video.txt).
static const char generated[] =
    "\"config\"\n{\n\t\"VendorID\"\t\t\"1\"\n\t\"DeviceID\"\t\t\"1\"\n\t\"setting.fullscreen\"\t\t\"1\"\n"
    "\t\"setting.nowindowborder\"\t\t\"0\"\n\t\"setting.aspectratiomode\"\t\t\"-1\"\n\t\"setting.mat_vsync\"\t\t\"1\"\n"
    "\t\"setting.mat_monitorgamma\"\t\t\"2.200000\"\n\t\"setting.mat_queue_mode\"\t\t\"-1\"\n"
    "\t\"setting.mat_forceaniso\"\t\t\"16\"\n\t\"setting.gpu_level\"\t\t\"3\"\n\t\"setting.mat_antialias\"\t\t\"4\"\n"
    "\t\"setting.cpu_level\"\t\t\"0\"\n\t\"setting.videoconfig_version\"\t\t\"1\"\n\t\"setting.mem_level\"\t\t\"2\"\n"
    "\t\"setting.gpu_mem_level\"\t\t\"2\"\n\t\"setting.mat_triplebuffered\"\t\t\"0\"\n"
    "\t\"setting.defaultres\"\t\t\"2560\"\n\t\"setting.defaultresheight\"\t\t\"2560\"\n}\n";

static char *slurp(const char *path, size_t *length) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    char *data = calloc(1, 70000);
    *length = fread(data, 1, 69999, f);
    fclose(f);
    return data;
}
static void put(const char *path, const char *text) {
    FILE *f = fopen(path, "wb"); assert(f); fputs(text, f); fclose(f);
}
static P2VideoConfigResult repair(const char *text, char **out) {
    size_t n;
    return p2_video_config_repair_text(text, strlen(text), out, &n);
}

static void replace_once(char *text, const char *from, const char *to) {
    char *at = strstr(text, from);
    assert(at);
    size_t a = strlen(from), b = strlen(to);
    memmove(at + b, at + a, strlen(at + a) + 1);
    memcpy(at, to, b);
}
static void text_rules(void) {
    char *out;
    // The real generated file: only three values change, nothing else.
    assert(repair(generated, &out) == P2_VIDEO_CONFIG_REPAIRED);
    char expected[sizeof(generated) + 16];
    snprintf(expected, sizeof(expected), "%s", generated);
    replace_once(expected, "\"setting.fullscreen\"\t\t\"1\"", "\"setting.fullscreen\"\t\t\"0\"");
    replace_once(expected, "\"setting.defaultres\"\t\t\"2560\"", "\"setting.defaultres\"\t\t\"1280\"");
    replace_once(expected, "\"setting.defaultresheight\"\t\t\"2560\"", "\"setting.defaultresheight\"\t\t\"720\"");
    assert(!strcmp(out, expected));
    // Repeated migration is a no-op.
    char *again;
    assert(repair(out, &again) == P2_VIDEO_CONFIG_UNCHANGED && !again);
    free(out);
    // Format variations of the same data: spaces, CRLF, bare tokens, comments,
    // key case, values before/after other keys, no fullscreen key.
    assert(repair("// video\r\n\"config\" {\r\n  setting.DefaultRes 2560 \"setting.defaultresheight\" \"2560\"\r\n"
                  "  \"Setting.Fullscreen\"  1 // was fullscreen\r\n}\r\n", &out) == P2_VIDEO_CONFIG_REPAIRED);
    assert(!strcmp(out, "// video\r\n\"config\" {\r\n  setting.DefaultRes 1280 \"setting.defaultresheight\" \"720\"\r\n"
                        "  \"Setting.Fullscreen\"  0 // was fullscreen\r\n}\r\n"));
    free(out);
    assert(repair("\"config\"{\"setting.defaultresheight\"\"2560\"\"setting.defaultres\"\"2560\"}", &out) == P2_VIDEO_CONFIG_REPAIRED);
    assert(!strcmp(out, "\"config\"{\"setting.defaultresheight\"\"720\"\"setting.defaultres\"\"1280\"}"));
    free(out);
    // Nested blocks are skipped, not misread.
    assert(repair("\"config\" { \"x\" { \"setting.defaultres\" \"1\" } \"setting.defaultres\" \"2560\" "
                  "\"setting.defaultresheight\" \"2560\" }", &out) == P2_VIDEO_CONFIG_REPAIRED);
    assert(strstr(out, "\"x\" { \"setting.defaultres\" \"1\" }") && strstr(out, "\"1280\"")); free(out);
    // Player choices are kept, including a fullscreen 2560x1440 and 1920x1080.
    assert(repair("\"config\" { \"setting.defaultres\" \"2560\" \"setting.defaultresheight\" \"1440\" \"setting.fullscreen\" \"1\" }", &out) == P2_VIDEO_CONFIG_UNCHANGED);
    assert(repair("\"config\" { \"setting.defaultres\" \"1920\" \"setting.defaultresheight\" \"1080\" }", &out) == P2_VIDEO_CONFIG_UNCHANGED);
    assert(repair("\"config\" { \"setting.defaultres\" \"2560\" }", &out) == P2_VIDEO_CONFIG_UNCHANGED);
    // Malformed or ambiguous data is never edited.
    const char *bad[] = {
        "", "\"config\"", "\"config\" {", "\"config\" { \"setting.defaultres\" \"2560\" \"setting.defaultresheight\" \"2560\"",
        "\"config\" { \"setting.defaultres\" \"2560 \n\"setting.defaultresheight\" \"2560\" }",
        "\"config\" { \"setting.defaultres\" \"2560\" \"setting.defaultres\" \"2560\" \"setting.defaultresheight\" \"2560\" }",
        "\"config\" { \"setting.defaultres\" \"2560\" \"setting.defaultresheight\" }",
        "\"config\" { \"setting.defaultres\" \"2560\" \"setting.defaultresheight\" \"2560\" } \"extra\"",
        "{ \"setting.defaultres\" \"2560\" \"setting.defaultresheight\" \"2560\" }",
    };
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i) {
        assert(repair(bad[i], &out) == P2_VIDEO_CONFIG_SKIPPED && !out);
    }
    size_t n;
    char embedded[] = "\"config\" { \"setting.defaultres\" \"2560\" \0 \"setting.defaultresheight\" \"2560\" }";
    assert(p2_video_config_repair_text(embedded, sizeof(embedded) - 1, &out, &n) == P2_VIDEO_CONFIG_SKIPPED);
}

static void files(void) {
    char root[] = "/tmp/p2-video-XXXXXX";
    assert(mkdtemp(root));
    char path[512], backup[512], message[256];
    size_t length;
    // Absent: seeded, parents created, the seed itself is already repaired.
    snprintf(path, sizeof(path), "%s/portal2-userdata/update/cfg/video.txt", root);
    assert(p2_video_config_prepare(path, message, sizeof(message)) == P2_VIDEO_CONFIG_SEEDED);
    char *data = slurp(path, &length);
    assert(data && strstr(data, "\"setting.defaultres\"\t\t\"1280\"") && strstr(data, "\"setting.fullscreen\"\t\t\"0\""));
    char *out;
    assert(p2_video_config_repair_text(data, length, &out, &length) == P2_VIDEO_CONFIG_UNCHANGED);
    free(data);
    assert(p2_video_config_prepare(path, message, sizeof(message)) == P2_VIDEO_CONFIG_UNCHANGED);
    // Generated: repaired with a byte-exact backup; repeating changes nothing.
    put(path, generated);
    assert(p2_video_config_prepare(path, message, sizeof(message)) == P2_VIDEO_CONFIG_REPAIRED);
    snprintf(backup, sizeof(backup), "%s%s", path, P2_VIDEO_CONFIG_BACKUP_SUFFIX);
    data = slurp(backup, &length);
    assert(data && length == sizeof(generated) - 1 && !memcmp(data, generated, length)); free(data);
    data = slurp(path, &length);
    assert(strstr(data, "\"1280\"") && strstr(data, "\"720\"") && !strstr(data, "2560")); free(data);
    assert(p2_video_config_prepare(path, message, sizeof(message)) == P2_VIDEO_CONFIG_UNCHANGED);
    // The engine regenerates it later: repaired again, first backup kept.
    put(path, generated);
    put(backup, "older original");
    assert(p2_video_config_prepare(path, message, sizeof(message)) == P2_VIDEO_CONFIG_REPAIRED);
    data = slurp(backup, &length); assert(!strcmp(data, "older original")); free(data);
    // Custom and malformed files: byte-identical afterwards.
    const char *kept[] = {"\"config\" { \"setting.defaultres\" \"1920\" \"setting.defaultresheight\" \"1080\" }\n",
                          "\"config\" { \"setting.defaultres\" \"2560\" \"setting.defaultresheight\" \"2560\"\n"};
    for (int i = 0; i < 2; ++i) {
        put(path, kept[i]);
        assert(p2_video_config_prepare(path, message, sizeof(message)) == (i ? P2_VIDEO_CONFIG_SKIPPED : P2_VIDEO_CONFIG_UNCHANGED));
        data = slurp(path, &length); assert(!strcmp(data, kept[i])); free(data);
    }
    // No temp files left behind.
    char temporary[600];
    snprintf(temporary, sizeof(temporary), "%s.p2-tmp", path);
    assert(access(temporary, F_OK));
    // Unwritable folder: reported failure, original untouched.
    if (geteuid()) {
        put(path, generated);
        unlink(backup);
        char folder[512];
        snprintf(folder, sizeof(folder), "%s/portal2-userdata/update/cfg", root);
        assert(!chmod(folder, 0555));
        assert(p2_video_config_prepare(path, message, sizeof(message)) == P2_VIDEO_CONFIG_FAILED);
        assert(!chmod(folder, 0755));
        data = slurp(path, &length); assert(!strcmp(data, generated)); free(data);
        snprintf(path, sizeof(path), "%s/locked/update/cfg/video.txt", root);
        snprintf(folder, sizeof(folder), "%s/locked", root);
        assert(!mkdir(folder, 0555));
        assert(p2_video_config_prepare(path, message, sizeof(message)) == P2_VIDEO_CONFIG_FAILED);
        assert(!chmod(folder, 0755));
    }
    char command[600];
    snprintf(command, sizeof(command), "rm -rf '%s'", root);
    assert(!system(command));
}

int main(void) {
    text_rules(); files();
    puts("Video config passed: generated repair, idempotence, backup, seed, custom/malformed/ambiguous untouched, failures reported");
    return 0;
}
