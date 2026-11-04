# Concurrent EPUB processing

`--jobs auto` is the default. `--jobs N` (also `--Jobs`) selects a positive
worker count; `--jobs 1` uses the original sequential conversion path. Zero,
invalid values and counts above the eligible core count are errors. Automatic
mode keeps one book sequential below 1 MiB expanded data or two entry batches.

```powershell
bin/release-native/epub-v2h.exe --input-path books --jobs auto --json
bin/release-native/epub-v2h.exe --input-path book.epub --jobs 2 --json
```

## Core selection

Windows queries CPU sets and process defaults, intersects process/group affinity,
selects the highest exposed efficiency class, and chooses one logical processor
per physical core. The compatibility topology path uses processor-core
relationships. Each worker sets group-aware hard affinity and reads it back
before the pool accepts conversion jobs. The current Windows test host exposes
16 eligible cores and one efficiency class.

Linux intersects online processors with `sched_getaffinity`, deduplicates
`thread_siblings_list`, and uses `cpu_core/cpus` or `cpu_capacity` when available.
Workers set and read back their affinity. Core counts are never inferred by
halving logical processor counts. If performance cores are entirely excluded by
process restrictions, selection falls back to one allowed processor. Missing
physical topology also results in sequential execution. Unknown core classes are
disclosed with `--verbose`; topology describes OS-visible processors, including
virtual processors inside a VM, rather than inaccessible host hardware.

Worker creation is deferred until a parallel run is needed. The startup barrier
checks every selected worker before conversion starts. Automatic mode reports a
startup failure and falls back to sequential conversion; an explicit parallel
count fails. No job starts before successful affinity validation.

