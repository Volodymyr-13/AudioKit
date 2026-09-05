// SPDX-License-Identifier: MIT

#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const AKFAPEDecoderErrorDomain;

typedef NS_ERROR_ENUM(AKFAPEDecoderErrorDomain, AKFAPEDecoderError) {
    AKFAPEDecoderErrorInvalidURL = 1,
    AKFAPEDecoderErrorInputOutput,
    AKFAPEDecoderErrorInvalidFormat,
    AKFAPEDecoderErrorUnsupportedFormat,
    AKFAPEDecoderErrorClosed,
    AKFAPEDecoderErrorInvalidBuffer,
    AKFAPEDecoderErrorInvalidFrame,
    AKFAPEDecoderErrorDecode,
    AKFAPEDecoderErrorSeek,
};

/// Internal Objective-C boundary; all operations require one serial owner.
/// Supports local mono/stereo APE files. Samples are Float32, noninterleaved.
@interface AKFAPEDecoder : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;

@property(nonatomic, readonly) AVAudioFormat *format;
@property(nonatomic, readonly) AVAudioFramePosition frameLength;
@property(nonatomic, readonly) AVAudioFramePosition framePosition;

- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)error NS_SWIFT_NAME(read(into:));
- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error NS_SWIFT_NAME(seek(to:));
- (void)close;

@end

NS_ASSUME_NONNULL_END
