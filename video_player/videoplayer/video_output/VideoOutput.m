//
//  VideoOutput.m
//  video_player
//
//  Created by apple on 16/8/25.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import "VideoOutput.h"
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import "YUVFrameCopier.h"
#import "ContrastEnhancerFilter.h"
#import "DirectPassRenderer.h"
#import <Foundation/Foundation.h>

/**
 * 本类的职责:
 *  1:作为一个UIView的子类, 必须提供layer的绘制, 我们这里是靠RenderBuffer和我们的CAEAGLLayer进行绑定来绘制的
 *  2:需要构建OpenGL的环境, EAGLContext与运行Thread
 *  3:调用第三方的Filter与Renderer去把YUV420P的数据处理以及渲染到RenderBuffer上
 *  4:由于这里面涉及到OpenGL的操作, 要增加NotificationCenter的监听, 在applicationWillResignActive 停止绘制
 *
 */

@interface VideoOutput()

@property (atomic) BOOL readyToRender;
@property (nonatomic, assign) BOOL shouldEnableOpenGL;
@property (nonatomic, strong) NSLock *shouldEnableOpenGLLock;
@property (nonatomic, strong) NSOperationQueue *renderOperationQueue;

@end

@implementation VideoOutput 
{
    EAGLContext*                            _context;
    GLuint                                  _displayFramebuffer;
    GLuint                                  _renderbuffer;
    GLint                                   _backingWidth;
    GLint                                   _backingHeight;
    
    BOOL                                    _stopping;
    
    YUVFrameCopier*                         _videoFrameCopier;
    
    BaseEffectFilter*                       _filter;
    
    DirectPassRenderer*                     _directPassRenderer;
}

//重写父类 UIView 的 layerClass 方法，并且一定要返回 CAEAGLLayer 这个类型
+ (Class) layerClass
{
    return [CAEAGLLayer class];
}

- (id) initWithFrame:(CGRect)frame textureWidth:(NSInteger)textureWidth textureHeight:(NSInteger)textureHeight {
    return [self initWithFrame:frame textureWidth:textureWidth textureHeight:textureHeight shareGroup:nil];
}

- (id) initWithFrame:(CGRect)frame textureWidth:(NSInteger)textureWidth textureHeight:(NSInteger)textureHeight  shareGroup:(EAGLSharegroup *)shareGroup
{
    self = [super initWithFrame:frame];
    if (self) {
        _shouldEnableOpenGLLock = [NSLock new];
        [_shouldEnableOpenGLLock lock];
        _shouldEnableOpenGL = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
        [_shouldEnableOpenGLLock unlock];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        
        //拿到 layer 并强制把类型转换为 CAEAGLLayer 类型的变量，然后给这个 layer 设置对应的参数
        CAEAGLLayer *eaglLayer = (CAEAGLLayer*) self.layer;
        eaglLayer.opaque = YES;
        eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
                                        [NSNumber numberWithBool:FALSE], kEAGLDrawablePropertyRetainedBacking,
                                        kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat,
                                        nil];
        
        //创建 OpenGL 线程，线程模型我们采用 NSOperationQueue 来实现，由于一些低端设备执行一次 OpenGL 的绘制耗费的时间可能比较长，如果使用 GCD 的线程模型的话，就有可能导致 DispatchQueue 里面的绘制操作累积得越来越多，并且不能清空。如果使用 NSOperationQueue 的话，可以在检测到这个 Queue 里面的 Operation 的数量，当超过定义的阈值（Threshold）时，就会清空老的 Operation，只保留最新的绘制操作。
        _renderOperationQueue = [[NSOperationQueue alloc] init];
        _renderOperationQueue.maxConcurrentOperationCount = 1;
        _renderOperationQueue.name = @"com.changba.video_player.videoRenderQueue";
        
        __weak VideoOutput *weakSelf = self;
        [_renderOperationQueue addOperationWithBlock:^{
            if (!weakSelf) {
                return;
            }

            __strong VideoOutput *strongSelf = weakSelf;
            //创建 OpenGL ES 的上下文
            if (shareGroup) {
                strongSelf->_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2 sharegroup:shareGroup];
            } else {
                strongSelf->_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
            }
            
            //绑定上下文，建立好了 EAGL 与 OpenGL ES 的连接
            if (!strongSelf->_context || ![EAGLContext setCurrentContext:strongSelf->_context]) {
                NSLog(@"Setup EAGLContext Failed...");
            }
            if(![strongSelf createDisplayFramebuffer]){
                NSLog(@"create Dispaly Framebuffer failed...");
            }
            
            [strongSelf createCopierInstance];
            if (![strongSelf->_videoFrameCopier prepareRender:textureWidth height:textureHeight]) {
                NSLog(@"_videoFrameFastCopier prepareRender failed...");
            }
            
            strongSelf->_filter = [self createImageProcessFilterInstance];
            if (![strongSelf->_filter prepareRender:textureWidth height:textureHeight]) {
                NSLog(@"_contrastEnhancerFilter prepareRender failed...");
            }
            [strongSelf->_filter setInputTexture:[strongSelf->_videoFrameCopier outputTextureID]];
            
            strongSelf->_directPassRenderer = [[DirectPassRenderer alloc] init];
            if (![strongSelf->_directPassRenderer prepareRender:textureWidth height:textureHeight]) {
                NSLog(@"_directPassRenderer prepareRender failed...");
            }
            [strongSelf->_directPassRenderer setInputTexture:[strongSelf->_filter outputTextureID]];
            strongSelf.readyToRender = YES;
        }];
    }
    return self;
}

