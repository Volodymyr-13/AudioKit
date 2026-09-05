// SPDX-FileCopyrightText: 2011 Stephen F. Booth <contact@sbooth.dev>
// SPDX-License-Identifier: MIT
// Adapted from SFBAudioEngine's SFBWavPackDecoder.m at abb4e351.
// File ownership, error checks, validation, and planar Float32 conversion are new.

#import "CWavPackDecoder.h"
// WavPack's legacy RIFF helper typedef collides with Carbon's AIFF ChunkHeader
// when both headers are included textually on macOS. It is not part of any
// decoder function signature; keep its spelling private to this translation unit.
#define ChunkHeader AKFWavPackChunkHeader
#include <wavpack/wavpack.h>
#undef ChunkHeader

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

NSErrorDomain const AKFWavPackDecoderErrorDomain = @"AudioKitFormats.WavPackDecoder";

enum { scratchFrameCount = 4096, maximumChannelCount = 2 };

typedef struct {
    int descriptor;
    int64_t length;
    int lastError;
} FileInput;

static BOOL fail(NSError **error, AKFWavPackDecoderError code, NSString *description, int posixStatus) {
    if (error) {
        NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: description} mutableCopy];
        if (posixStatus) {
            info[NSUnderlyingErrorKey] = [NSError errorWithDomain:NSPOSIXErrorDomain code:posixStatus userInfo:nil];
        }
        *error = [NSError errorWithDomain:AKFWavPackDecoderErrorDomain code:code userInfo:info];
    }
    return NO;
}

static int32_t readBytes(void *identifier, void *buffer, int32_t count) {
    FileInput *input = identifier;
    if (count < 0) {
        input->lastError = EINVAL;
        return -1;
    }
    int32_t received = 0;
    while (received < count) {
        ssize_t result = read(input->descriptor, (unsigned char *)buffer + received, (size_t)(count - received));
        if (result < 0) {
            if (errno == EINTR) continue;
            input->lastError = errno;
            return -1;
        }
        if (result == 0) break;
        received += (int32_t)result;
    }
    return received;
}

static int64_t getPosition(void *identifier) {
    FileInput *input = identifier;
    off_t position = lseek(input->descriptor, 0, SEEK_CUR);
    if (position < 0) input->lastError = errno;
    return position;
}

static int seekAbsolute(void *identifier, int64_t position) {
    FileInput *input = identifier;
    if (position < 0) {
        input->lastError = EINVAL;
        return -1;
    }
    if (lseek(input->descriptor, position, SEEK_SET) < 0) {
        input->lastError = errno;
        return -1;
    }
    return 0;
}

static int seekRelative(void *identifier, int64_t offset, int mode) {
    FileInput *input = identifier;
    if (mode != SEEK_SET && mode != SEEK_CUR && mode != SEEK_END) {
        input->lastError = EINVAL;
        return -1;
    }
    if (lseek(input->descriptor, offset, mode) < 0) {
        input->lastError = errno;
        return -1;
    }
    return 0;
}

static int pushBackByte(void *identifier, int byte) {
    return seekRelative(identifier, -1, SEEK_CUR) == 0 ? byte : EOF;
}

static int64_t getLength(void *identifier) { return ((FileInput *)identifier)->length; }
static int canSeek(void *identifier) {
    (void)identifier;
    return 1;
}

@implementation AKFWavPackDecoder {
    FileInput _input;
    WavpackStreamReader64 _reader;
    WavpackContext *_decoder;
    int32_t _scratch[scratchFrameCount * maximumChannelCount];
    AVAudioFormat *_format;
    AVAudioFramePosition _frameLength;
    AVAudioFramePosition _framePosition;
    unsigned _channels;
    BOOL _floatingPoint;
    BOOL _isLossless;
    BOOL _requiresLossless;
    BOOL _failed;
    double _integerScale;
}

