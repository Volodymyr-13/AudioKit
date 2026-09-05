// SPDX-FileCopyrightText: 2011 Stephen F. Booth <contact@sbooth.dev>
// SPDX-License-Identifier: MIT
// Adapted from SFBAudioEngine's SFBMonkeysAudioDecoder.mm at abb4e351.
// The file I/O, validation, error boundary, and Float32 conversion are new.

#import "CAPEDecoder.h"

#define PLATFORM_APPLE
#include <MAC/All.h>
#include <MAC/IAPEIO.h>
#include <MAC/MACLib.h>
#undef PLATFORM_APPLE

#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <sys/stat.h>
#include <unistd.h>

NSErrorDomain const AKFAPEDecoderErrorDomain = @"AudioKitFormats.APEDecoder";

namespace {

constexpr AVAudioFrameCount scratchFrames = 4096;
constexpr size_t maximumFrameBytes = 2 * sizeof(float);

BOOL fail(NSError **error, AKFAPEDecoderError code, NSString *description, int codecStatus = 0,
          int posixStatus = 0) {
    if (error) {
        NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: description} mutableCopy];
        if (codecStatus) info[@"codecStatus"] = @(codecStatus);
        if (posixStatus) {
            info[NSUnderlyingErrorKey] = [NSError errorWithDomain:NSPOSIXErrorDomain code:posixStatus userInfo:nil];
        }
        *error = [NSError errorWithDomain:AKFAPEDecoderErrorDomain code:code userInfo:info];
    }
    return NO;
}

/// No Foundation categories, global registration, whole-file copies, or writes.
class FileInput final : public APE::IAPEIO {
public:
    explicit FileInput(int descriptor, int64_t length) : descriptor_(descriptor), length_(length) {}
    ~FileInput() override { ::close(descriptor_); }

    int Open(const APE::str_utfn *, bool) override { return ERROR_INVALID_INPUT_FILE; }
    int Close() override { return ERROR_SUCCESS; }
    int Read(void *buffer, unsigned int count, unsigned int *readCount) override {
        *readCount = 0;
        while (*readCount < count) {
            const auto result = ::read(descriptor_, static_cast<unsigned char *>(buffer) + *readCount,
                                       count - *readCount);
            if (result < 0) {
                if (errno == EINTR) continue;
                lastError = errno;
                return ERROR_IO_READ;
            }
            if (result == 0) break;
            *readCount += static_cast<unsigned int>(result);
        }
        return ERROR_SUCCESS;
    }
    int Write(const void *, unsigned int, unsigned int *written) override {
        if (written) *written = 0;
        return ERROR_IO_WRITE;
    }
    int Seek(APE::int64 offset, APE::SeekMethod method) override {
        int whence;
        switch (method) {
            case APE::SeekFileBegin: whence = SEEK_SET; break;
            case APE::SeekFileCurrent: whence = SEEK_CUR; break;
            case APE::SeekFileEnd: whence = SEEK_END; break;
            default: return ERROR_IO_READ;
        }
        if (::lseek(descriptor_, offset, whence) < 0) {
            lastError = errno;
            return ERROR_IO_READ;
        }
        return ERROR_SUCCESS;
    }
    int Create(const APE::str_utfn *) override { return ERROR_IO_WRITE; }
    int Delete() override { return ERROR_IO_WRITE; }
    int SetEOF() override { return ERROR_IO_WRITE; }
    unsigned char *GetBuffer(int *) override { return nullptr; }
    APE::int64 GetPosition() override {
        const auto position = ::lseek(descriptor_, 0, SEEK_CUR);
        if (position < 0) lastError = errno;
        return position;
    }
    APE::int64 GetSize() override { return length_; }
    int GetName(APE::str_utfn *name) override {
        if (name) name[0] = 0;
        return ERROR_SUCCESS;
    }

    int lastError = 0;

private:
    int descriptor_;
    int64_t length_;
};

