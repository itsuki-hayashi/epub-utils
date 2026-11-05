# Performance builds and validation

The thread-only XML fork is documented in [XML_CONCURRENCY.md](XML_CONCURRENCY.md).
Use `-MemoryPolicy FrozenParallel` for its promotion comparisons: the candidate's
worst measured peak must stay within four times the frozen matching-workload
median of per-run peaks. `Sequential` and `WorkerScaled` retain their previous
single-worker and pool-scaling safeguards. All promotion timings use release
executables with profiling disabled.

A full eight-pair native Windows comparison established faster end-to-end
conversion and lower peak memory than Windows Perl, with independent output
verification and the aggregate compression-quality gate enforced. The optimized
native PGO candidate also passed eight full alternating pairs against frozen Ada
for Converted, Preserved and Mixed workloads, including both compression floors,
the memory budget and the workload-regression gate. The earlier fourfold speed
target was not reached. Private corpus measurements and outputs
remain outside the repository; do not treat profiling timings or limited
diagnostic runs as acceptance results.

The results above precede concurrency. [CONCURRENCY.md](CONCURRENCY.md) describes
the shared pool, parallel benchmark options, worker-scaled memory policy and
task-local profiling units. Use --jobs 1 to reproduce single-core behavior.

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

### Optional profile-guided optimization

PGO remains optional; ordinary release builds do not consume
training data. The generation and use builds share a separate `rnq` object
configuration so GCC can locate the same object profile paths. Their packaged
executables remain separate. PGO builds force recompilation so native C helper
objects cannot retain generation instrumentation during the use build:

```powershell
./tools/build.ps1 -BuildKind release -CpuTuning native -PgoMode generate -ProfileDirectory C:\bench\pgo-data
bin/release-native-pgo-generate/epub-v2h.exe --input-path C:\bench\tuning-input --output-directory C:\bench\training-sequential --jobs 1 --json > C:\bench\training-sequential.json
bin/release-native-pgo-generate/epub-v2h.exe --input-path C:\bench\tuning-input --output-directory C:\bench\training-parallel --jobs 2 --json > C:\bench\training-parallel.json
./tools/build.ps1 -BuildKind release -CpuTuning native -PgoMode use -ProfileDirectory C:\bench\pgo-data
```

Use a fresh external profile directory. A source/dependency/configuration
fingerprint rejects missing or stale training data; compiler profile warnings
remain errors for owned code. Only owned units and generated binding code receive
PGO flags. Dependencies retain their existing build configuration and sources.
Checks, assertions and static linkage remain enabled. Train on the tuning set,
then verify output identity and performance on the holdout set before promotion.
Gprof and LTO cannot be combined with these scripted PGO builds.
Generation flags apply during compilation and linking, following the
[GCC instrumentation requirements](https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html).

Linux selects the equivalent build with `EPUB_BUILD=release`,
`EPUB_TUNING=native`, `EPUB_PGO=generate` or `use`, and an external
`EPUB_PGO_DIRECTORY`. Its training identities are platform-specific.

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
$frozenAdaPeakBytes = (Get-Content C:\bench\baseline-summary.json -Raw | ConvertFrom-Json).AdaMedianPeakBytes
./tools/benchmark.ps1 -InputPath C:\books -ReferenceReport C:\bench\reference.json `
  -QualityBaselineReport C:\bench\frozen-ada-report.json -MemoryBaselinePeakBytes $frozenAdaPeakBytes `
  -AdaExecutable bin/release-native/epub-v2h.exe -OutputRoot C:\bench\measurements `
  -Workload Converted -Pairs 8 -CompressionGate Aggregate -Label release-native
```

Run `-Workload Preserved` and `-Workload Mixed` separately. For a quick diagnostic,
add `-Limit 12 -Pairs 1`; such a run cannot satisfy acceptance. Preserve reference
files and reports: the validator compares statuses, reasons, changed entries,
source immutability, hashes, lengths, ZIP order, timestamps, attributes, and every
decompressed payload. The default `Aggregate` gate rejects runs whose total
compressed payload size exceeds Perl's zlib level-9 result; individual books
may vary, and the private validation metrics list every growing book and its
compressed-byte delta. `PerBook` remains available
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

Before editing source, freeze the current executable and its verified outputs.
`tools/prepare-performance.ps1` takes the executable, input path, Perl reference
report and external output root. It snapshots the binary and records deterministic
tuning/holdout partitions stratified by status, size, entry count, approximate
compressibility and observed text encoding. It does not convert books or replace
the frozen Ada quality report. Preserve the source revision and build flags too;
a rebuilt control must use the same dependency optimization flags as the release.

`-QualityBaselineReport` selects the frozen Ada output report, restricted to the
measured books. Every candidate is independently checked against both references.
`-RequireIdenticalBaseline` additionally requires exact output archive bytes for
structural changes. Full measurements require an Ada quality reference or control
executable. `-MemoryBaselinePeakBytes` is the measured frozen Ada peak for that
workload, read from its saved benchmark summary.

