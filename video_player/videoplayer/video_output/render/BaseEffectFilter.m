//
//  BaseEffectFilter.m
//  video_player
//
//  Created by apple on 16/9/1.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import "BaseEffectFilter.h"

@implementation BaseEffectFilter

- (BOOL) prepareRender:(NSInteger) frameWidth height:(NSInteger) frameHeight;
{
    return NO;
}

//template method
- (void) renderWithWidth:(NSInteger) width height:(NSInteger) height position:(float)position {
    
}

- (BOOL) buildProgram:(NSString*) vertexShader fragmentShader:(NSString*) fragmentShader;
{
    BOOL result = NO;
    GLuint vertShader = 0, fragShader = 0;
    //创建一个程序的实例作为程序的容器
    filterProgram = glCreateProgram();
    
    /**
    函数原型中的参数 shaderType 有两种类型：
    一是 GL_VERTEX_SHADER，创建顶点着色器时开发者应传入的类型；
    二是 GL_FRAGMENT_SHADER，创建片元着色器时开发者应传入的类型。
    */
    vertShader = compileShader(GL_VERTEX_SHADER, vertexShader); //顶点着色器
    if (!vertShader)
        goto exit;
    fragShader = compileShader(GL_FRAGMENT_SHADER, fragmentShader); //片元着色器
    if (!fragShader)
        goto exit;
    
    //将编译的 shader 附加（Attach）到创建的程序中
    glAttachShader(filterProgram, vertShader);
    glAttachShader(filterProgram, fragShader);
    
    //链接程序
    glLinkProgram(filterProgram);
    
    filterPositionAttribute = glGetAttribLocation(filterProgram, "position");
    filterTextureCoordinateAttribute = glGetAttribLocation(filterProgram, "texcoord");
    filterInputTextureUniform = glGetUniformLocation(filterProgram, "inputImageTexture");
    
    //检查这个程序到底有没有链接成功
    GLint status;
    glGetProgramiv(filterProgram, GL_LINK_STATUS, &status);
    if (status == GL_FALSE) {
        NSLog(@"Failed to link program %d", filterProgram);
        goto exit;
    }
    result = validateProgram(filterProgram);
exit:
    if (vertShader)
        glDeleteShader(vertShader);
    if (fragShader)
        glDeleteShader(fragShader);
    
    if (result) {
        NSLog(@"OK setup GL programm");
    } else {
        glDeleteProgram(filterProgram);
        filterProgram = 0;
    }
    return result;
}

- (void) releaseRender;
{
    if (filterProgram) {
        glDeleteProgram(filterProgram);
        filterProgram = 0;
    }
}

- (void) setInputTexture:(GLint) textureId;
{
    _inputTexId = textureId;
}

- (GLint) outputTextureID
{
    return -1;
}

@end