API references: [Windows CPU sets](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_cpu_set_information),
[process group affinity](https://learn.microsoft.com/en-us/windows/win32/api/processtopologyapi/nf-processtopologyapi-getprocessgroupaffinity),
[Linux topology](https://www.kernel.org/doc/html/latest/admin-guide/cputopology.html).

## Scheduling and ownership

One shared Ada task pool serves entries and books. For N workers, admission is
bounded to N active books and 2N entry batches across the entire run. Completed
compressed batches waiting for the writer retain their admission credit. Batches
contain consecutive entries up to 256 KiB expanded data or 32 entries. A larger
entry occupies one batch. The job queue and completion mailbox each hold at most
4N jobs. Workers never wait for child jobs or create nested pools.

Each book parses metadata in archive order, validates all initial payloads in
parallel, and then performs its existing analysis and patch planning sequentially.
Entry compression runs in parallel; a single writer consumes results in original
entry order, accumulating the output hash and ZIP offsets. After checked flush
and close, an independently opened persisted file is hashed and its entries are
verified in parallel. Only a completely verified book can publish. Preserved
books keep the existing bounded copy and independent persisted hash checks.

Each entry keeps the existing DEFLATE decisions, compression attempts and
validated-original-stream fallback. No individual DEFLATE stream is split.
Whole-file hashing, central-directory emission and publication remain sequential
within each book. Output archives must remain byte-identical to frozen Ada.

Bounded source readers have private cursors over the same opened source. A short
lock covers each seek/read of at most 64 KiB; decoding runs outside that lock.
Reference lifetime uses a separate protected counter, with one operation per
copy or release. The last owner frees the source after leaving that operation.
Mutable codec state,
XML readers/symbol tables, buffers and replies belong to individual jobs.
Uncommon Zip-Ada compatibility decoding uses a separate narrow lock; owned
stored/DEFLATE decoding remains parallel. Catalogues are changed only after their
readers drain. Pool-owned jobs transfer replies to the coordinator after local
controlled objects have finalized.

Failures are selected by stage and original entry ordinal. A failed book stops
admitting work, drains running jobs, closes resources and removes its temporary
output. A cleanup close failure retains the earlier error and adds its own
diagnostic. Other books continue. Temporary names use one protected sequence,
exclusive reservation and collision retry. Concurrent directory creation accepts
only a directory that actually exists after the race.

## Publication and reporting

Independent verified books publish as ready. Destination groups use existing
parent identity plus native filename rules. Case aliases, potential DOS aliases,
unknown filesystem collation and failed identity queries serialize a conservative
scope. Colliding destinations preserve input-order precedence, including when an
earlier book fails. Final publication always uses atomic no-replacement semantics.
External publishers can still win a race; their existing files are never replaced.

Linux checks per-directory casefold flags before treating ext4, Btrfs or tmpfs
names as case-sensitive. Unavailable queries and XFS use conservative grouping:
[tmpfs supports per-directory casefold](https://cdn.kernel.org/doc/html/latest/filesystems/tmpfs.html),
and [XFS still supports its deprecated ASCII-CI format](https://cdn.kernel.org/doc/html/latest/admin-guide/xfs.html).

Only the coordinator emits console output and report records. Results and
warnings remain in input order, so a later book may be published before its report
is printed. The report schema and all existing CLI options are retained.

## Memory, diagnostics and PGO

Memory may scale with active workers. A large entry is not divided or retained
in a global cache. Workers reserve 16 MiB stacks; physical memory use depends on
actual stack use and live batches. Peak process memory is measured, rather than
estimated from stack reservations. `--jobs 1` remains available for constrained
systems.

Set `EPUB_CONCURRENCY_STATS` to an external CSV path to record selected cores,
submitted/completed jobs, queue/batch/book high-water marks, pool elapsed time,
and each worker's job count and busy wall time. Busy wall time includes I/O and
is not CPU utilization. The benchmark reports process CPU seconds divided by
elapsed seconds and worker count separately.

Profiling timer stacks and allocation counters are task-local. Repeated resource
decoding is tracked per book across workers. Phase seconds sum task-local wall
durations and may overlap; they are neither process CPU time nor elapsed time.
Use `summarize-performance.ps1 -Workers N` for parallel profiles. It does not
calculate a serial Amdahl ceiling from parallel work totals. Release profiling
hooks remain empty and inlined. Use `--jobs 1` with gprof.

PGO remains optional. Generation compiles and links with
`-fprofile-update=atomic`, and source/configuration identity must match the use
build. Train on the reserved tuning set with both `--jobs 1` and multiple
workers, using separate output directories, then validate holdout data. Atomic instrumentation can contend heavily at large worker counts;
its speed is not a release performance result. LTO remains optional and disabled.
Runtime checks, assertions, static linking and dependency pins are unchanged.

Parallel-only PGO training was rejected after a measured 2.73% sequential
regression. GCC [optimizes untrained code for size by default](https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html#index-fprofile-partial-training),
so sequential behavior must be included in training and checked independently.
Balanced training alone also missed the conservative median gate (3.37% slower).
After replacing controlled lifetime-lock guards with the narrow protected
counter, a 32-pair sequential comparison measured 0.36% slower, with a
paired 95% speedup interval of 0.980–1.016. It meets the median tolerance and does
not establish a sequential speed change.

## Reproducing acceptance measurements

Freeze executable/source/profile identities before modification and retain private
inputs, outputs, profiles and raw reports outside the checkout. For parallel
Windows measurements use the existing benchmark with these additional options:

```powershell
./tools/benchmark.ps1 -InputPath C:\bench\input -ReferenceReport C:\bench\perl.json `
  -QualityBaselineReport C:\bench\frozen-ada.json -BaselineAdaExecutable C:\bench\frozen-ada.exe `
  -AdaExecutable C:\bench\candidate.exe -OutputRoot C:\bench\results -Workload Converted `
  -Jobs auto -AffinityMode PhysicalCores -MemoryPolicy WorkerScaled `
  -Pairs 8 -ExtendInconclusive -MaximumPairs 32 -RequireIdenticalBaseline -CompressionGate Aggregate
```

Repeat for Preserved and Mixed. Linux Ada-only diagnostic runs accept
`benchmark-linux.py --jobs auto --affinity-mode PhysicalCores`; its default
single-core mode remains available, and it makes no cross-platform speed claim. The candidate inherits the controller's original
allowed affinity before startup; frozen Ada/Perl controls inherit single-core
affinity. `-ControlJobs 1` supports a newer control with the jobs option. Optional
`-ReuseReferenceOutputs` independently verifies existing frozen Perl outputs
instead of reconverting them; it requires an Ada control and worker-scaled memory
policy. The worker-scaled comparison reports a 2N-times-control peak budget and
does not apply the previous below-Perl whole-process ceiling to parallel mode.
Sequential measurements retain the original memory gate.

Use uninstrumented releases for timing. Require eight alternating pairs, at least
3% median improvement with a paired 95% interval excluding no improvement, both
aggregate compression floors, byte identity, and no repeatable regression above
2% in another workload or sequential mode. Extend inconclusive runs to 16 and
32 pairs. Measure single-file latency separately from batch throughput and record
scaling at 1, 2 and the detected maximum.

## Measured Windows workloads

On 2026-11-05, the uninstrumented native PGO release was compared with the exact
frozen Ada PGO executable on the Windows host's 16 eligible physical cores.
Controls used one core; parallel workers used one logical processor per core.
The complete reserved holdout contains 68 converted and three preserved books.
Each workload below uses eight alternating pairs and independent verification.

| Workload | Frozen Ada median | 16-worker median | Speedup (paired 95% interval) | Maximum process working set |
| --- | ---: | ---: | ---: | ---: |
| Converted, 68 books | 17.789 s | 2.113 s | 8.42x (8.18–9.02) | 143.99 MiB |
| Preserved, 3 books | 0.421 s | 0.352 s | 1.20x (1.14–1.24) | 22.96 MiB |
| Mixed, 71 books | 18.134 s | 2.303 s | 7.87x (7.62–8.54) | 139.15 MiB |

All workload timing, compression and worker-scaled memory gates pass. These
comparisons measure batch throughput; single-file latency is checked separately.
Mixed-workload process CPU utilization is 76.9% of the 16-worker capacity.

The many-entry single-book case improves 1.70x (0.201 s to 0.118 s). The
dominant-entry case takes 0.124 s versus 0.114 s and fails the original 2% relative
latency gate. This candidate therefore has not passed overall promotion under
that gate. The pinned GNAT runtime's `Finalize_Global_Tasks` unconditionally
waits 10 ms when tasking is linked; an isolated minimal-program comparison
measured about 20 ms additional wall time on this Windows host, even without
creating a worker. No runtime finalization or dependency source was bypassed.

All 337 output EPUBs are byte-identical to frozen Ada. Their compressed payload
total is 3,053,535,091 bytes, versus Perl level 9's 3,054,746,896 bytes. Both the
266-book tuning set and the 71-book holdout independently meet the Perl floor.
No book grows relative to frozen Ada; 51 books remain larger than Perl, as in the
baseline. Their individual deltas and the raw reports stay outside the checkout.

The separate scaling comparison on the same 71-book cohort measured:

| Workers | Candidate median | Speedup against paired frozen control | Pairs |
| --- | ---: | ---: | ---: |
| 1 | 20.316 s | 0.996x | 32 |
| 2 | 9.218 s | 1.967x | 8 |
| 16 | 2.284 s | 7.842x | 8 |

Each row has its own alternating control runs; the normalized speedups account
for changing host conditions. Maximum observed admission was 16 active books,
32 outstanding batches and 31 queued jobs, within the N/2N/4N bounds.

PGO remains optional and is not promoted over the standard native build. Its
32-pair comparison measured 0.972x native speed (95% interval 0.950–1.012), which
does not establish a benefit. The throughput table above identifies the PGO
variant explicitly and compares it with the exact frozen PGO baseline.

The final diagnostic profile has no abandoned timers. Decompression accounts
for about 38% of summed task-local wall time, match finding 23%, XML parsing 10%
and analysis 9%. Blocking and overlap affect these fractions; they are not CPU
shares or serial speedup ceilings. Per-book analysis, each DEFLATE stream,
whole-file hashes and ordered ZIP assembly remain serial within a book. Further
work should first measure shared-source I/O contention and dominant-entry load
imbalance, keeping stream decisions and archive byte identity intact.

## Validation status

Windows: 134 unit cases, public CLI/independent verification of 21 books and 159
entries, jobs 1/2/auto byte identity, concurrent native filesystem faults, and
67 applicable proof checks pass. Linux: 86 unit cases and the static ELF,
filesystem and public CLI/worker-mode checks pass. The standalone native
destination-identity harness passes 19 casefold, unavailable-query and I/O-error
cases. Native Windows imports contain
only ADVAPI32, KERNEL32, msvcrt and SHELL32. Dependencies were not source-patched.
Linux staging used a source-identical verified Zip-Ada cache after a fresh
SourceForge download failed the pinned checksum; the checksum gate was retained.

Coverage currently measures 94.16% statements and 75.80% decisions; required core
coverage passes. The unchanged 95%/90% application gate remains unmet. The
expanded concurrency error and topology branches increase the coverage denominator.
See the checked-in verification reports for the measured units.
