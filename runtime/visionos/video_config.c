#include "video_config.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

enum { MAX_CONFIG = 64 * 1024 };

// Exactly what the engine itself wrote on visionOS, with the 16:9 window.
static const char seed[] =
    "\"config\"\n{\n"
    "\t\"VendorID\"\t\t\"1\"\n"
    "\t\"DeviceID\"\t\t\"1\"\n"
    "\t\"setting.fullscreen\"\t\t\"0\"\n"
    "\t\"setting.nowindowborder\"\t\t\"0\"\n"
    "\t\"setting.aspectratiomode\"\t\t\"-1\"\n"
    "\t\"setting.mat_vsync\"\t\t\"1\"\n"
    "\t\"setting.mat_monitorgamma\"\t\t\"2.200000\"\n"
    "\t\"setting.mat_queue_mode\"\t\t\"-1\"\n"
    "\t\"setting.mat_forceaniso\"\t\t\"16\"\n"
    "\t\"setting.gpu_level\"\t\t\"3\"\n"
    "\t\"setting.mat_antialias\"\t\t\"4\"\n"
    "\t\"setting.cpu_level\"\t\t\"0\"\n"
    "\t\"setting.videoconfig_version\"\t\t\"1\"\n"
    "\t\"setting.mem_level\"\t\t\"2\"\n"
    "\t\"setting.gpu_mem_level\"\t\t\"2\"\n"
    "\t\"setting.mat_triplebuffered\"\t\t\"0\"\n"
    "\t\"setting.defaultres\"\t\t\"1280\"\n"
    "\t\"setting.defaultresheight\"\t\t\"720\"\n"
    "}\n";

typedef struct { size_t start, length; int brace; } Token;  // brace: '{', '}' or 0

// Next KeyValues token at *at. 1 token, 0 end of text, -1 malformed.
static int next_token(const char *text, size_t length, size_t *at, Token *token) {
    size_t i = *at;
    for (;;) {
        while (i < length && (text[i] == ' ' || text[i] == '\t' || text[i] == '\r' || text[i] == '\n')) ++i;
        if (i + 1 < length && text[i] == '/' && text[i + 1] == '/') {
            while (i < length && text[i] != '\n') ++i;
            continue;
        }
        break;
    }
    if (i >= length) { *at = i; return 0; }
    if (!text[i]) return -1;
    if (text[i] == '{' || text[i] == '}') {
        *token = (Token){i, 1, text[i]};
        *at = i + 1;
        return 1;
    }
    if (text[i] == '"') {
        size_t start = ++i;
        while (i < length && text[i] != '"') {
            if (!text[i] || text[i] == '\n') return -1;
            if (text[i] == '\\' && i + 1 < length) ++i;
            ++i;
        }
        if (i >= length) return -1;
        *token = (Token){start, i - start, 0};
        *at = i + 1;
        return 1;
    }
    size_t start = i;
    while (i < length && text[i] != ' ' && text[i] != '\t' && text[i] != '\r' && text[i] != '\n' &&
           text[i] != '{' && text[i] != '}' && text[i] != '"') {
        if (!text[i]) return -1;
        ++i;
    }
    *token = (Token){start, i - start, 0};
    *at = i;
    return 1;
}

static int is(const char *text, Token token, const char *word) {
    return !token.brace && token.length == strlen(word) && !strncasecmp(text + token.start, word, token.length);
}

enum { KEY_WIDTH, KEY_HEIGHT, KEY_FULLSCREEN, KEY_COUNT };
static const char *const keys[KEY_COUNT] = {"setting.defaultres", "setting.defaultresheight", "setting.fullscreen"};

