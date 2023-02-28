//
//  ELAudioSession.m
//  video_player
//
//  Created by apple on 16/9/5.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import "ELAudioSession.h"
#import "AVAudioSession+RouteUtils.h"

const NSTimeInterval AUSAudioSessionLatency_Background = 0.0929;
const NSTimeInterval AUSAudioSessionLatency_Default = 0.0232;
const NSTimeInterval AUSAudioSessionLatency_LowLatency = 0.0058;

@implementation ELAudioSession

+ (ELAudioSession *)sharedInstance
{
    static ELAudioSession *instance = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ELAudioSession alloc] init];
    });
    return instance;
}

- (id)init
{
    if((self = [super init]))
    {
        _preferredSampleRate = _currentSampleRate = 44100.0;
        _audioSession = [AVAudioSession sharedInstance];
    }
    return self;
}

//根据我们需要硬件设备提供的能力来设置类别
- (void)setCategory:(NSString *)category
{
    _category = category;
    
    NSError *error = nil;
    if(![self.audioSession setCategory:_category error:&error])
        NSLog(@"Could note set category on audio session: %@", error.localizedDescription);
}

- (void)setActive:(BOOL)active
{
    _active = active;
    
    NSError *error = nil;
    
    //设置采样频率，让硬件设备按照设置的采样率来采集或者播放音频
    if (![self.audioSession setPreferredSampleRate:self.preferredSampleRate error:&error])
        NSLog(@"Error when setting sample rate on audio session: %@", error.localizedDescription);
    
    //激活 AudioSession
    if (![self.audioSession setActive:_active error:&error])
        NSLog(@"Error when setting active state of audio session: %@", error.localizedDescription);
    
    _currentSampleRate = [self.audioSession sampleRate];
}

//设置 I/O 的 Buffer，Buffer 越小说明延迟越低
- (void)setPreferredLatency:(NSTimeInterval)preferredLatency
{
    _preferredLatency = preferredLatency;
    
    NSError *error = nil;
    if(![self.audioSession setPreferredIOBufferDuration:_preferredLatency error:&error])
        NSLog(@"Error when setting preferred I/O buffer duration");
}

- (void)addRouteChangeListener
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onNotificationAudioRouteChange:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:nil];
    [self adjustOnRouteChange];
}

#pragma mark - notification observer

- (void)onNotificationAudioRouteChange:(NSNotification *)notification {
//    [self adjustOnRouteChange];
    
    NSDictionary *interuptionDict = notification.userInfo;
    NSInteger routeChangeReason = [[interuptionDict valueForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
    if (routeChangeReason == AVAudioSessionRouteChangeReasonNewDeviceAvailable || routeChangeReason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable || routeChangeReason == AVAudioSessionRouteChangeReasonWakeFromSleep ) {
        //Do Something
    } else if (routeChangeReason == AVAudioSessionRouteChangeReasonCategoryChange ||
    routeChangeReason == AVAudioSessionRouteChangeReasonOverride) {
        //Do Something
    }
}

- (void)adjustOnRouteChange
{
    AVAudioSessionRouteDescription *currentRoute = [[AVAudioSession sharedInstance] currentRoute];
    if (currentRoute) {
        if ([[AVAudioSession sharedInstance] usingWiredMicrophone]) {
        } else {
            if (![[AVAudioSession sharedInstance] usingBlueTooth]) {
                [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
            }
        }
    }
}
@end
