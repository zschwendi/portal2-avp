#include <TargetConditionals.h>
#if TARGET_OS_VISION
#import <Foundation/Foundation.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/utsname.h>
#include <unistd.h>
#include "game_vision.h"
#include "input_vision.h"
#include "video_config.h"
#include <SDL.h>

int p2_main(int argc, char **argv);
int rt_ios_game_ui_visible_shared(void); // runtime/ios/game_state.c
int rt_ios_game_ui_ready_shared(void);
static _Atomic int state;
static _Atomic int started_fps_limit;
int p2_vision_game_state(void) { return atomic_load(&state); }
int p2_vision_game_ui_visible(void) { return atomic_load(&state) == 1 && rt_ios_game_ui_visible_shared(); }
int p2_vision_game_ui_ready(void) { return atomic_load(&state) == 1 && rt_ios_game_ui_ready_shared(); }

int p2_vision_game_hfr_target(void) {
    struct utsname device;
    // M5 Vision Pro supports a 120 Hz mode. Use 90 for M2 and unknown models.
    if (uname(&device) == 0 && strcmp(device.machine, "RealityDevice17,1") == 0) return 120;
    return 90;
}

static int configured_fps_limit(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"P2VisionHighFrameRate"] ? p2_vision_game_hfr_target() : 60;
}

int p2_vision_game_fps_limit(void) {
    int started = atomic_load(&started_fps_limit);
    return started ? started : configured_fps_limit();
}

// Immersive eye size request: width << 32 | height, 0 for the windowed size.
static _Atomic uint64_t eye_request;
static _Atomic int eye_mode;
void p2_vision_request_eye_size(int width, int height) {
    uint64_t value = width > 0 && height > 0 && width <= 8192 && height <= 8192 ?
        (uint64_t)(uint32_t)width << 32 | (uint32_t)height : 0;
    atomic_store(&eye_request, value);
}
void p2_vision_requested_eye_size(int *width, int *height) {
    uint64_t value = atomic_load(&eye_request);
    if (width) *width = (int)(value >> 32);
    if (height) *height = (int)(value & 0xffffffffu);
}
void p2_vision_set_eye_mode(int active) { atomic_store(&eye_mode, active != 0); }
int p2_vision_display_restoring(void) {
    return atomic_load(&eye_mode) && !atomic_load(&eye_request);
}
// ---- Owned-content gate ------------------------------------------------------
// The engine must never start with missing or short VPK archives: it dies
// after "Tried to Seek/Read NULL file handle!" with no crash report.
static os_unfair_lock report_lock = OS_UNFAIR_LOCK_INIT;
static P2ContentReport last_report;
static int have_report;