float sampleAsFloat(const unsigned char *bytes, unsigned bits, bool floatingPoint) {
    if (floatingPoint) {
        float value;
        std::memcpy(&value, bytes, sizeof(value));
        return value;
    }
    // MAC's explicit playback processing returns unsigned 8-bit / signed
    // little-endian integer PCM, regardless of the original container flags.
    if (bits == 8) return (static_cast<int>(bytes[0]) - 128) / 128.0f;
    uint32_t raw = 0;
    for (unsigned byte = 0; byte < bits / 8; ++byte) raw |= uint32_t(bytes[byte]) << (byte * 8);
    const int64_t signedValue = int64_t(raw) - ((raw & (uint32_t(1) << (bits - 1))) ? (int64_t(1) << bits) : 0);
    return static_cast<float>(double(signedValue) / double(int64_t(1) << (bits - 1)));
}

} // namespace

@implementation AKFAPEDecoder {
    std::unique_ptr<FileInput> _input;
    std::unique_ptr<APE::IAPEDecompress> _decoder;
    std::array<unsigned char, scratchFrames * maximumFrameBytes> _scratch;
    AVAudioFormat *_format;
    AVAudioFramePosition _frameLength;
    AVAudioFramePosition _framePosition;
    unsigned _bits;
    unsigned _channels;
    unsigned _frameBytes;
    bool _floatingPoint;
    bool _failed;
}

@synthesize format = _format;
@synthesize frameLength = _frameLength;
@synthesize framePosition = _framePosition;

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    if (!url.isFileURL) {
        fail(error, AKFAPEDecoderErrorInvalidURL, @"APE decoding requires a local file URL.");
        return nil;
    }

    const char *path = url.fileSystemRepresentation;
    // O_NONBLOCK keeps a non-regular input such as a FIFO from blocking before
    // fstat rejects it. It does not change reads from regular files.
    int descriptor = path ? ::open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK) : -1;
    if (descriptor < 0) {
        fail(error, AKFAPEDecoderErrorInputOutput, @"The audio file could not be opened.", 0, path ? errno : EINVAL);
        return nil;
    }
    struct stat info {};
    const int statResult = ::fstat(descriptor, &info);
    if (statResult != 0 || !S_ISREG(info.st_mode)) {
        const int status = statResult != 0 ? errno : EINVAL;
        ::close(descriptor);
        fail(error, AKFAPEDecoderErrorInputOutput, @"The audio source must be a readable regular file.", 0, status);
        return nil;
    }

    try {
        // Transfer the descriptor only after allocation succeeds.
        _input = std::make_unique<FileInput>(descriptor, info.st_size);
        descriptor = -1;
        int status = ERROR_SUCCESS;
        _decoder.reset(CreateIAPEDecompressEx(_input.get(), &status));
        if (!_decoder || status != ERROR_SUCCESS) {
            fail(error, AKFAPEDecoderErrorInvalidFormat, @"The file is not a valid supported APE stream.", status,
                 _input->lastError);
            return nil;
        }
        const auto bits = _decoder->GetInfo(APE::IAPEDecompress::APE_INFO_BITS_PER_SAMPLE);
        const auto channels = _decoder->GetInfo(APE::IAPEDecompress::APE_INFO_CHANNELS);
        const auto rate = _decoder->GetInfo(APE::IAPEDecompress::APE_INFO_SAMPLE_RATE);
        const auto length = _decoder->GetInfo(APE::IAPEDecompress::APE_DECOMPRESS_TOTAL_BLOCKS);
        const auto frameBytes = _decoder->GetInfo(APE::IAPEDecompress::APE_INFO_BLOCK_ALIGN);
        const auto flags = _decoder->GetInfo(APE::IAPEDecompress::APE_INFO_FORMAT_FLAGS);
        _floatingPoint = (flags & APE_FORMAT_FLAG_FLOATING_POINT) != 0;
        if ((channels != 1 && channels != 2) || (bits != 8 && bits != 16 && bits != 24 && bits != 32) ||
            (_floatingPoint && bits != 32)) {
            fail(error, AKFAPEDecoderErrorUnsupportedFormat, @"APE decoding currently supports mono/stereo 8–32-bit PCM.");
            return nil;
        }
        if (rate <= 0 || rate > 768000 || length < 0 || frameBytes != channels * (bits / 8)) {
            fail(error, AKFAPEDecoderErrorInvalidFormat, @"The APE stream has invalid audio parameters.");
            return nil;
        }
        _bits = static_cast<unsigned>(bits);
        _channels = static_cast<unsigned>(channels);
        _frameBytes = static_cast<unsigned>(frameBytes);
        _frameLength = length;
        _format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:double(rate)
                                                   channels:_channels interleaved:NO];
        if (!_format) {
            fail(error, AKFAPEDecoderErrorUnsupportedFormat, @"The APE audio format could not be represented.");
            return nil;
        }
        status = _decoder->SetNumberOfThreads(1);
        // This API returns the effective thread count, not ERROR_SUCCESS.
        if (status != 1) {
            fail(error, AKFAPEDecoderErrorDecode, @"The APE decoder could not be configured.", status);
            return nil;
        }
        return self;
    } catch (...) {
        if (descriptor >= 0) ::close(descriptor);
        fail(error, AKFAPEDecoderErrorInvalidFormat, @"The APE decoder failed while opening the stream.");
        return nil;
    }
}

- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)error {
    buffer.frameLength = 0;
    if (!_decoder) return fail(error, AKFAPEDecoderErrorClosed, @"The APE source is closed.");
    if (_failed) return fail(error, AKFAPEDecoderErrorDecode, @"The APE source requires a seek or reopen after a decoding failure.");
    if (buffer.frameCapacity == 0 || ![buffer.format isEqual:_format] || !buffer.floatChannelData) {
        return fail(error, AKFAPEDecoderErrorInvalidBuffer, @"The buffer must have positive capacity and match the source format.");
    }
    if (_framePosition == _frameLength) return YES;

    try {
        AVAudioFrameCount written = 0;
        while (written < buffer.frameCapacity && _framePosition < _frameLength) {
            const auto requested = std::min<APE::int64>(std::min(scratchFrames, buffer.frameCapacity - written),
                                                       _frameLength - _framePosition);
            APE::int64 received = 0;
            APE::IAPEDecompress::APE_GET_DATA_PROCESSING processing {true, false, false};
            _input->lastError = 0;
            const int status = _decoder->GetData(_scratch.data(), requested, &received, &processing);
            if (status != ERROR_SUCCESS || received <= 0 || received > requested) {
                _failed = true;
                return fail(error, AKFAPEDecoderErrorDecode, @"The APE stream is truncated or failed checksum validation.",
                            status, _input->lastError);
            }
            for (unsigned channel = 0; channel < _channels; ++channel) {
                float *output = buffer.floatChannelData[channel] + written;
                for (APE::int64 frame = 0; frame < received; ++frame) {
                    output[frame] = sampleAsFloat(_scratch.data() + frame * _frameBytes + channel * (_bits / 8),
                                                 _bits, _floatingPoint);
                }
            }
            written += static_cast<AVAudioFrameCount>(received);
            _framePosition += received;
        }
        buffer.frameLength = written;
        return YES;
    } catch (...) {
        _failed = true;
        return fail(error, AKFAPEDecoderErrorDecode, @"The APE decoder failed while reading the stream.");
    }
}

- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
    if (!_decoder) return fail(error, AKFAPEDecoderErrorClosed, @"The APE source is closed.");
    if (frame < 0 || frame > _frameLength) {
        return fail(error, AKFAPEDecoderErrorInvalidFrame, @"The seek position is outside the APE stream.");
    }
    // MAC clamps a seek to EOF to its last sample. Model EOF explicitly so a
    // later read does not accidentally replay that final sample.
    if (frame == _frameLength) {
        _framePosition = frame;
        _failed = false;
        return YES;
    }
    try {
        _input->lastError = 0;
        const int status = _decoder->Seek(frame);
        if (status != ERROR_SUCCESS) {
            _failed = true;
            return fail(error, AKFAPEDecoderErrorSeek, @"The APE stream could not seek to the requested frame.", status,
                        _input->lastError);
        }
        _framePosition = frame;
        _failed = false;
        return YES;
    } catch (...) {
        _failed = true;
        return fail(error, AKFAPEDecoderErrorSeek, @"The APE decoder failed while seeking.");
    }
}

- (void)close {
    // The decoder refers to the I/O adapter, so destroy it first.
    _decoder.reset();
    _input.reset();
}

- (void)dealloc { [self close]; }

@end
