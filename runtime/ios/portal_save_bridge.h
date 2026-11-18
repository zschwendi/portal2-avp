#pragma once
#import <Foundation/Foundation.h>
@class UIViewController;

// Shared Swift save model, called on the UIKit thread before p2_main starts.
@interface P2SaveBridge : NSObject
+ (void)configureUserDirectory:(NSString *)userDirectory;
+ (NSString *)status;
+ (BOOL)cloudConfigured;
+ (BOOL)playOffline;
+ (void)prepareWithCloud:(BOOL)withCloud completion:(void (^)(BOOL ready))completion;
+ (void)launchDidNotStart;
+ (void)presentFrom:(UIViewController *)parent savesChanged:(void (^)(void))savesChanged;
@end