static NSString *documents_folder(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

// Checks Documents, adds the volume sizes and remembers the report.
static int content_check(NSString *documents, P2ContentReport *report) {
    p2_content_check(documents.length ? documents.fileSystemRepresentation : NULL, report);
    if (documents.length) {
        NSArray<NSURLResourceKey> *keys = @[NSURLVolumeAvailableCapacityForImportantUsageKey, NSURLVolumeTotalCapacityKey];
        NSDictionary<NSURLResourceKey, id> *values =
            [[NSURL fileURLWithPath:documents isDirectory:YES] resourceValuesForKeys:keys error:nil];
        NSNumber *available = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
        NSNumber *total = values[NSURLVolumeTotalCapacityKey];
        if ([available isKindOfClass:NSNumber.class]) report->volume_available = available.longLongValue;
        if ([total isKindOfClass:NSNumber.class]) report->volume_total = total.longLongValue;
    }
    os_unfair_lock_lock(&report_lock);
    last_report = *report;
    have_report = 1;
    os_unfair_lock_unlock(&report_lock);
    if (!report->complete)
        NSLog(@"[vision-game] Owned content incomplete: %d required file(s) missing, %d of %d archives missing, "
              "%d short, %d bad index(es), manifest %s (%d of %d listed files missing, %d wrong size), "
              "sentinel map %s, about %lld bytes missing; first: %s",
              report->required_missing, report->missing_archives, report->archives, report->short_archives,
              report->bad_directories, !report->manifest ? "absent" : report->manifest_bad ? "unreadable" : "read",
              report->manifest_missing, report->manifest_files, report->manifest_wrong_size,
              report->maps_missing ? "missing" : "present or not needed", (long long)report->missing_bytes,
              p2_content_report_name(report, 0));
    return report->complete;
}

// Documents/portal2-setup-status.json, read remotely with devicectl.
static void content_status(NSString *documents, const P2ContentReport *report, const char *trigger, int started) {
    if (!documents.length) return;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    id version = info[@"CFBundleShortVersionString"], build = info[@"CFBundleVersion"];
    P2ContentStatus status = {
        .platform = "visionOS",
        .app_version = [version isKindOfClass:NSString.class] ? [version UTF8String] : NULL,
        .app_build = [build isKindOfClass:NSString.class] ? [build UTF8String] : NULL,
        .trigger = trigger && *trigger ? trigger : "unspecified",
        .engine_started = started,
    };
    NSString *path = [documents stringByAppendingPathComponent:@(P2_CONTENT_STATUS_FILE)];
    if (p2_content_write_status(path.fileSystemRepresentation, report, &status))
        NSLog(@"[vision-game] Could not write %s: %s", P2_CONTENT_STATUS_FILE, strerror(errno));
}

int p2_vision_content_check(const char *trigger, P2ContentReport *out) {
    @autoreleasepool {
        NSString *documents = documents_folder();
        P2ContentReport report;
        int complete = content_check(documents, &report);
        content_status(documents, &report, trigger, atomic_load(&state) == 1);
        if (out) *out = report;
        return complete;
    }
}

int p2_vision_content_last(P2ContentReport *out) {
    os_unfair_lock_lock(&report_lock);
    int have = have_report;
    if (have && out) *out = last_report;
    os_unfair_lock_unlock(&report_lock);
    return have;
}

int p2_vision_game_start(const char *trigger) {
    int current = atomic_load(&state);
    if (current == 1 || current == 2) return 0;
    NSString *documents = documents_folder();
    NSFileManager *files = NSFileManager.defaultManager;
    P2ContentReport report;
    if (!content_check(documents, &report)) {
        atomic_compare_exchange_strong(&state, &current, -1);  // never overwrite a concurrent start
        content_status(documents, &report, trigger, atomic_load(&state) == 1);
        return atomic_load(&state) == -1 ? -1 : 0;
    }
    int fps_limit = configured_fps_limit();
    int expected = current;
    if (!atomic_compare_exchange_strong(&state, &expected, 1)) return 0;
    atomic_store(&started_fps_limit, fps_limit);
    content_status(documents, &report, trigger, 1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        @autoreleasepool {
            NSString *user = [documents stringByAppendingPathComponent:@"portal2-userdata"];
            [files createDirectoryAtPath:user withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *log = [documents stringByAppendingPathComponent:@"game.log"];
            if (freopen(log.fileSystemRepresentation, "w", stderr)) {
                dup2(fileno(stderr), STDOUT_FILENO);
                setvbuf(stderr, NULL, _IONBF, 0);
                setvbuf(stdout, NULL, _IONBF, 0);
            }
            struct rlimit limits;
            if (!getrlimit(RLIMIT_NOFILE, &limits)) {
                limits.rlim_cur = limits.rlim_max == RLIM_INFINITY ? 10240 : MIN((rlim_t)10240, limits.rlim_max);
                setrlimit(RLIMIT_NOFILE, &limits);
            }
            char executable[4096]; uint32_t length = sizeof(executable);
            if (_NSGetExecutablePath(executable, &length)) { atomic_store(&state, 2); return; }
            // The engine's first video config follows the 2560x2560 virtual
            // display and then runs 2560x720 (video_config.h). Only that
            // generated value is repaired; a failure keeps the engine's file.
            char video_message[512];
            NSString *video = [user stringByAppendingPathComponent:@"update/cfg/video.txt"];
            P2VideoConfigResult video_result = p2_video_config_prepare(video.fileSystemRepresentation,
                                                                       video_message, sizeof(video_message));
            fprintf(stderr, "[vision-game] Video config: %s (result %d)\n", video_message, (int)video_result);
            setenv("P2_STEAM_API_DYLIB", executable, 1); // Existing mobile offline stub.
            setenv("SteamAppId", "620", 1); setenv("SteamGameId", "620", 1);
            setenv("SDL_VIDEODRIVER", "dummy", 1);
            SDL_SetMainReady();
            if (p2_vision_input_init()) fprintf(stderr,"[vision-input] Initialization failed: %s\n",SDL_GetError());
            NSMutableArray<NSString *> *arguments = [@[@"portal2", @"--images",
                [documents stringByAppendingPathComponent:@"prep"], @"--game-dir",
                [documents stringByAppendingPathComponent:@"game"], @"--linux-root",
                [documents stringByAppendingPathComponent:@"linux"], @"--user-dir", user,
                @"--", @"-game", @"portal2", @"-novid", @"-window", @"-insecure",
                @"-w", @"1280", @"-h", @"720", @"+mat_queue_mode", @"0"] mutableCopy];
            BOOL high_frame_rate = fps_limit > 60;
            if (!high_frame_rate) [arguments addObjectsFromArray:@[@"+fps_max", @"60"]];
            NSString *extra = [NSString stringWithContentsOfFile:[documents stringByAppendingPathComponent:@"launch.args"]
                                                       encoding:NSUTF8StringEncoding error:nil];
#if TARGET_OS_SIMULATOR
            const char *input_audit = getenv("P2_VISION_INPUT_AUDIT");
            if (input_audit && !strcmp(input_audit,"1")) [arguments addObject:@"-condebug"];
            const char *test_map = getenv("P2_VISION_TEST_MAP");
            if (test_map && *test_map) {
                NSString *map = [NSString stringWithUTF8String:test_map];
                NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                    @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
                NSString *path = [documents stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"game/portal2/maps/%@.bsp",map]];
                if ([map rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
                    [files fileExistsAtPath:path]) {
                    [arguments addObjectsFromArray:@[@"+map",map]];
                    extra = nil; // Development override never changes the player's launch file.
                }
            }
#endif
            for (NSString *line in [extra componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
                if (line.length && ![line hasPrefix:@"#"]) [arguments addObject:line];
            if (high_frame_rate) [arguments addObjectsFromArray:@[@"+fps_max", @(fps_limit).stringValue]];
            int argc = (int)arguments.count;
            char **argv = calloc((size_t)argc + 1, sizeof(*argv));
            if (!argv) { atomic_store(&state, 2); return; }
            for (int i = 0; i < argc; ++i) argv[i] = strdup(arguments[(NSUInteger)i].UTF8String);
            fprintf(stderr, "[vision-game] Engine frame rate target: %d FPS (%s)\n", fps_limit,
                    high_frame_rate ? "High Frame Rate" : "launch default");
            fprintf(stderr, "[vision-game] Starting actual recompiled Portal 2; offline mobile Steam stub; immersive stereo not attached\n");
            int result = p2_main(argc, argv);
            fprintf(stderr, "[vision-game] Engine returned %d\n", result);
            for (int i = 0; i < argc; ++i) free(argv[i]); free(argv);
            atomic_store(&state, 2);
        }
    });
    return 0;
}
#endif