- (BaseEffectFilter*) createImageProcessFilterInstance
{
    return [[ContrastEnhancerFilter alloc] init];
}

- (BaseEffectFilter*) getImageProcessFilterInstance
{
    return _filter;
}

- (void) createCopierInstance
{
    _videoFrameCopier = [[YUVFrameCopier alloc] init];
}

static int count = 0;
//static int totalDroppedFrames = 0;

//当前operationQueue里允许最多的帧数，理论上好的机型上不会有超过1帧的情况，差一些的机型（比如iPod touch），渲染的比较慢，
//队列里可能会有多帧的情况，这种情况下，如果有超过三帧，就把除了最近3帧以前的帧移除掉（对应的operation cancel掉）
static const NSInteger kMaxOperationQueueCount = 3;

- (void) presentVideoFrame:(VideoFrame*) frame;
{
    if(_stopping){
        NSLog(@"Prevent A InValid Renderer >>>>>>>>>>>>>>>>>");
        return;
    }
    
    @synchronized (self.renderOperationQueue) {
        NSInteger operationCount = _renderOperationQueue.operationCount;
        //判断当前 OperationQueue 里面的 operation 的数目，如果大于规定的阈值（一般为 2 或者 3），就说明每一次绘制花费的时间较多，导致渲染队列积攒的数量越来越多了，我们应该删除最久的绘制操作，只保留与阈值个数对应的绘制操作数量，然后将本次绘制操作加入到绘制队列中。
        if (operationCount > kMaxOperationQueueCount) {
            [_renderOperationQueue.operations enumerateObjectsUsingBlock:^(__kindof NSOperation * _Nonnull operation, NSUInteger idx, BOOL * _Nonnull stop) {
                if (idx < operationCount - kMaxOperationQueueCount) {
                    [operation cancel];
                } else {
                    //totalDroppedFrames += (idx - 1);
                    //NSLog(@"===========================❌ Dropped frames: %@, total: %@", @(idx - 1), @(totalDroppedFrames));
                    *stop = YES;
                }
            }];
        }
        
        __weak VideoOutput *weakSelf = self;
        [_renderOperationQueue addOperationWithBlock:^{
            if (!weakSelf) {
                return;
            }

            __strong VideoOutput *strongSelf = weakSelf;
            
            [strongSelf.shouldEnableOpenGLLock lock];
            if (!strongSelf.readyToRender || !strongSelf.shouldEnableOpenGL) {
                //每次写完绘图代码，想让它立即完成效果的时候，就需要我们自己手动调用 glFlush() 或 gLFinish() 函数，将缓冲区中的指令（无论是否为满）立刻送给图形硬件执行，但是要等待图形硬件执行完后这些指令才返回。
                glFinish();
                [strongSelf.shouldEnableOpenGLLock unlock];
                return;
            }
            [strongSelf.shouldEnableOpenGLLock unlock];
            count++;
            int frameWidth = (int)[frame width];
            int frameHeight = (int)[frame height];
            [EAGLContext setCurrentContext:strongSelf->_context];
            [strongSelf->_videoFrameCopier renderWithTexId:frame];
            [strongSelf->_filter renderWithWidth:frameWidth height:frameHeight position:frame.position];
            
            glBindFramebuffer(GL_FRAMEBUFFER, strongSelf->_displayFramebuffer);
            //使用 GLProgram 进行绘制
            [strongSelf->_directPassRenderer renderWithWidth:strongSelf->_backingWidth height:strongSelf->_backingHeight position:frame.position];
            glBindRenderbuffer(GL_RENDERBUFFER, strongSelf->_renderbuffer);
            //将刚刚绘制的内容显示到 layer 上去，最终用户就可以在 UIView 中看到我们刚刚绘制的内容了
            [strongSelf->_context presentRenderbuffer:GL_RENDERBUFFER];
        }];
    }
    
}

