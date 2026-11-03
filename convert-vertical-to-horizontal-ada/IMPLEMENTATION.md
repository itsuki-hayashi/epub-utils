# Implementation status

The converter is functional but has not passed all release acceptance gates.
This file records current evidence and does not replace the agreed plan.

Linux x86-64 is implemented using separate filesystem and CP932 adapters. It
builds with the same pinned toolchain and strict owned-source diagnostics.
The executable is a static ELF with no interpreter or dynamic dependencies.
The 47 shared unit cases and the 21-fixture CLI suite pass on Ubuntu 26.04;
filesystem acceptance checks pass on both native Linux storage and WSL's
Windows mount. Windows retains its API fault-injection suite and passes all
73 cases. See [LINUX.md](LINUX.md) for commands and platform details.

## Implemented and exercised

The Windows CLI uses GNAT 16.1.0, GPRbuild 26.0.1, Ada 2022, XML/Ada 26.0.0
and Zip-Ada 62.0.0. All 21 reference EPUBs match the expected classification,
changed resources, decompressed payloads, entry order, attributes and timestamps.
Nine books convert and twelve remain exact whole-file copies. Independent Perl
verification checks all 159 output entries. Converted resources attempt Deflate_R
with Zip-Ada's native stored fallback; `mimetype` is first and stored.

The implementation includes source-preserving CSS/markup scanners, strict UTF-8
and UTF-16LE/BE handling, Windows CP932 conversion, SAX inspection with entity
declaration rejection, stylesheet graph traversal, classification, non-spine
editing, JSON reports, recursive enumeration and atomic no-replacement output
publication. Relative URI edge cases are checked against the Perl resolver,
including ports, user information, duplicate slashes and dot segments.

There are 73 passing Windows AUnit cases, many containing generated or exhaustive
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
incomplete measurement. The last recorded Windows coverage before the platform
split, including the shared owned container project, entry point and owned
decompression adapter, was **95.02% statements and
79.26% decisions**. That measurement met the statement threshold and missed the
decision threshold; it does not measure the new Linux adapter. Classification and
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

The last PE import audit found only ADVAPI32.dll, KERNEL32.dll, msvcrt.dll and
SHELL32.dll. A final reproducible import audit remains a release gate.
GNATcoverage-generated support follows tool defaults; normal builds validate
owned source diagnostics before instrumentation.
The obsolete embedded foundation-test CLI mode has been removed; those checks
are covered by the modular test suites rather than shipped in the executable.

## Remaining release gates

Close coverage and behavioral matrix gaps; complete the remaining core proofs;
measure the Perl Devel::Cover baseline; add Windows CI and final binary audits.

Archive processing currently holds complete books and payloads in memory. The
Windows reader rejects files larger than Natural'Last bytes. True large streamed
ZIP64 handling remains a limitation to resolve and verify. Archive-name decoding
and corruption validation also require further adversarial tests before release.
