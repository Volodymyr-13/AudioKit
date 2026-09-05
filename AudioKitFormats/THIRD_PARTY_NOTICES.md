# Third-party notices

## SFBAudioEngine

`Sources/CAPEDecoder/APEDecoder.mm` adapts the `IAPEIO` callback boundary and
Monkey's Audio decoder setup/read/seek approach from Stephen F. Booth's
`Sources/CSFBAudioEngine/Decoders/SFBMonkeysAudioDecoder.mm` at SFBAudioEngine
commit `abb4e351c8dd870137b19723dea975f8804220c1`.

Source: https://github.com/sbooth/SFBAudioEngine

The module uses its own file I/O and Float32 conversion. It does not include
SFBAudioEngine's player, metadata model, TagLib, encoders, or global registry.

MIT License

Copyright (c) 2006-2026 Stephen F. Booth

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Monkey's Audio / CXXMonkeysAudio 12.13.0

Dependency source: https://github.com/sbooth/CXXMonkeysAudio

Pinned source revision: `79cafc4dfccff8b9d3065cbf198f6e171a9409c3`.
The package links the `MAC` product and exposes decoding only. The upstream
product also contains encoder implementation; selecting this product is not a
claim that its source target compiles only decoder code.

Monkey's Audio License Agreement (3 clause BSD)

Copyright 2000-2026 Matthew T. Ashland. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1) Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.
2) Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.
3) Neither the name of the copyright holder nor the names of its contributors
may be used to endorse or promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Test fixtures

No audio recordings or encoded fixtures are included in this package. The
optional integration suite reads the user's separate AudioTest_FilesTypes
corpus. Public sample provenance and hashes are recorded in
`IntegrationTests/FormatCorpus/SAMPLES.md`. The source-code licenses above do
not grant redistribution rights to those recordings or their decoded references.
