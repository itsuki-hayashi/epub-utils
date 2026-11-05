# Book worker queue

The XML path now uses the maintained context-owned XML/Ada fork and compact SAX
summaries. See [XML_CONCURRENCY.md](XML_CONCURRENCY.md) for the dependency,
ownership, runtime synchronization and scaling evidence.

Each EPUB is one runnable task containing its input path, destination, conversion
options and result identity. All task descriptors are prepared before workers
start. A fixed Ada worker pool takes these tasks from one FIFO queue. A worker
processes its complete book, publishes the verified result, and immediately
takes the next task. Workers drain the queue and exit. There are no groups of
books that must finish together, entry-stage continuations, or nested pools.

`--jobs auto` uses the available physical performance cores. `--jobs N` (also
`--Jobs`) selects a positive count within that limit. `--jobs 1` retains the
direct sequential path. Invalid values, zero and excessive counts are rejected.
For a parallel run, the selected workers are created once at the beginning;
threads are reused until every queued book is processed. One book uses one
worker, including when it is the only input.

```powershell
bin/release-native/epub-v2h.exe --input-path books --jobs auto --json
bin/release-native/epub-v2h.exe --input-path books --jobs 4 --json
```

## Core selection

Windows queries CPU sets and process defaults, respects process/group affinity,
selects the highest exposed efficiency class, and chooses one logical processor
per physical core. Each worker sets group-aware hard affinity and reads it back.
Linux intersects online CPUs with `sched_getaffinity`, deduplicates hardware
siblings, and uses exposed performance-core masks or capacity information.

Unknown core classes are disclosed with `--verbose`. Missing physical topology
falls back to sequential processing. Virtual-machine topology describes the
processors exposed by the guest OS. Core counts are never inferred by halving
the logical processor count.

Every selected worker completes startup and affinity validation before any book
is submitted. Automatic mode falls back to sequential processing if startup
fails; an explicit parallel count fails. No task is converted before this
startup check succeeds.