P2VideoConfigResult p2_video_config_repair_text(const char *text, size_t length, char **out, size_t *out_length) {
    if (out) *out = NULL;
    if (out_length) *out_length = 0;
    if (!text || length > MAX_CONFIG) return P2_VIDEO_CONFIG_SKIPPED;
    // Expect: name { (key value | key { ... })* } and nothing after.
    size_t at = 0;
    Token token, values[KEY_COUNT];
    int found[KEY_COUNT] = {0};
    if (next_token(text, length, &at, &token) != 1 || token.brace) return P2_VIDEO_CONFIG_SKIPPED;
    if (next_token(text, length, &at, &token) != 1 || token.brace != '{') return P2_VIDEO_CONFIG_SKIPPED;
    for (;;) {
        int got = next_token(text, length, &at, &token);
        if (got != 1) return P2_VIDEO_CONFIG_SKIPPED;            // unterminated root block
        if (token.brace == '}') break;
        if (token.brace) return P2_VIDEO_CONFIG_SKIPPED;          // a block without a key
        Token key = token, value;
        if (next_token(text, length, &at, &value) != 1 || value.brace == '}') return P2_VIDEO_CONFIG_SKIPPED;
        if (value.brace == '{') {                                  // nested block: skip it
            int depth = 1;
            while (depth) {
                if (next_token(text, length, &at, &token) != 1) return P2_VIDEO_CONFIG_SKIPPED;
                depth += token.brace == '{' ? 1 : token.brace == '}' ? -1 : 0;
            }
            continue;
        }
        for (int k = 0; k < KEY_COUNT; ++k)
            if (is(text, key, keys[k])) {
                if (found[k]++) return P2_VIDEO_CONFIG_SKIPPED;   // duplicate: ambiguous
                values[k] = value;
            }
    }
    size_t end = at;
    if (next_token(text, length, &end, &token) != 0) return P2_VIDEO_CONFIG_SKIPPED;  // trailing data
    if (!found[KEY_WIDTH] || !found[KEY_HEIGHT] ||
        !is(text, values[KEY_WIDTH], "2560") || !is(text, values[KEY_HEIGHT], "2560"))
        return P2_VIDEO_CONFIG_UNCHANGED;
    const char *replacement[KEY_COUNT] = {"1280", "720",
        found[KEY_FULLSCREEN] && is(text, values[KEY_FULLSCREEN], "1") ? "0" : NULL};
    // Apply in file order.
    int order[KEY_COUNT] = {KEY_WIDTH, KEY_HEIGHT, KEY_FULLSCREEN};
    for (int a = 0; a < KEY_COUNT; ++a)
        for (int b = a + 1; b < KEY_COUNT; ++b)
            if (found[order[b]] && (!found[order[a]] || values[order[b]].start < values[order[a]].start)) {
                int swap = order[a]; order[a] = order[b]; order[b] = swap;
            }
    char *result = malloc(length + 16);
    if (!result) return P2_VIDEO_CONFIG_FAILED;
    size_t written = 0, copied = 0;
    for (int i = 0; i < KEY_COUNT; ++i) {
        int k = order[i];
        if (!found[k] || !replacement[k]) continue;
        memcpy(result + written, text + copied, values[k].start - copied);
        written += values[k].start - copied;
        size_t n = strlen(replacement[k]);
        memcpy(result + written, replacement[k], n);
        written += n;
        copied = values[k].start + values[k].length;
    }
    memcpy(result + written, text + copied, length - copied);
    written += length - copied;
    result[written] = 0;
    if (out) *out = result; else free(result);
    if (out_length) *out_length = written;
    return P2_VIDEO_CONFIG_REPAIRED;
}

static int write_file(const char *path, const char *data, size_t length) {
    char temporary[4096];
    if (snprintf(temporary, sizeof(temporary), "%s.p2-tmp", path) >= (int)sizeof(temporary)) { errno = ENAMETOOLONG; return -1; }
    int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    size_t done = 0;
    while (done < length) {
        ssize_t n = write(fd, data + done, length - done);
        if (n < 0) { if (errno == EINTR) continue; int saved = errno; close(fd); unlink(temporary); errno = saved; return -1; }
        done += (size_t)n;
    }
    if (fsync(fd) || close(fd)) { int saved = errno; unlink(temporary); errno = saved; return -1; }
    if (rename(temporary, path)) { int saved = errno; unlink(temporary); errno = saved; return -1; }
    return 0;
}