@synthesize format = _format;
@synthesize frameLength = _frameLength;
@synthesize framePosition = _framePosition;
@synthesize isLossless = _isLossless;

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _input.descriptor = -1;
    if (!url.isFileURL) {
        fail(error, AKFWavPackDecoderErrorInvalidURL, @"WavPack decoding requires a local file URL.", 0);
        return nil;
    }
    const char *path = url.fileSystemRepresentation;
    // A FIFO must not block open before fstat can reject the non-regular input.
    _input.descriptor = path ? open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK) : -1;
    if (_input.descriptor < 0) {
        fail(error, AKFWavPackDecoderErrorInputOutput, @"The audio file could not be opened.", path ? errno : EINVAL);
        return nil;
    }
    struct stat information;
    int statStatus = fstat(_input.descriptor, &information);
    if (statStatus != 0 || !S_ISREG(information.st_mode)) {
        fail(error, AKFWavPackDecoderErrorInputOutput, @"The audio source must be a readable regular file.",
             statStatus != 0 ? errno : EINVAL);
        return nil;
    }
    _input.length = information.st_size;
    _reader = (WavpackStreamReader64){
        .read_bytes = readBytes,
        .get_pos = getPosition,
        .set_pos_abs = seekAbsolute,
        .set_pos_rel = seekRelative,
        .push_back_byte = pushBackByte,
        .get_length = getLength,
        .can_seek = canSeek,
        // This wrapper owns the descriptor. No write, close, or correction-file callbacks.
    };
    char codecError[80] = {0};
    // OPEN_DSD_NATIVE permits identifying DSD so we can reject it explicitly
    // before decoding. OPEN_ALT_TYPES exposes the source's qualify-mode flags.
    // No OPEN_WVC/OPEN_TAGS/OPEN_NO_CHECKSUM or added worker threads are enabled.
    _decoder = WavpackOpenFileInputEx64(&_reader, &_input, NULL, codecError,
                                      OPEN_NORMALIZE | OPEN_ALT_TYPES | OPEN_DSD_NATIVE, 0);
    if (!_decoder) {
        fail(error, _input.lastError ? AKFWavPackDecoderErrorInputOutput : AKFWavPackDecoderErrorInvalidFormat,
             @"The file is not a valid supported WavPack stream.", _input.lastError);
        return nil;
    }
    if (WavpackGetQualifyMode(_decoder) & QMODE_DSD_AUDIO) {
        fail(error, AKFWavPackDecoderErrorUnsupportedFormat, @"DSD-encoded WavPack is not supported by this PCM source.", 0);
        return nil;
    }

    int mode = WavpackGetMode(_decoder);
    int bits = WavpackGetBitsPerSample(_decoder);
    int bytes = WavpackGetBytesPerSample(_decoder);
    int channels = WavpackGetNumChannels(_decoder);
    uint32_t sampleRate = WavpackGetSampleRate(_decoder);
    int64_t length = WavpackGetNumSamples64(_decoder);
    _floatingPoint = (mode & MODE_FLOAT) != 0;
    _isLossless = (mode & MODE_LOSSLESS) != 0;
    _requiresLossless = _isLossless;
    if (!(mode & MODE_HYBRID) && WavpackLossyBlocks(_decoder)) {
        fail(error, AKFWavPackDecoderErrorInvalidFormat, @"The WavPack stream is missing data required for lossless decoding.", 0);
        return nil;
    }
    if ((channels != 1 && channels != 2) || (bits != 8 && bits != 16 && bits != 24 && bits != 32) ||
        (_floatingPoint && (bits != 32 || bytes != 4)) || length < 0) {
        fail(error, AKFWavPackDecoderErrorUnsupportedFormat,
             @"WavPack decoding currently supports finite mono/stereo 8–32-bit PCM streams.", 0);
        return nil;
    }
    if (sampleRate == 0 || sampleRate > 768000 || bytes < 1 || bytes > 4 || bits > bytes * 8 ||
        WavpackGetSampleIndex64(_decoder) != 0 || WavpackGetNumErrors(_decoder) != 0) {
        fail(error, AKFWavPackDecoderErrorInvalidFormat, @"The WavPack stream has invalid audio parameters or damaged blocks.", 0);
        return nil;
    }
    _channels = (unsigned)channels;
    _frameLength = length;
    // WavPack integers are right-justified in int32, but preserve alignment
    // within the original sample byte width. This also covers hybrid WV output.
    _integerScale = 1.0 / ldexp(1.0, bytes * 8 - 1);
    _format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:sampleRate
                                               channels:_channels interleaved:NO];
    if (!_format) {
        fail(error, AKFWavPackDecoderErrorUnsupportedFormat, @"The WavPack audio format could not be represented.", 0);
        return nil;
    }
    return self;
}

- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)error {
    buffer.frameLength = 0;
    if (!_decoder) return fail(error, AKFWavPackDecoderErrorClosed, @"The WavPack source is closed.", 0);
    if (_failed) return fail(error, AKFWavPackDecoderErrorDecode, @"The WavPack source requires a seek or reopen after a decoding failure.", 0);
    if (buffer.frameCapacity == 0 || ![buffer.format isEqual:_format] || !buffer.floatChannelData) {
        return fail(error, AKFWavPackDecoderErrorInvalidBuffer, @"The buffer must have positive capacity and match the source format.", 0);
    }
    if (_framePosition == _frameLength) return YES;

    AVAudioFrameCount written = 0;
    while (written < buffer.frameCapacity && _framePosition < _frameLength) {
        uint32_t requested = (uint32_t)MIN((AVAudioFramePosition)MIN(scratchFrameCount, buffer.frameCapacity - written),
                                         _frameLength - _framePosition);
        int errorsBefore = WavpackGetNumErrors(_decoder);
        _input.lastError = 0;
        uint32_t received = WavpackUnpackSamples(_decoder, _scratch, requested);
        // Missing WVX precision data can change a later block to lossy without
        // increasing the CRC error counter. In WavPack 5.9, GetMode dynamically
        // clears MODE_LOSSLESS when its sticky lossy_blocks flag is set.
        _isLossless = _isLossless && (WavpackGetMode(_decoder) & MODE_LOSSLESS) != 0;
        if (_requiresLossless && !_isLossless) {
            _failed = YES;
            return fail(error, AKFWavPackDecoderErrorDecode,
                        @"The WavPack stream lost data required for lossless decoding.", 0);
        }
        if (received != requested || WavpackGetNumErrors(_decoder) != errorsBefore || _input.lastError ||
            WavpackGetSampleIndex64(_decoder) != _framePosition + received) {
            _failed = YES;
            return fail(error, AKFWavPackDecoderErrorDecode, @"The WavPack stream is truncated or failed checksum validation.",
                        _input.lastError);
        }
        for (unsigned channel = 0; channel < _channels; ++channel) {
            float *destination = buffer.floatChannelData[channel] + written;
            for (uint32_t frame = 0; frame < received; ++frame) {
                const int32_t *sample = &_scratch[frame * _channels + channel];
                if (_floatingPoint) {
                    // MODE_FLOAT returns float bit patterns in the int32 buffer.
                    memcpy(&destination[frame], sample, sizeof(float));
                } else {
                    destination[frame] = (float)((double)*sample * _integerScale);
                }
            }
        }
        written += received;
        _framePosition += received;
    }
    buffer.frameLength = written;
    return YES;
}

- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
    if (!_decoder) return fail(error, AKFWavPackDecoderErrorClosed, @"The WavPack source is closed.", 0);
    if (frame < 0 || frame > _frameLength) {
        return fail(error, AKFWavPackDecoderErrorInvalidFrame, @"The seek position is outside the WavPack stream.", 0);
    }
    // WavpackSeekSample64 rejects EOF; model that valid PCMSource position here.
    if (frame == _frameLength) {
        _framePosition = frame;
        _failed = NO;
        return YES;
    }
    _input.lastError = 0;
    int errorsBefore = WavpackGetNumErrors(_decoder);
    int didSeek = WavpackSeekSample64(_decoder, frame);
    _isLossless = _isLossless && (WavpackGetMode(_decoder) & MODE_LOSSLESS) != 0;
    if (_requiresLossless && !_isLossless) {
        _failed = YES;
        return fail(error, AKFWavPackDecoderErrorSeek,
                    @"The WavPack stream lost data required for lossless decoding.", 0);
    }
    if (!didSeek || _input.lastError ||
        WavpackGetNumErrors(_decoder) != errorsBefore || WavpackGetSampleIndex64(_decoder) != frame) {
        _failed = YES;
        return fail(error, AKFWavPackDecoderErrorSeek, @"The WavPack stream could not seek to the requested frame.",
                    _input.lastError);
    }
    _framePosition = frame;
    _failed = NO;
    return YES;
}

- (void)close {
    if (_decoder) _decoder = WavpackCloseFile(_decoder);
    if (_input.descriptor >= 0) {
        close(_input.descriptor);
        _input.descriptor = -1;
    }
}

- (void)dealloc { [self close]; }

@end
