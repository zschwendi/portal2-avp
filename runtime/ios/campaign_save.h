#pragma once

#define P2_CAMPAIGN_SAVE_STEM_SIZE 64

#ifdef __OBJC__
#import <Foundation/Foundation.h>

// Latest complete single-player slot for the offline mobile account, with a
// valid header, packed level state and installed map. Does not write files.
NSString *p2_latest_campaign_save(const char *documents, const char *game);
#endif
