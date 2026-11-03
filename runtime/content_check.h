#pragma once
// Owned-content completeness gate, run by the visionOS and iOS launchers before
// the engine starts. Missing numbered VPK archives make the engine die after a
// NULL file handle; this check finds them from file sizes and the VPK
// directory trees alone. It reads no other file and reports only file names,
// counts and sizes, never file contents. Plain C, no platform dependencies.
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define P2_CONTENT_STATUS_FILE "portal2-setup-status.json"
enum { P2_CONTENT_NAME_COUNT = 4, P2_CONTENT_NAME_SIZE = 96 };

typedef struct P2ContentReport {
    int complete;          // 1: required files present, every referenced archive present and long enough
    int required_missing;  // absent: game/portal2/pak01_dir.vpk, linux/portal2_linux, prep/layout.json
    int directories;       // pak01_dir.vpk files examined (one per game/* folder that has one)
    int bad_directories;   // unreadable, truncated or malformed directory files
    int archives;          // numbered archives referenced by entries with archive data
    int missing_archives;  // absent, or not a regular file
    int short_archives;    // shorter than the furthest byte an entry references
    int64_t missing_bytes; // estimate: extents of absent archives plus the shortfall of short ones
    int64_t elapsed_us;    // time the check took
    // Filled by the platform launcher (-1 when unknown), written to the status file.
    int64_t volume_available; // volumeAvailableCapacityForImportantUsage
    int64_t volume_total;
    int names;             // used entries of name[]
    char name[P2_CONTENT_NAME_COUNT][P2_CONTENT_NAME_SIZE]; // first problems, e.g. game/portal2/pak01_066.vpk
} P2ContentReport;

// Checks <documents>/game, <documents>/linux and <documents>/prep. Returns
// report->complete. Safe from any thread; takes milliseconds (one stat per
// archive and one read of each directory tree).
int p2_content_check(const char *documents, P2ContentReport *report);
// Same with the three roots given separately (explicit --game-dir,
// --linux-root and --images launch options). Names stay prefixed with
// game/, linux/ and prep/.
int p2_content_check_roots(const char *game, const char *linux_root, const char *prep, P2ContentReport *report);
// Name `index` of the report, "" when out of range. Never NULL.
const char *p2_content_report_name(const P2ContentReport *report, int index);

typedef struct P2ContentStatus {
    const char *platform;    // "visionOS", "iOS", "iPadOS"
    const char *app_version; // CFBundleShortVersionString, or NULL
    const char *app_build;   // CFBundleVersion, or NULL
    const char *trigger;     // "launch", "check-again", "engine-start", ...
    int engine_started;      // the launcher starts (or already runs) the engine after this check
} P2ContentStatus;

// Writes a small JSON status (timestamp, app version, counts, first missing
// names, volume sizes, engine started) to `path` atomically (temporary file
// and rename). Returns 0, or -1 with errno set.
int p2_content_write_status(const char *path, const P2ContentReport *report, const P2ContentStatus *status);

#ifdef __cplusplus
}
#endif
