# Performance builds and validation

A full eight-pair native Windows comparison established faster end-to-end
conversion and lower peak memory than Windows Perl, with independent output
verification and the aggregate compression-quality gate enforced. The earlier
fourfold speed target was not reached. Private corpus measurements and outputs
remain outside the repository; do not treat profiling timings or limited
diagnostic runs as acceptance results.

## Build configurations

```powershell
./tools/build.ps1                                  # development, portable CPU
./tools/build.ps1 -BuildKind release -CpuTuning portable
./tools/build.ps1 -BuildKind release -CpuTuning native
./tools/build.ps1 -BuildKind profile -CpuTuning native -Gprof
./tools/build.ps1 -BuildKind release -CpuTuning native -SectionGC # experimental size variant
```

Native release output is `bin/release-native/epub-v2h.exe`. Release packaging
saves `.debug` symbols before stripping the executable. Profile executables
retain symbols. Packaging retains the unstripped linker output under
`obj/linked/<configuration>` (`obj/linux/linked/<configuration>` on Linux), so
repeated packaging does not modify GPRbuild's tracked executable.
`--subdirs` isolates application and dependency objects by
configuration. All variants retain runtime checks, assertions, strict owned-code
warnings, static application/runtime linking, and the upstream dependency warning
policy. Release optimization uses `-O3 -gnatn`; native builds also use
`-march=native -mtune=native` and are machine-specific. Stripping is packaging,
not a claimed execution-speed improvement. LTO is experimental and disabled by
default; the current dependency link does not pass its LTO build.
The optional `-SectionGC` variant compiles source-built units with function/data
sections and links with `--gc-sections`, using a separate object configuration
and public `-sections` artifact directory.
It must pass correctness, import, and timing checks before replacing a release.
Linux selects the same experiment with `EPUB_SECTIONS=true`. Internal isolated
object directories use short codes such as `rn`, `png`, and `rns`, avoiding MinGW archive-tool
path limits; public artifact directories retain their descriptive names.

Linux uses the same configuration choices:

```sh
EPUB_BUILD=release EPUB_TUNING=portable ./tools/build.sh
EPUB_BUILD=release EPUB_TUNING=native ./tools/build.sh
EPUB_BUILD=profile EPUB_TUNING=native EPUB_GPROF=true ./tools/build.sh
```

The native Linux release is `bin/linux/release-native/epub-v2h`.

## Reproduce Windows comparisons

Keep inputs, reference reports, profiles, and all output books outside the
repository. Use a flat input directory with unique basenames. Generate a Perl
reference report and preserve its output books for independent comparison:

```powershell
# From convert-vertical-to-horizontal-perl; create C:\bench first.
perl -Ilib -Ilocal/lib/perl5 bin/epub-v2h --input-path C:\books `
  --output-directory C:\bench\reference-books --json > C:\bench\reference.json

# From convert-vertical-to-horizontal-ada.
./tools/build.ps1 -BuildKind release -CpuTuning native
./tools/benchmark.ps1 -InputPath C:\books -ReferenceReport C:\bench\reference.json `
  -AdaExecutable bin/release-native/epub-v2h.exe -OutputRoot C:\bench\measurements `
  -Workload Converted -Pairs 8 -CompressionGate Aggregate -Label release-native
```

Run `-Workload Preserved` and `-Workload Mixed` separately. For a quick diagnostic,
add `-Limit 12 -Pairs 1`; such a run cannot satisfy acceptance. Preserve reference
files and reports: the validator compares statuses, reasons, changed entries,
source immutability, hashes, lengths, ZIP order, timestamps, attributes, and every
decompressed payload. The default `Aggregate` gate rejects runs whose total
compressed payload size exceeds Perl's zlib level-9 result; individual books
may vary, and the validator reports their count. `PerBook` remains available
as an optional stricter diagnostic. Failed validation excludes a
measurement from any speedup claim.

The harness performs one warm-up per implementation and alternating paired runs
with inherited single-core affinity, fresh output destinations, and the same
output volume. It records wall time, CPU time, peak working set, byte counts, and
binary identity. `Speedup` is Perl median elapsed time divided by Ada median
elapsed time. `TargetMet` requires a full eight-pair run, faster conversion,
lower peak RAM, and an enforced compression gate. `FourfoldSpeedup` records the
earlier stretch target separately. Linux results must be reported separately.

To isolate a small implementation change, add `-BaselineAdaExecutable` naming
the frozen control binary. The harness then alternates the two Ada binaries;
a Perl warm-up still supplies the independently verified expected output.
These results are explicitly diagnostic comparisons, never Perl speed
acceptance results. Use `-Pairs 8 -Limit 12` for a small paired comparison.

`tools/check-corpus.ps1` accepts the same input, reference, executable and
external output-root paths for one full correctness/quality check. It records
no timings or memory measurements and makes no speed claim; it is useful before
starting a long acceptance run. Its default compression gate is `Aggregate`.

## Profiling

The profile build writes inclusive phase timers when `EPUB_PROFILE_PATH` names
an external CSV file. Phases nest; do not sum their times. Production JSON is
unchanged, and release timer bodies are empty and inlined. The benchmark harness
sets a separate phase-log path for each run. Gprof builds also write `gmon.out`
in each run directory; Windows gprof builds disable ASLR for sampling accuracy.

```powershell
./tools/summarize-gprof.ps1 -Executable bin/profile-native-gprof/epub-v2h.exe `
  -Gmon C:\bench\profile-run\gmon.out -Addr2Line C:\toolchain\bin\addr2line.exe
```

