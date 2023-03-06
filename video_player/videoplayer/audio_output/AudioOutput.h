//
//  AudioOutput.h
//  video_player
//
//  Created by apple on 16/8/25.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import <Foundation/Foundation.h>

//设计一个回调函数用来获取要渲染的 PCM 数据，在 OC 中回调函数的实现一般是定义一个协议（Protocol），由调用端去实现这个协议，重写协议里面定义的方法
@protocol FillDataDelegate <NSObject>

- (NSInteger) fillAudioData:(SInt16*) sampleBuffer numFrames:(NSInteger)frameNum numChannels:(NSInteger)channels;

@end

@interface AudioOutput : NSObject

@property(nonatomic, assign) Float64 sampleRate;
@property(nonatomic, assign) Float64 channels;

- (id) initWithChannels:(NSInteger) channels sampleRate:(NSInteger) sampleRate bytesPerSample:(NSInteger) bytePerSample fillDataDelegate:(id<FillDataDelegate>) fillAudioDataDelegate;

- (BOOL) play;
- (void) stop;

@end
