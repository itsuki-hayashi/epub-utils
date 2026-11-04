# Implementation status

The converter is functional but has not passed all release acceptance gates.
This file records current evidence and does not replace the agreed plan.

## Concurrency implementation

One shared Ada task pool now processes independent entries and books, with
physical-core affinity, bounded batches, ordered archive assembly and reports,
and publication as ready for independent destinations. See
[CONCURRENCY.md](CONCURRENCY.md) for ownership, failure handling, tests and
measurement commands. The current coverage is 94.16% statements and 75.80%
decisions; required core coverage passes, and the unchanged 95%/90% application
gate remains unmet.

## Performance implementation

Release and profiling builds now support portable and native CPU tuning, with
separate object directories. Release optimization retains checks, assertions,
static linking, and strict owned-code diagnostics. Dependency sources and their
warning settings are unchanged.

An owned, attributed subset of the Zip-Ada encoder now provides DEFLATE and
stored fallback. It includes a level-9 lazy matcher, checked word comparisons,
a linear-time Huffman fast path with bounded package-merge fallback, compact
token storage, and block-based slicing-by-eight IEEE CRC-32. SHA-256 uses GNAT
SHA intrinsics when supported, with runtime CPU dispatch and a tested GNAT
software fallback. The common stored/DEFLATE decoder is owned Ada code, with
bounded input refills, exact output-size checks, CRC verification and a retained
Zip-Ada compatibility path for uncommon methods. Compressor input uses a
lifetime-bound bulk string view; short match prefixes come directly from the
match finder rather than a reconstructed second dictionary.
See [CODEC_ORIGINS.md](CODEC_ORIGINS.md) for provenance and licensing. Compressor
strategy is flexible, but acceptance requires compression at least as good as
both frozen Ada and the Perl reference's zlib level 9 in aggregate; a speed
improvement cannot waive either gate.

The current shared codec and file-stream tests pass on Windows and Linux:
134 Windows cases and 86 Linux cases. Retained optimizations include a
17-bit multiplicative-hash matcher with bounded bulk input and hoisted probes,
adaptive search for unchanged resources, batched bit output, word-buffered
decoding with an additional short-literal path, indexed resource lookup,
scoped read-only container queries, and bulk SHA instruction processing.
Unused RAM-cache and buffering experiments have been removed; the compression
workspace experiment did not improve wall time enough to retain.
The bounded analysis-cache and larger-token-block experiments were also rejected
by paired timing checks. Optional source-bound PGO generation/use builds preserve
checks, assertions, static linking and unmodified dependencies. See PERFORMANCE.md
for training, holdout validation, dual compression gates and promotion criteria.
Conversion now uses file-backed catalogues with shared handle ownership,
on-demand payload loading, sequential output hashing, and entry-at-a-time
persisted verification. Source CRC validation still covers every entry before
analysis returns. No complete input or output ZIP buffer is retained by the
production conversion path. Preserved books are copied in bounded chunks and
verified by whole-file digest.

The full eight-pair native Windows benchmark establishes faster conversion and
lower peak memory than Windows Perl. Every measured output passed independent
verification and the aggregate compression-quality floor, allowing individual
books to vary while listing every growing book and its byte delta privately.
The optimized native PGO candidate also passed full eight-pair comparisons
against frozen Ada for Converted, Preserved and Mixed workloads, including the
paired confidence interval, memory and workload-regression gates.
The earlier fourfold speed target
was not reached. Private corpus timings and outputs remain outside the
repository. Diagnostics are not acceptance evidence.

`tools/benchmark.ps1` performs warm-up, alternating paired runs, single-core
affinity, and independent payload/metadata verification. Full acceptance uses
eight pairs without an input limit and an explicit compression gate. Profiling
executables are diagnostic only. Raw inputs, outputs and measurement artifacts
must remain outside the repository.

## Earlier functional validation

Linux x86-64 is implemented using separate filesystem and CP932 adapters. It
builds with the same pinned toolchain and strict owned-source diagnostics.
The executable is a static ELF with no interpreter or dynamic dependencies.
The 74 shared unit cases and the 21-fixture CLI suite pass on Ubuntu 26.04;
filesystem acceptance checks pass on both native Linux storage and WSL's
Windows mount. Windows retains its API fault-injection suite and passes all
109 cases. Normal and optional PGO builds pass CLI and static-link checks on
both platforms. See [LINUX.md](LINUX.md) for commands and platform details.

## Implemented and exercised