API references: [Windows CPU sets](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_cpu_set_information),
[process group affinity](https://learn.microsoft.com/en-us/windows/win32/api/processtopologyapi/nf-processtopologyapi-getprocessgroupaffinity),
[Linux topology](https://www.kernel.org/doc/html/latest/admin-guide/cputopology.html).

## Processing and ownership

With N workers, at most N books are processing at once. The queue contains all
remaining book descriptors; it does not preload their ZIP payloads. Only task
metadata and completed report records grow with the number of inputs. Book
catalogues, XML readers, codec state and payload buffers belong to the worker
currently processing that book.

Each task calls the existing complete-book conversion path. It validates every
initial entry, classifies and transforms the book, retains all compression
attempts and the validated-original-stream fallback, writes the archive, checks
flush/close, independently hashes the persisted file, verifies the saved entries,
and publishes atomically without replacement. A failed book reports its error,
cleans its temporary output, and allows the same worker to take another book.

Archive entry order, DEFLATE decisions, encodings, hashes and ZIP metadata remain
unchanged. There is no parallel splitting of an entry or a book. Shared reference
counts, temporary reservations and directory creation remain thread safe.
Compatibility decoding that requires shared Zip-Ada state keeps its narrow lock.
Runtime checks, assertions, static packaging and dependency pins are retained.

## Completion and output

Books publish independently from their workers. The coordinator emits results
and diagnostics as completions arrive. Console lines and JSON/report records
have no input-order guarantee. The original input ordinal remains attached to
each result for identification; it is not used to delay delivery.

Colliding output destinations race through the existing atomic no-replacement
publication operation. One successful publisher wins; existing files are never
overwritten. There is no input-order precedence or collision-group scheduling.

The only final wait is for the queue to drain before returning the process exit
status. A worker never waits for another book to finish before taking its next
available task. Output collection does not control admission of new books.

## Diagnostics and measurements

`EPUB_CONCURRENCY_STATS` writes worker placement, jobs per worker, queue high-water
mark, maximum simultaneous books and worker busy wall time. Submitted/completed
jobs now count books. The legacy `batch_high_water` field is zero. Busy wall time
includes I/O; process CPU seconds divided by elapsed time and worker count is
reported separately as CPU utilization.

Use the benchmark with `-Jobs auto -AffinityMode PhysicalCores`. Comparisons with
the previous scheduler use its frozen executable with `-ControlJobs auto
-ControlAffinityMode PhysicalCores`. Reports are matched by book identity rather
than array position. Exact archive bytes and both aggregate compression floors
remain required. Private inputs, outputs and profiles stay outside the checkout.

The approved latency policy allows at most 20 ms added median time when the
frozen control median is below 250 ms. At 250 ms and above, the 2% limit applies.
The absolute allowance does not add another 2%. `evaluate-performance.ps1`
applies this rule; include sequential and single-file summaries when evaluating
those cases. The pinned GNAT tasking runtime has a fixed shutdown wait, which
has not been bypassed or patched.

PGO remains optional. Generate with `-fprofile-update=atomic`, train on a
representative reserved set, and rebuild with the matching source/configuration
identity. Earlier entry-stage scheduler measurements are historical and do not
describe this book-queue implementation. LTO remains disabled by default.

## Validation

The Windows unit suite includes a deterministic two-worker, three-book test.
The first book is blocked at its source open; the second completes and reports;
the same worker then opens the third queued book and releases the first. This
checks worker reuse, continuous queue consumption and completion-order reporting.
The Windows suite has 141 cases; Linux has 91. Public CLI checks cover 21 books,
159 saved entries, encodings, jobs 1/2/auto byte identity, failure isolation,
recursive paths and atomic publication races. Applicable proofs and the existing
coverage thresholds remain part of validation. Coverage gaps are reported without
weakening their gates.

On 2026-11-05, eight alternating native-release pairs on the reserved 71-book
Mixed holdout compared this queue with the frozen previous entry-stage scheduler.
Both used 16 physical-core workers. Median elapsed time fell from 2.198 s to
1.940 s (11.7% less time, 1.133x throughput; paired 95% speedup interval
1.108–1.191). Median peak working set fell from 145,592,320 to 122,128,384 bytes;
the candidate's highest observed peak was 127,647,744 bytes. These measurements
compare two parallel Ada schedulers, not Ada with Perl or serial execution.
An untimed accounting run submitted and completed 71 book jobs with 16 workers,
16 simultaneous books and zero batches. Each worker processed 3–7 books.

Independent full-corpus validation covered 337 books: 322 Converted, 15 Preserved,
no errors, and exact archive identity with frozen Ada for every book. Compressed
payload totaled 3,053,535,091 bytes, equal to frozen Ada and below Perl level 9's
3,054,746,896 bytes. The existing 51 individual books larger than Perl are listed
in the private validation report; none grew against frozen Ada.

The earlier queue-only native Windows import audit and static Linux ELF audit passed. Windows had
135 passing AUnit cases, Linux 86, with 19 additional Linux native filesystem
identity cases and 67 discharged proof checks. Application coverage is 93.73%
statements and 75.67% decisions: required core coverage passes, while the existing
95%/90% application thresholds remain unmet. Private measurements, frozen binaries,
source inventory and logs are retained outside the repository.

## One versus sixteen workers

On 2026-11-05, the same frozen native executable was compared with `--jobs 1`
and `--jobs 16` in eight alternating pairs on the reserved 71-book Mixed holdout
(68 Converted, 3 Preserved). The host is a Ryzen 9 7950X3D with 16 physical cores
and 32 logical processors. The serial run was pinned to one selected logical
processor; the parallel workers used one logical processor per physical core.
Every measured output passed independent verification and exact frozen-Ada
archive identity. Inputs were warmed, outputs were fresh, and publication,
flush/close, hashing and entry verification were included.

| Metric | One worker | Sixteen workers |
| --- | ---: | ---: |
| Median elapsed seconds | 18.816 | 1.942 |
| Speedup | 1.00x | 9.69x |
| Median process CPU seconds | 17.969 | 24.758 |
| Median peak working set, MiB | 24.3 | 114.8 |

The paired 95% speedup interval is 9.608–9.879. Parallel efficiency is 60.5%.
Average CPU use is 12.75 of the 16 selected cores, while worker occupancy is
87.1% of available worker wall time. Occupancy includes I/O and lock waits.
Total CPU cost increases 37.8% for the same work.

Accounting from the uninstrumented release measurements gives an ideal elapsed
time of 1.176 s and an observed gap of 0.766 s. Approximately 0.424 s of that gap
comes from increased aggregate CPU cost, 0.092 s from additional non-CPU time
inside active jobs, and 0.250 s from time outside active jobs. The last category
contains approximately 0.210 s of pool idle time, primarily the final book tail,
and 0.039 s outside the pool. These are accounting estimates from median timings
and worker busy totals, not independently timed exclusive phases.

### Identified scaling bottleneck

Book-local XML data still uses shared compiler-managed finalization collections
for `Epub.XML.Node_Lists.Element_Access` and
`Epub.XML.Attribute_Lists.Element_Access`. Every controlled element allocation
and deallocation touches its access type's collection lock. Independent books
therefore contend on the same two collection locks. Repeated deep copies in
`Epub.Lists.Element`, `Adjust` and `Replace_Element` amplify this traffic.
`Epub.XML.Characters`, for example, copies a node and its attributes before
replacing it on every character callback.

Isolated diagnostic builds timed the original GNAT lock functions without
removing synchronization, changing dependency sources, or changing production
code. Symbol mapping identified 3,726,676 node-collection acquisitions and
4,007,008 attribute-collection acquisitions on this workload. Their combined
acquisition time was 0.158 summed task-seconds with one worker and 5.77–6.24
with sixteen workers in two diagnostic runs. Probe stacks balanced without
errors, and independently checked diagnostic outputs matched frozen Ada exactly.
These numbers include instrumentation overhead and overlapping task time; they
are evidence of contention, not release elapsed seconds or an exact attribution
of the entire release regression.

Separate phase diagnostics support the same finding: exclusive XML parsing plus
analysis increased from 2.188 to 7.587 summed task-seconds. Match finding grew
from 7.972 to 8.573 and decompression from 4.942 to 5.133. Match finding remains
the largest compute phase, but XML/container bookkeeping scales much worse.
Allocator diagnostics counted roughly 15.7 million allocation/reallocation calls
and 15.7 million frees; direct allocator/free time increased from 1.00 to 2.15
summed task-seconds. This excludes compiler finalization-collection locking.

The release diagnostic's busy-weighted Windows processor-performance counter
changed from 121.3 to 118.5, approximately 2.3% lower. The mean system disk queue
was 0.18 during the parallel run. These samples do not support a large clock
drop or a saturated disk as the primary explanation. Hardware memory-bandwidth
saturation was not measured.

The next owned-code targets are scoped node reads during analysis and in-place
character accumulation that avoids cloning node attributes. Keep existing deep
value-copy behavior for callers requiring ownership. After reducing that shared
bookkeeping, consider enqueueing estimated expensive books first to shorten the
final whole-book tail. Retain the fixed worker pool, runtime checks, exact output
identity and full persisted verification. Raw profiles, diagnostic sources,
scripts and reports remain outside the checkout; performance claims above use
the unchanged release executable only.