The summarizer understands MinGW's BSD-format 64-bit histogram and resolves
inlined stacks through DWARF. It reports profiler overhead separately; its
samples cover the executable image, not time spent in external system DLLs.
Use uninstrumented release builds for acceptance timing. Windows filesystem
tracing with WPR was unavailable under the current host profiling policy.

## Retained implementation changes

- File-backed catalogues share owned source handles. Payloads are loaded on
  demand; initial source CRC checks still inspect every member.
- Output is streamed to an exclusive temporary file. Intended and persisted
  whole-file digests are computed independently, and archive verification checks
  one entry at a time before atomic no-replacement publication.
- The owned lazy matcher uses checked four-byte multiplicative hash keys and
  word comparisons. Changed resources use the full 4096-link search budget;
  unchanged source-backed resources use a 64-link trial before comparing the
  result with their validated original compressed stream. A linear
  two-queue Huffman path falls back to bounded package merge when necessary;
  exhaustive tests require the reference's exact lengths and tie decisions.
- The entropy encoder selects the lowest computed stored/fixed/dynamic/recycled
  representation for bounded token blocks. After attempting compression, an
  unchanged source-backed entry can retain its smaller original DEFLATE stream.
  Changed entries cannot use this fallback. Both paths receive the same complete
  persisted verification.
- Stored and DEFLATE decoding use an owned buffered reader, Huffman lookup table,
  geometric match copying and exact output-size/CRC checks. Refills cannot read
  following archive entries. Other methods retain Zip-Ada's compatibility decoder.
- Read-only string views and byte views avoid staging copies. Match prefixes
  come directly from the match finder, eliminating a duplicate reconstructed
  text window in the entropy encoder.
- The Huffman decoder inlines its short-code lookup while keeping the canonical
  long-code fallback and all truncation checks.
- Owned CRC uses slicing-by-eight IEEE CRC-32. SHA-256 processes multiple blocks
  per call using GNAT CPU intrinsics
  after runtime feature detection, with GNAT's portable implementation retained
  and independently exercised as a forced fallback.

See [CODEC_ORIGINS.md](CODEC_ORIGINS.md) for source attribution and licenses.
The split token/expansion-array experiment was removed: it preserved archive
bytes but did not improve measured speed or peak memory.

## Separate Linux measurements

`tools/benchmark-linux.py` measures the static Linux executable alone. Supply
an external input directory and a Windows Perl reference report whose `Book`
and `Output` paths have been adapted to those Linux-accessible files. Input
aliases may be needed when original Windows filenames exceed ext4's byte limit;
record that preparation outside the checkout. Copying/staging is untimed.

```sh
python3 tools/benchmark-linux.py --executable bin/linux/release-native/epub-v2h \
  --input /tmp/epub-benchmark/input --reference-report /tmp/epub-benchmark/reference.json \
  --work-root /tmp/epub-benchmark/results --runs 8
```

Repeat with a work root on `/mnt/c` to measure that storage separately. The
script performs one warm-up, selects one available CPU, and creates fresh
outputs for each run. Elapsed time includes the GNU time/taskset wrappers;
CPU and maximum resident set come from GNU time. Every run is independently
checked with Python's ZIP reader against Windows Perl payloads, entry order,
timestamps, attributes, reports, source/output hashes and aggregate compressed
size. These results make no cross-platform Perl speedup claim. Linux peak RSS
and Windows peak working set are different operating-system metrics.