The Windows CLI uses GNAT 16.1.0, GPRbuild 26.0.1, Ada 2022, XML/Ada 26.0.0
and Zip-Ada 62.0.0. All 21 reference EPUBs match the expected classification,
changed resources, decompressed payloads, entry order, attributes and timestamps.
Nine books convert and twelve remain exact whole-file copies. Independent Perl
verification checks all 159 output entries. The original encoder attempted
Deflate_R with stored fallback; the owned encoder's changes are described above.
`mimetype` remains first and stored.

The implementation includes source-preserving CSS/markup scanners, strict UTF-8
and UTF-16LE/BE handling, Windows CP932 conversion, SAX inspection with entity
declaration rejection, stylesheet graph traversal, classification, non-spine
editing, JSON reports, recursive enumeration and atomic no-replacement output
publication. Relative URI edge cases are checked against the Perl resolver,
including ports, user information, duplicate slashes and dot segments.

There are 109 passing Windows AUnit cases, many containing generated or exhaustive
assertion matrices. Suites cover text, archives, book planning, Windows paths,
publication, reports and native failure injection. Test-only JSON 6.0.0 reads
the shared fixture manifest and production reports. Ownership tests exercise
deep copies, variable-length elements, growth, replacement, deletion and invalid
indices. Native wrappers inject open/read/write/flush/close/move/delete and
enumeration failures; they are absent from the production executable.

Archive inspection now bounds central/local metadata and compressed payloads,
compares local CRC/sizes against the catalogue, rejects overlapping entries,
and confines ZIP64 values to their declared extra field. Signed and unsigned
ZIP32/ZIP64 data descriptors are validated by owned code. An owned child adapter
calls Zip-Ada's lower-level decompressor with an isolated compressed payload
and an exception-safe bounded output stream; uncompressed-size mismatches are
rejected. This requires no third-party source changes. Tests cover malformed
names, truncated headers, descriptor corruption, duplicate ZIP64 extras and
case-distinct member names.

CLI integration covers aliases, dry runs, analysis, errors, collisions, continued
batch processing, Unicode and supplementary filenames, long paths, junction
skipping, per-source output directories and mixed-case `horizontal` exclusion.
The executable also runs with only Windows system directories on PATH.

## Verification entry points

```powershell
./tools/build.ps1
./tools/test.ps1
./tools/test-cli.ps1
./tools/prove.ps1
./tools/coverage.ps1
```

`coverage.ps1` enforces the agreed gates. `-MeasureOnly` records an explicitly
incomplete measurement. The latest Windows measurement, including the shared
owned container project, entry point and owned decompression adapter, is
**95.09% statements and 80.91% decisions**. It meets the statement threshold and
misses the decision threshold; it does not measure the Linux adapter. Classification and
publication have 100% statement, decision and MC/DC coverage; the replacement
primitive has 100% statement and decision coverage. The global coverage gate is
false. See `verification/coverage-latest.json` and the corresponding text report.

GNATprove discharges all 67 current core checks without unchecked assumptions.
The application uses the proved classification, replacement, mode mapping and
publication routines. This is a selected proof boundary; multi-edit ordering
and all remaining required functional contracts are not yet complete.

Application code, owned containers, tests and proof units retain every optional
GNAT warning as an error, backend warnings as errors, assertions and runtime
checks. Per the user's revised policy, third-party dependencies use upstream
settings and their warnings are not release gates. Production and tests use
unmodified dependency sources. All warning-cleanup source patches, forked vendor
copies, generators and experimental strict-dependency projects are removed.
The test-only JSON project has a GNAT 16 build-configuration adjustment, with no
source changes. See `BUILD_POLICY.md` for the exact ownership boundary.

The optimized Windows artifact's PE import audit found only ADVAPI32.dll,
KERNEL32.dll, msvcrt.dll and SHELL32.dll. Linux normal and PGO artifacts are
static ELF executables. Repeat these audits for each packaged artifact.
GNATcoverage-generated support follows tool defaults; normal builds validate
owned source diagnostics before instrumentation.
The obsolete embedded foundation-test CLI mode has been removed; those checks
are covered by the modular test suites rather than shipped in the executable.

## Remaining release gates

Close coverage and behavioral matrix gaps; complete the remaining core proofs;
measure the Perl Devel::Cover baseline; add Windows CI and keep binary audits current.

File-backed conversion uses bounded streams, while active decoded resources and
text transformations still need memory proportional to their size. Application
and report byte counts remain limited to Natural'Last. Larger ZIP64 files,
archive-name decoding and corruption validation require further adversarial
tests before release.
