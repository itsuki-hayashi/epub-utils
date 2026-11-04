# Owned codec implementation

The application maintains its DEFLATE encoder in this repository. It does not
patch Alire caches, modify the reference checkouts, or link zlib/zlib-ng.

The starting point for the attributed adaptations is the MIT-licensed Zip-Ada
62.0.0 release already pinned by the application. The reviewed newer Zip-Ada
checkout was commit `006a12be94d4aefcc48dc2c261282b2c882b51e8`. The zlib-ng
checkout reviewed for matching and checksum techniques was commit
`0e21d97fa77816f7de8d156e8cfb4e41364877cb`; no zlib-ng C source is compiled.

| Owned units | Origin and changes |
| --- | --- |
| `Epub.Compression.Deflate` | Adapted `Zip.Compress.Deflate`; owned Huffman and level-9 matching, compact token records and bounded whole-token-block scheduling. Removed inspection scans, research tracing, unused strategy/progress/encryption paths and duplicate dictionary reconstruction. Match prefixes come directly from the matcher. |
| `Epub.Compression` | Minimal stream/buffer orchestration adapted from `Zip.Compress`; known-size compression and stored fallback only, without unrelated encoders or encryption dispatch. |
| `Epub.LZ77` | Production uses an owned, bounded rewrite of `LZ77_using_IZ`, based on Jean-Loup Gailly's Info-ZIP lazy matching. Search limits match level 9; checked word comparisons accelerate candidate matching. The Rich subset, credited to Rich Geldreich Jr. and its Ada maintainer, remains for test baseline comparisons and is not selected by the production instantiation. |
| `Epub.Huffman.Encoding` | Canonical-code construction adapted from `Huffman.Encoding`. |
| `Epub.Huffman.Length_Limited_Coding` | Boundary package-merge adaptation; a bounded monotonic arena with compact indices replaces pool scans and garbage collection. An owned linear-time two-queue fast path handles ordinary trees already satisfying the bit limit. Differential and exhaustive tests require identical lengths and tie decisions. |
| `Epub.Word_Operations` | Application implementation using checked spans, unaligned word loads and GNAT's trailing-zero intrinsic. No out-of-span loads or zero-input intrinsic calls. |
| `Epub.Checksums` | Application implementation of slicing-by-eight IEEE CRC-32. It does not substitute the different CRC-32C polynomial implemented by SSE4.2's CRC instruction. |
| `Epub.Digests` | Application SHA-256 buffering and padding, with GNAT bindings to the SHA round/message intrinsics. Only feature detection uses inline CPUID assembly. FIPS 180-4 defines the standard constants and hash behavior; no third-party SHA implementation is copied. CPUs without SHA support and forced-software tests use `GNAT.SHA256`. |
| `Epub.Inflate` | Application RFC 1951 stored/DEFLATE decoder, written in Ada. Uses a nine-bit primary Huffman table with canonical long-code fallback, bounded word refills, an opportunistic second-literal path, exact output allocation, geometric dictionary copying and IEEE CRC checks. Reviewed zlib-ng's table/state organization; no C decoder source is copied or linked. |

The production `Info_Zip_9_Knuth` matcher uses checked four-byte keys and the
multiplicative hash technique reviewed in zlib-ng's `insert_string_p.h`. It
uses level-9 lazy-search limits for changed resources. Unchanged source-backed
resources use a 64-link trial and retain their validated original stream when
smaller. Emitted match choices and compressed sizes may differ. It is
implemented in Ada, without compiling C source.
Compression acceptance compares aggregate payload size against the Perl
zlib level-9 reference and reports individual book variation.

The expanded Huffman arena deliberately trades bounded per-call workspace for
less CPU work. Overall memory acceptance must be measured at process level;
this change alone does not establish lower RAM use than Perl.

Retained Zip-Ada reader and ZIP-header interfaces continue to use their original
projects and sources. Codec tests instantiate the unmodified reference generic
in a separate test-only dependency project; owned algorithms and test logic
compile with the application's strict warning policy.

SHA instructions are confined to a function carrying the GCC `sha,sse2` target
attribute; portable builds do not require SHA globally. Runtime dispatch checks
CPUID before entering that function. Native-tuned builds retain their documented
machine-specific instruction requirements. Known-answer and differential tests
cover padding boundaries, fragmented updates, non-consuming digest calls,
unaligned input views, and the forced GNAT fallback.

## Original license for adapted portions

Copyright (c) Gautier de Montmollin, 2009–2024, with the component-specific
copyright ranges, algorithm authors, and credits retained in the source files.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
