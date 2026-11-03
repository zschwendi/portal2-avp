#pragma once
// Owned-content completeness gate, run by the visionOS and iOS launchers before
// the engine starts. Missing numbered VPK archives make the engine die after a
// NULL file handle; this check finds them from file sizes and the VPK
// directory trees alone. Loose files (campaign maps, ...) are invisible to the
// VPK trees: in the Documents layout, the content manifest lists every owned
// file with its size, and each one must be present with exactly that size.
// It reads no other file and reports only file names, counts and sizes, never
// file contents. Plain C, no platform dependencies.
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define P2_CONTENT_STATUS_FILE "portal2-setup-status.json"
// Documents/portal2-content-manifest.txt, written last by a complete import
// (visionOS importer) or delivery (tools/serve_owned_content.py
// --write-content-manifest): the header line, then one line per owned file,
// "<decimal byte size>\t<relative path>" with paths as the importer uses them
// (prep/..., linux/..., game/<folder>/...). LF or CRLF; empty lines ignored.
#define P2_CONTENT_MANIFEST_FILE "portal2-content-manifest.txt"
#define P2_CONTENT_MANIFEST_HEADER "P2-CONTENT-MANIFEST 1"
// Without a manifest (content copied by hand): the first campaign map must be
// there too, or Singleplayer fails with "test chamber is not available".
#define P2_CONTENT_SENTINEL_MAP "game/portal2/maps/sp_a1_intro1.bsp"
enum { P2_CONTENT_NAME_COUNT = 4, P2_CONTENT_NAME_SIZE = 96 };

typedef struct P2ContentReport {
    int complete;          // 1: required files present, every referenced archive present and long enough,
                           // and (p2_content_check) every manifest file present with its size, or no
                           // manifest and the sentinel campaign map present
    int required_missing;  // absent: game/portal2/pak01_dir.vpk, linux/portal2_linux, prep/layout.json
    int directories;       // pak01_dir.vpk files examined (one per game/* folder that has one)
    int bad_directories;   // unreadable, truncated or malformed directory files
    int archives;          // numbered archives referenced by entries with archive data
    int missing_archives;  // absent, or not a regular file
    int short_archives;    // shorter than the furthest byte an entry references
    int64_t missing_bytes; // estimate: extents of absent archives plus the shortfall of short ones; with a
                           // manifest, at least the listed size of every missing or wrong-size file
    // p2_content_check only (Documents layout); always 0 from p2_content_check_roots.
    int manifest;            // 0: no manifest (weaker check: archives plus the sentinel map); 1: present
    int manifest_bad;        // present but unreadable, wrong header, unsafe path, malformed line or empty
    int manifest_files;      // files it lists (0 when bad)
    int manifest_missing;    // listed files absent or not regular files
    int manifest_wrong_size; // listed files whose size differs from the listed size
    int maps_missing;        // no manifest: the sentinel campaign map is absent or empty
    int64_t elapsed_us;    // time the check took
    // Filled by the platform launcher (-1 when unknown), written to the status file.
    int64_t volume_available; // volumeAvailableCapacityForImportantUsage
    int64_t volume_total;
    int names;             // used entries of name[]
    char name[P2_CONTENT_NAME_COUNT][P2_CONTENT_NAME_SIZE]; // first problems, e.g. game/portal2/pak01_066.vpk
} P2ContentReport;

// Checks <documents>/game, <documents>/linux and <documents>/prep, then
// <documents>/portal2-content-manifest.txt: every listed file must exist as a
// regular file of exactly the listed size. Without a manifest, the sentinel
// map is required as well. Returns report->complete. Safe from any thread;
// takes milliseconds (one stat per archive and listed file, one read of each
// directory tree and of the manifest).
int p2_content_check(const char *documents, P2ContentReport *report);
// The archive and required-file checks alone, with the three roots given
// separately (explicit --game-dir, --linux-root and --images launch options,
// e.g. a simulator run against the Mac install). Names stay prefixed with
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