- (BOOL) createDisplayFramebuffer;
{
    BOOL ret = TRUE;
    //创建帧缓冲区
    glGenFramebuffers(1, &_displayFramebuffer);
    //创建绘制缓冲区
    glGenRenderbuffers(1, &_renderbuffer);
    //绑定帧缓冲区到渲染管线
    glBindFramebuffer(GL_FRAMEBUFFER, _displayFramebuffer);
    //绑定绘制缓存区到渲染管线
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
    //为绘制缓冲区分配存储区，这里我们把 CAEAGLLayer 的绘制存储区作为绘制缓冲区的存储区。
    [_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
    //获取绘制缓冲区的像素宽度
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_backingWidth);
    //获取绘制缓冲区的像素高度
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_backingHeight);
    //绑定绘制缓冲区到帧缓冲区
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _renderbuffer);
    
    //检查 Framebuffer 的 status
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"failed to make complete framebuffer object %x", status);
        return FALSE;
    }
    
    GLenum glError = glGetError();
    if (GL_NO_ERROR != glError) {
        NSLog(@"failed to setup GL %x", glError);
        return FALSE;
    }
    return ret;
}

//由于所有涉及 OpenGL ES 的操作都要放到绑定了上下文环境的线程中去操作，所以这个方法中对 OpenGL ES 的操作也要保证放到 OperationQueue 中去执行。
- (void) destroy;
{
    _stopping = true;
    
    __weak VideoOutput *weakSelf = self;
    [self.renderOperationQueue addOperationWithBlock:^{
        if (!weakSelf) {
            return;
        }
        __strong VideoOutput *strongSelf = weakSelf;
        //把 GLProgram 释放掉
        if(strongSelf->_videoFrameCopier) {
            [strongSelf->_videoFrameCopier releaseRender];
        }
        if(strongSelf->_filter) {
            [strongSelf->_filter releaseRender];
        }
        if(strongSelf->_directPassRenderer) {
            [strongSelf->_directPassRenderer releaseRender];
        }
        if (strongSelf->_displayFramebuffer) {
            glDeleteFramebuffers(1, &strongSelf->_displayFramebuffer);
            strongSelf->_displayFramebuffer = 0;
        }
        if (strongSelf->_renderbuffer) {
            glDeleteRenderbuffers(1, &strongSelf->_renderbuffer);
            strongSelf->_renderbuffer = 0;
        }
        
        //解除本线程与 OpenGL 上下文之间的绑定
        if ([EAGLContext currentContext] == strongSelf->_context) {
            [EAGLContext setCurrentContext:nil];
        }
    }];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (_renderOperationQueue) {
        [_renderOperationQueue cancelAllOperations];
        _renderOperationQueue = nil;
    }
    
    _videoFrameCopier = nil;
    _filter = nil;
    _directPassRenderer = nil;
    
    _context = nil;
    NSLog(@"Render Frame Count is %d", count);
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self.shouldEnableOpenGLLock lock];
    self.shouldEnableOpenGL = NO;
    [self.shouldEnableOpenGLLock unlock];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self.shouldEnableOpenGLLock lock];
    self.shouldEnableOpenGL = YES;
    [self.shouldEnableOpenGLLock unlock];
}

@end
