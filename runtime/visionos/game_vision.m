#include <TargetConditionals.h>
#if TARGET_OS_VISION
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include "game_vision.h"
#include "input_vision.h"
#include <SDL.h>

int p2_main(int argc, char **argv);
int rt_ios_game_ui_visible_shared(void); // runtime/ios/game_state.c
static _Atomic int state;
int p2_vision_game_state(void) { return atomic_load(&state); }
int p2_vision_game_ui_visible(void) { return atomic_load(&state) == 1 && rt_ios_game_ui_visible_shared(); }

// Immersive eye size request: width << 32 | height, 0 for the windowed size.
static _Atomic uint64_t eye_request, eye_withdrawn_ns;
static _Atomic int eye_mode;
void p2_vision_request_eye_size(int width, int height) {
    uint64_t value = width > 0 && height > 0 && width <= 8192 && height <= 8192 ?
        (uint64_t)(uint32_t)width << 32 | (uint32_t)height : 0;
    // Stamp before withdrawing, so a reader never pairs 0 with an old stamp.
    // Callers serialize (PortalPresentation's lock).
    if (!value && atomic_load(&eye_request)) atomic_store(&eye_withdrawn_ns, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    atomic_store(&eye_request, value);
}
void p2_vision_requested_eye_size(int *width, int *height) {
    uint64_t value = atomic_load(&eye_request);
    if (width) *width = (int)(value >> 32);
    if (height) *height = (int)(value & 0xffffffffu);
}
void p2_vision_set_eye_mode(int active) { atomic_store(&eye_mode, active != 0); }
int p2_vision_display_restoring(void) {
    if (!atomic_load(&eye_mode) || atomic_load(&eye_request)) return 0;
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - atomic_load(&eye_withdrawn_ns) < 2500000000ull;
}
// Placeholder until the engine-side controller aim code links its strong
// definition (a strong symbol replaces this weak one at link time).
__attribute__((weak)) int p2_vision_controller_aim_active(void) { return -1; }

int p2_vision_game_start(void) {
    if (atomic_load(&state) == 1 || atomic_load(&state) == 2) return 0;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *relative in @[@"game/portal2/pak01_dir.vpk", @"linux/portal2_linux", @"prep/layout.json"]) {
        if (![files fileExistsAtPath:[documents stringByAppendingPathComponent:relative]]) {
            atomic_store(&state, -1);
            return -1;
        }
    }
    int expected = atomic_load(&state);
    if (!atomic_compare_exchange_strong(&state, &expected, 1)) return 0;
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
                @"-w", @"1280", @"-h", @"720", @"+mat_queue_mode", @"0", @"+fps_max", @"60"] mutableCopy];
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
            int argc = (int)arguments.count;
            char **argv = calloc((size_t)argc + 1, sizeof(*argv));
            if (!argv) { atomic_store(&state, 2); return; }
            for (int i = 0; i < argc; ++i) argv[i] = strdup(arguments[(NSUInteger)i].UTF8String);
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