Ada/control comparisons report a deterministic paired bootstrap 95% confidence
interval. `-ExtendInconclusive -MaximumPairs 32` extends eight initial pairs to
sixteen and then thirty-two when the interval includes no improvement. Promotion
requires an unlimited full run, at least 3% faster conversion, an interval above
one, both compression gates, and peak RAM no greater than twice the control and
below Perl. Run Converted, Preserved and Mixed separately; pass their summaries
to `tools/evaluate-performance.ps1`. It also checks binary/cohort identity and
rejects workload regressions above 2%, except for the approved 20 ms absolute
allowance when the frozen control median is below 250 ms. At 250 ms and above,
the 2% limit applies. Include sequential and single-file summaries with
`-SequentialSummary` and `-SingleFileSummary` to validate those latency cases.
Limited runs never satisfy promotion.
`tools/test-performance.ps1` checks the statistical calculations and script syntax.

`tools/check-corpus.ps1` accepts the same input, reference, executable and
external output-root paths for one full correctness/quality check. It records
no timings or memory measurements and makes no speed claim; it is useful before
starting a long acceptance run. Its default compression gate is `Aggregate`.
It also accepts `-QualityBaselineReport` and `-RequireIdenticalBaseline` for
untimed validation against the frozen Ada outputs.

## Profiling

The profile build writes inclusive phase timers when `EPUB_PROFILE_PATH` names
an external CSV file. It additionally records exclusive time using a nested timer
stack and writes a companion `.counters.csv`. Phases nest; do not sum inclusive
times. Counters cover demand/repeated member decoding, match searches/candidates,
bulk input, native reads/writes/seeks, byte transfers and owned allocation requests.
Owned container counts exclude allocations internal to the runtime and strings,
and include profiler bookkeeping; they are not live or peak heap measurements.
Incomplete timer stacks after a failed book are discarded and reported.
Production JSON is
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
`tools/summarize-performance.ps1 -PhasePath C:\bench\phases.csv` ranks exclusive
costs and computes ideal speedup ceilings. Supply `-ElapsedSeconds` to use total
elapsed time rather than the sum of accounted timers as the denominator.

## Retained implementation changes

- File-backed catalogues share owned source handles. Payloads are loaded on
  demand; initial source CRC checks still inspect every member.
- Output is streamed to an exclusive temporary file. Intended and persisted
  whole-file digests are computed independently, and archive verification checks
  one entry at a time before atomic no-replacement publication.
- The owned lazy matcher uses checked four-byte multiplicative hash keys and
  a 17-bit head table, hoisted two-byte match probes and word comparisons.
  Input refills copy bounded spans rather than invoking callbacks for each byte.
  Changed resources use the full 4096-link search budget;
  unchanged source-backed resources use a 64-link trial before comparing the
  result with their validated original compressed stream. A linear
  two-queue Huffman path falls back to bounded package merge when necessary;
  exhaustive tests require the reference's exact lengths and tie decisions.
- The entropy encoder selects the lowest computed stored/fixed/dynamic/recycled
  representation for bounded token blocks. A 64-bit accumulator emits bounded
  four-byte batches; stored-block costs share the token statistics pass.
  After attempting compression, an
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
  long-code fallback and all truncation checks. Bounded word refills populate the
  bit accumulator; an opportunistic second literal avoids another decode loop.
- Case-sensitive first-occurrence indexes accelerate archive and manifest lookup.
  Ordered vectors and deep-copy ownership remain intact. Scoped read-only queries
  avoid controlled-element copies in attribute lookup and persisted verification.
- Owned CRC uses slicing-by-eight IEEE CRC-32. SHA-256 processes multiple blocks
  per call using GNAT CPU intrinsics
  after runtime feature detection, with GNAT's portable implementation retained
  and independently exercised as a forced fallback.

See [CODEC_ORIGINS.md](CODEC_ORIGINS.md) for source attribution and licenses.
The split token/expansion-array experiment was removed: it preserved archive
bytes but did not improve measured speed or peak memory.
The bounded analysis cache was also removed after paired trials failed to show
a reliable improvement. Larger token blocks met compression requirements but
did not meet the timing gate, so the existing block size remains in use.

## Separate Linux measurements

`tools/benchmark-linux.py` measures the static Linux executable alone. Supply
an external input directory and a Windows Perl reference report whose `Book`
and `Output` paths have been adapted to those Linux-accessible files. Input
aliases may be needed when original Windows filenames exceed ext4's byte limit;
record that preparation outside the checkout. Copying/staging is untimed.

```sh
python3 tools/benchmark-linux.py --executable bin/linux/release-native/epub-v2h \
  --input /tmp/epub-benchmark/input --reference-report /tmp/epub-benchmark/reference.json \
  --quality-baseline-report /tmp/epub-benchmark/frozen-ada.json \
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

## Whole-book concurrency

The default automatic mode uses a fixed Ada worker pool pinned to the available
physical performance cores. Every queued job owns a whole book. A worker takes
its next job immediately after completing the previous book; results are emitted
in completion order. Use `--jobs 1` for the direct serial path. There is no
within-book parallelism. Shared source lifetimes and temporary reservations are
synchronized, while book processing state remains worker-owned.

See [CONCURRENCY.md](CONCURRENCY.md) for the queue, validation, and separately
measured throughput and memory. Previous entry-stage scheduler measurements are
historical; they are not performance claims for this implementation.
