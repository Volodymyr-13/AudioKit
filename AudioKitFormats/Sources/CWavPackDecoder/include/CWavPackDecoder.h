// SPDX-License-Identifier: MIT

#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const AKFWavPackDecoderErrorDomain;

typedef NS_ERROR_ENUM(AKFWavPackDecoderErrorDomain, AKFWavPackDecoderError) {
    AKFWavPackDecoderErrorInvalidURL = 1,
    AKFWavPackDecoderErrorInputOutput,
    AKFWavPackDecoderErrorInvalidFormat,
    AKFWavPackDecoderErrorUnsupportedFormat,
    AKFWavPackDecoderErrorClosed,
    AKFWavPackDecoderErrorInvalidBuffer,
    AKFWavPackDecoderErrorInvalidFrame,
    AKFWavPackDecoderErrorDecode,
    AKFWavPackDecoderErrorSeek,
};

/// Internal C/Objective-C boundary; all operations require one serial owner.
/// Decodes only the supplied WV file. Adjacent WVC correction files are not read.
@interface AKFWavPackDecoder : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;

@property(nonatomic, readonly) AVAudioFormat *format;
@property(nonatomic, readonly) AVAudioFramePosition frameLength;
@property(nonatomic, readonly) AVAudioFramePosition framePosition;
@property(nonatomic, readonly) BOOL isLossless;

- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)error NS_SWIFT_NAME(read(into:));
- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error NS_SWIFT_NAME(seek(to:));
- (void)close;

@end

NS_ASSUME_NONNULL_END