static int make_parents(const char *path) {
    char folder[4096];
    if (snprintf(folder, sizeof(folder), "%s", path) >= (int)sizeof(folder)) { errno = ENAMETOOLONG; return -1; }
    char *slash = strrchr(folder, '/');
    if (!slash || slash == folder) return 0;
    *slash = 0;
    for (char *p = folder + 1; *p; ++p) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(folder, 0755) && errno != EEXIST) return -1;
        *p = '/';
    }
    return mkdir(folder, 0755) && errno != EEXIST ? -1 : 0;
}

P2VideoConfigResult p2_video_config_prepare(const char *path, char *message, size_t size) {
    char scratch[8];
    if (!message || !size) { message = scratch; size = sizeof(scratch); }
    if (!path || !*path) { snprintf(message, size, "no video config path"); return P2_VIDEO_CONFIG_FAILED; }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        if (errno != ENOENT) { snprintf(message, size, "video.txt unreadable: %s", strerror(errno)); return P2_VIDEO_CONFIG_FAILED; }
        if (make_parents(path) || write_file(path, seed, sizeof(seed) - 1)) {
            snprintf(message, size, "could not seed video.txt: %s (the engine writes its own)", strerror(errno));
            return P2_VIDEO_CONFIG_FAILED;
        }
        snprintf(message, size, "seeded video.txt: windowed 1280x720");
        return P2_VIDEO_CONFIG_SEEDED;
    }
    char *text = malloc(MAX_CONFIG + 1);
    size_t length = 0;
    ssize_t n = 0;
    while (text && length <= MAX_CONFIG && (n = read(fd, text + length, MAX_CONFIG + 1 - length)) != 0) {
        if (n < 0) { if (errno == EINTR) continue; break; }
        length += (size_t)n;
        if (length > MAX_CONFIG) break;
    }
    int read_error = !text || n < 0 ? (text ? errno : ENOMEM) : 0;
    close(fd);
    if (read_error) {
        free(text);
        snprintf(message, size, "video.txt unreadable: %s", strerror(read_error));
        return P2_VIDEO_CONFIG_FAILED;
    }
    char *repaired = NULL;
    size_t repaired_length = 0;
    P2VideoConfigResult result = p2_video_config_repair_text(text, length, &repaired, &repaired_length);
    if (result != P2_VIDEO_CONFIG_REPAIRED) {
        free(text);
        snprintf(message, size, result == P2_VIDEO_CONFIG_UNCHANGED ? "video.txt kept (not the generated 2560x2560 size)" :
                 result == P2_VIDEO_CONFIG_SKIPPED ? "video.txt kept: unrecognized or ambiguous data" : "video.txt repair out of memory");
        return result;
    }
    char backup[4096];
    struct stat info;
    if (snprintf(backup, sizeof(backup), "%s%s", path, P2_VIDEO_CONFIG_BACKUP_SUFFIX) >= (int)sizeof(backup) ||
        (stat(backup, &info) && (errno != ENOENT || write_file(backup, text, length)))) {
        int saved = errno;
        free(text); free(repaired);
        snprintf(message, size, "video.txt kept: backup failed: %s", strerror(saved));
        return P2_VIDEO_CONFIG_FAILED;
    }
    free(text);
    int failed = write_file(path, repaired, repaired_length);
    int saved = errno;
    free(repaired);
    if (failed) { snprintf(message, size, "video.txt kept: write failed: %s", strerror(saved)); return P2_VIDEO_CONFIG_FAILED; }
    snprintf(message, size, "repaired generated video.txt 2560x2560 fullscreen -> windowed 1280x720 (backup %s)", backup);
    return P2_VIDEO_CONFIG_REPAIRED;
}
