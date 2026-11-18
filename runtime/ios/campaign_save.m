#include <TargetConditionals.h>
#if TARGET_OS_IPHONE || TARGET_OS_VISION
#import "campaign_save.h"
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

uint64_t SteamAPI_ISteamUser_GetSteamID(void *user);
const char *rt_ios_case_path(const char *canonical, size_t trusted);

static BOOL saveHeaderTokens(NSData *data, uint32_t count, unsigned headerToken, unsigned mapToken) {
    const char *token = data.bytes, *end = token + data.length;
    BOOL header = NO, map = NO;
    for (uint32_t i = 0; i < count && token < end && !(header && map); ++i) {
        const char *terminator = memchr(token, 0, (size_t)(end - token));
        if (!terminator) return NO;
        if (i == headerToken) header = !strcmp(token, "GameHeader");
        if (i == mapToken) map = !strcmp(token, "mapName");
        token = terminator + 1;
    }
    return header && map;
}

static BOOL completeSaveArchive(int file, off_t offset, off_t fileSize, const char *map) {
    uint32_t count;
    if (pread(file, &count, sizeof(count), offset) != sizeof(count)) return NO;
    count = CFSwapInt32LittleToHost(count);
    offset += sizeof(count);
    // Each packed state file has a 260-byte name and a 32-bit payload length.
    unsigned char entry[260 + sizeof(uint32_t)];
    if (!count || count > (fileSize - offset) / (off_t)sizeof(entry)) return NO;
    char levelState[128 + sizeof(".hl1")];
    snprintf(levelState, sizeof(levelState), "%s.hl1", map);
    BOOL hasLevelState = NO;
    for (uint32_t i = 0; i < count; ++i) {
        if (pread(file, entry, sizeof(entry), offset) != sizeof(entry) || !memchr(entry, 0, 260)) return NO;
        uint32_t bytes;
        memcpy(&bytes, entry + 260, sizeof(bytes));
        bytes = CFSwapInt32LittleToHost(bytes);
        offset += sizeof(entry);
        if (bytes > fileSize - offset) return NO;
        if (bytes && !strcasecmp((const char *)entry, levelState)) hasLevelState = YES;
        offset += bytes;
    }
    return hasLevelState && offset == fileSize;
}

static BOOL campaignSave(int file, off_t fileSize, const char *game) {
    uint32_t header[5];  // JSAV, version, serialized header length, token count and length.
    if (pread(file, header, sizeof(header), 0) != sizeof(header) || memcmp(header, "JSAV", 4) ||
        CFSwapInt32LittleToHost(header[1]) != 116) return NO;
    uint32_t dataSize = CFSwapInt32LittleToHost(header[2]), tokenCount = CFSwapInt32LittleToHost(header[3]);
    uint32_t tokenBytes = CFSwapInt32LittleToHost(header[4]);
    // Portal 2 v116 begins with GameHeader, whose first field is the fixed-size mapName.
    unsigned char fields[12 + 128];
    off_t dataOffset = (off_t)sizeof(header) + tokenBytes;
    if (!tokenCount || tokenCount > tokenBytes || tokenBytes > 128 * 1024 || dataSize < sizeof(fields) ||
        fileSize <= dataOffset + dataSize || pread(file, fields, sizeof(fields), dataOffset) != sizeof(fields) ||
        fields[0] != 4 || fields[1] || fields[8] != 128 || fields[9]) return NO;
    NSMutableData *tokens = [NSMutableData dataWithLength:tokenBytes];
    if (pread(file, tokens.mutableBytes, tokenBytes, sizeof(header)) != tokenBytes ||
        !saveHeaderTokens(tokens, tokenCount, fields[2] | (fields[3] << 8), fields[10] | (fields[11] << 8))) return NO;
    const char *map = (const char *)fields + 12;
    if (!memchr(map, 0, 128) || strncmp(map, "sp_", 3) ||
        map[strspn(map, "abcdefghijklmnopqrstuvwxyz0123456789_")] ||
        !completeSaveArchive(file, dataOffset + dataSize, fileSize, map)) return NO;
    char path[PATH_MAX];
    int length = snprintf(path, sizeof(path), "%s/portal2/maps/%s.bsp", game, map);
    const char *mapPath = length > 0 && length < (int)sizeof(path) ? rt_ios_case_path(path, strlen(game)) : NULL;
    struct stat info;
    return mapPath && !stat(mapPath, &info) && S_ISREG(info.st_mode) && info.st_size > 0;
}

NSString *p2_latest_campaign_save(const char *documents, const char *game) {
    if (!documents || !game) return nil;
    // Use the same offline account as the engine and leave the imported user's saves alone.
    char path[PATH_MAX];
    int length = snprintf(path, sizeof(path), "%s/portal2-userdata/portal2/save/%llu",
                         documents, (unsigned long long)SteamAPI_ISteamUser_GetSteamID(NULL));
    if (length <= 0 || length >= (int)sizeof(path)) return nil;
    const char *savePath = rt_ios_case_path(path, strlen(documents));
    if (!savePath) return nil;
    NSString *directory = [NSString stringWithUTF8String:savePath];
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    NSString *latest = nil;
    struct timespec newest = {0};
    for (NSString *name in names) {
        if ([name.pathExtension caseInsensitiveCompare:@"sav"] != NSOrderedSame) continue;
        NSString *stem = name.stringByDeletingPathExtension;
        const char *word = stem.UTF8String;
        if (!word || !word[0] || word[0] == '-' || strlen(word) >= P2_CAMPAIGN_SAVE_STEM_SIZE ||
            word[strspn(word, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")]) continue;
        int file = open([directory stringByAppendingPathComponent:name].fileSystemRepresentation,
                        O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
        if (file < 0) continue;
        struct stat info;
        if (!fstat(file, &info) && S_ISREG(info.st_mode)) {
            struct timespec modified = info.st_mtimespec;
            BOOL newer = !latest || modified.tv_sec > newest.tv_sec || (modified.tv_sec == newest.tv_sec &&
                (modified.tv_nsec > newest.tv_nsec || (modified.tv_nsec == newest.tv_nsec &&
                 [stem compare:latest options:NSLiteralSearch] == NSOrderedAscending)));
            if (newer && campaignSave(file, info.st_size, game)) {
                latest = stem;
                newest = modified;
            }
        }
        close(file);
    }
    return latest;
}

#endif
