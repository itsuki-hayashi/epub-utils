# Independent XML contexts in one process

Production uses `xmlada_epub=26.0.0-epub.1`, relative-pinned in the application,
tests and coverage manifests. GNAT 16.1.0, GPRbuild 26.0.1, Zip-Ada 62.0.0,
AUnit 26.0.0 and JSON 6.0.0 remain unchanged. The upstream XML/Ada 26.0.0 archive
checksum, original file inventory and reviewed patch identity are in
[the fork provenance](vendor/xmlada_epub/EPUB_FORK.md). The source identity is
`65cb5f52604c8432f83ada2cea5ce066a6bcda20c0d55b125130ddb1848e8480`.
Git preserves the dependency's exact source bytes across platforms with an
explicit `-text` attribute; checkout newline conversion cannot invalidate the
recorded upstream/fork hashes.

The existing fixed whole-book pool is unchanged: each worker completes one book
and takes the next queued book immediately. Completion reports are unordered.
There are no helper processes, IPC, XML pools, batches or new parser libraries.

## Ownership and storage

`Sax.Contexts.Parse_Context` is a limited stack owner of an adopted SAX reader,
its symbol table, parser buffers, DTD/entity state, attributes and namespace
stacks. Every context and table records its creating Ada task. Context operations
reject wrong-task and reentrant use before accessing mutable state. Checked
task-local identities and generations reject foreign/stale borrowed symbols,
including when allocator addresses are reused. These checks do not depend on
assertion policy. Reset allocates its replacement table before invalidating
the old state, so allocation failure leaves the original context usable.

Interned UTF-8 strings and hash entries are plain owned storage, freed with their
document-scoped table. Borrowed symbol/table handles have no controlled fields,
reference counts, locks or atomic updates. Reader extension cleanup releases its
plain frame array. Parser cleanup and string-input close are idempotent. There
is no persistent XML cache. Immutable Unicode tables are shared; mutable context
and table identity counters use thread-local storage.

`Inspect_Container`, `Inspect_Package` and `Inspect_Content` return limited summary
owners containing only byte arrays, plain facts, spans, text-fragment links and
flags. No XML node or attribute containing a controlled string is allocated.
Class/id token iteration creates no temporary controlled list. Source patching
also stores attributes as plain offsets into the original source, under a stack
owner. Values needed by `Book_Plan` are copied into its existing owned results.
Parser handles and summaries never enter coordinator completion records.

Elements match local names, attributes match qualified names, metadata uses
direct text, and fragmented character callbacks concatenate correctly. Body and
root-SVG ancestry/exclusions determine visible text. Parsing completes before
fixed-layout and manifest checks. Original source bytes still supply every
patch; summaries are never serialized. Entity restrictions and external-resource
rejection are unchanged.

## Dependency and synchronization audits

Only `xmlada_epub_sax`, `xmlada_epub_input` and `xmlada_epub_unicode` are exported.
DOM/schema remain upstream reference material outside the production closure and
have no concurrency guarantee. The original parser is a separately linked test
oracle under `tests/xml_oracle`, with a separate Alire workspace and original
XML/Ada pin. It cannot enter a production build through those projects.

Both build scripts verify the complete maintained fork inventory before building
and inspect the link map afterwards. The audit rejects original XML/Ada imports,
original-cache objects, `Sax.Pointers` and the old XML node/attribute collections.
`audit-xml-fork.py --sources-list LIST --link-map MAP` additionally checks resolved
XML source paths. Objects/libraries are isolated by platform, build and role;
GPR subdirectories isolate tuning, profiling and PGO. Linux validation uses a
separate native source stage because Alire-generated state is host-specific.

PGO fingerprints include fork sources, project files, manifests and patch
identity. `tools/test-pgo-identity.py` verifies invalidation after changes to each
of these, while generated objects cannot change identity. No PGO training data
was reused for this structural change. Bounds checks, assertions, static
packaging and the strict owned-source/dependency warning boundary remain intact.

Runtime diagnostics count actual finalization-collection attachments by their
linked collection addresses and direct task-lock calls, and measure allocator
work separately. Wrappers always execute the original runtime functions; they
do not replace locks, soft links or finalizers. Instrumented binaries are never
used for promotion timing. Queue/runtime/OS allocator synchronization remains
outside the XML parser and summary path.

The Windows process audit observes zero application helper children. Both frozen
and candidate GNAT executables cause Windows to provide one `System32/conhost.exe`
console host; that existing OS console behavior is retained. It is not an XML or
book worker. The runtime observation uses process snapshots with image/creation
time checks, combined with static source/closure inspection; snapshots alone
cannot exclude a process shorter than their measured polling gaps. Linux and
Windows use the same thread-only conversion design.

## Compatibility evidence

The final native candidate is independently verified against all 337 private
books: 322 converted, 15 preserved, zero errors, and 337 byte-identical archives
against frozen Ada. Compressed payload remains 3,053,535,091 bytes, below Perl
level 9's 3,054,746,896 bytes. No book grows against frozen Ada; the same 51 books
grow against Perl. Their individual growth records stay in the private reports.

The isolated original-parser comparison passes 41,811 checks on 13,937 decoded
XML documents: 13,930 accepted and seven rejected, with no undecodable corpus
resources skipped. Cases cover namespaces and qualified attributes, duplicate
attributes, DTDs/entities, comments, CDATA, processing instructions, mixed and
fragmented text, large attributes/text and deep nesting. It compares every
retained fact and flag, acceptance and owned entity diagnostics. Full-book
comparisons additionally verify classifications, changed entries and archive
metadata/compression bytes.

Windows: 141 unit/integration/fault tests pass, followed by three complete
reruns. Linux: 91 tests and 19 native destination/filesystem fault cases pass.
All 21 CLI fixtures and 159 entries pass independent verification on Windows,
native Linux storage and Windows-mounted Linux storage, including jobs 1/2/auto,
source preservation, publication races and clean runtime search paths. The
parallel close-fault injector now explicitly targets temporary-output closes;
source finalizer cleanup cannot consume that test's one-shot failure.

Context tests force callbacks to overlap across all selected workers, check
distinct sentinels and namespace bindings, wrong-task/reset/reentry rejection,
foreign and stale symbols, repeated creation/destruction and failure recovery.
One-shot heap failures exercise parser/summary and source-span cleanup. Required
proofs pass all 67 checks. Required core coverage passes; the unchanged global
95% statement / 90% decision gate still fails. Current coverage is recorded in
`verification/coverage-latest.json`; this existing gap is not waived.

## Measurement protocol

Frozen control SHA-256:
`76565A9DF450465B47835D8EFE1450B79AE9003D2448A09A5DD81E99EFC335A0`.
Candidate SHA-256:
`2E7662A990A15B0EBB81B39E75865CACBBF7CEF6E9D1F47A8F04211CA6236FE7`.
Both use the existing physical-core affinity selection and one process. Timing
uses uninstrumented checked native release binaries, with section GC, no LTO
and no PGO. The original 266-book tuning / 71-book holdout partition is retained.

For a matching sixteen-worker comparison:

```powershell
./tools/benchmark.ps1 -InputPath $holdout -ReferenceReport $perlReference `
  -QualityBaselineReport $adaReference -AdaExecutable $candidate `
  -BaselineAdaExecutable $frozen -OutputRoot $privateArtifacts `
  -Jobs 16 -ControlJobs 16 -AffinityMode PhysicalCores `
  -ControlAffinityMode PhysicalCores -MemoryPolicy FrozenParallel `
  -Pairs 8 -ExtendInconclusive -MaximumPairs 32 -Workload Mixed `
  -RequireIdenticalBaseline -ReuseReferenceOutputs -CompressionGate Aggregate
```

The same protocol measures Converted and Preserved separately and checks the
tuning set independently. Single-worker comparisons retain the two-times memory
safeguard. Latency regression is limited to 2%, with the approved 20 ms fixed
allowance only when the frozen median is below 250 ms. Private books, outputs,
profiles and oracle traces stay outside this repository.

## Results

All comparisons below used eight full alternating pairs. The timing, latency,
memory and two compression gates pass. Every paired 95% speedup interval excludes
one; no extension to sixteen or thirty-two pairs was needed. Full numeric results
are in [the verification record](verification/xml-concurrency-latest.json).

| Workload | Books | Workers | Frozen median | Candidate median | Speedup | Paired 95% interval |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Holdout Mixed | 71 | 16 | 1.939 s | 1.540 s | 1.259x | 1.244–1.272x |
| Holdout Converted | 68 | 16 | 1.915 s | 1.499 s | 1.277x | 1.261–1.287x |
| All Preserved | 15 | 16 | 1.057 s | 0.783 s | 1.350x | 1.331–1.363x |
| Tuning Mixed | 266 | 16 | 6.765 s | 5.647 s | 1.198x | 1.166–1.209x |
| Holdout Mixed, serial | 71 | 1 | 18.932 s | 18.142 s | 1.044x | 1.042–1.045x |

For the primary holdout comparison, median per-run peak working set falls from
115.46 to 100.14 MiB. The candidate's worst peak is 106.37 MiB, below the approved
461.84 MiB ceiling (four times the frozen median). Worst serial peak is 22.15 MiB,
below the frozen 25.41 MiB median and its two-times safeguard. Each remaining
workload also passes its own matching-baseline memory gate.

Three additional release runs at each worker count provide the scaling curve.
These curve medians are descriptive measurements, separate from the eight-pair
promotion comparisons above. Each run's persisted archive hashes match frozen
Ada independently.

| Workers | Elapsed median | CPU median | Median peak MiB | Speedup over one |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 18.149 s | 17.234 s | 21.08 | 1.00x |
| 2 | 9.261 s | 17.484 s | 30.64 | 1.96x |
| 4 | 4.749 s | 17.578 s | 42.12 | 3.82x |
| 8 | 2.547 s | 17.922 s | 64.77 | 7.12x |
| 16 | 1.546 s | 19.500 s | 102.03 | 11.74x |

## Remaining costs and queue tail

The reproducible diagnostic builder is `tools/prepare-xml-profile.ps1`; see
[its instructions](tools/diagnostics/README.md). A clean external source copy
builds the same dependency closure with call accounting, allocation measurements
and additional worker timestamps. Both clean diagnostic and ordinary default
builds pass the fork audit. Linux syscall tracing records one initial exec,
sixteen `CLONE_THREAD` calls and zero fork/vfork/helper exec calls.

At 1, 2, 4, 8 and 16 workers, actual collection attachments attributed to SAX,
XML summaries and source-patching attributes are all zero. The old 7,733,684 XML
node/attribute collection lock operations are absent. The separate source-patcher
collection is absent as well. One direct runtime task-lock call remains per
invocation, independent of worker count, outside the XML data path. The
sixteen-worker profile has 91,681 other collection attachments, primarily owned
archive members and result/resource strings; no raw collection address is
unmapped. There is no shared symbol reference-count implementation in the
production closure.

The isolated sixteen-worker profile accounts for 22.799 summed task wall seconds.
Exclusive match finding consumes 8.539 s (37.5%), decompression 5.136 s (22.5%),
and entropy encoding 1.786 s (7.8%). XML syntax work consumes 0.711 s, summary
construction 0.119 s, and summary consumption 0.018 s. The XML parsing phase's
inclusive duration is 0.830 s; callback durations are already included there.
These timings exclude setup/cleanup work assigned to enclosing phases and must
not be added to release elapsed time. The profile counts 3,569,708 malloc calls;
allocator/free durations total 0.683/0.627 summed task seconds and overlap phase
measurements. Runtime/OS allocation synchronization remains a separate cost.

For perspective, the serial diagnostic's exclusive match-finding and
decompression fractions are 40.0% and 24.5% of accounted work. Eliminating either
alone would give ideal bounds of about 1.67x or 1.32x on that accounted work,
assuming other work stayed fixed. These are diagnostic Amdahl bounds, not release
speed forecasts or recommendations to weaken compression/validation.

The instrumented queue drains at 1.255 s and the final worker completes at
1.691 s: a 0.436 s terminal tail. Of 3.457 worker-seconds idle over the pool
lifetime, 3.408 occur after queue drain (98.6%). Workers continue taking new
books whenever runnable tasks remain; the late idle workers have no queued book
to take. This is neither a completion barrier nor a batch.

In the release curve, total CPU work grows by 13.1% from one to sixteen workers,
and the sixteen-worker invocation averages about 12.6 active CPU cores. Unequal
book durations and the terminal queue tail now explain most idle capacity;
remaining codec, allocation, cache and native-I/O costs explain further losses
from ideal scaling. No new XML serialization point was introduced.

A separate follow-up can evaluate cost-aware ordering of books in the same fixed
queue, using entry counts and expanded text sizes to start expensive books early.
That preserves unordered results and worker reuse. Making one large book use
several workers would require separately approved changes to task granularity;
this implementation preserves one whole book per runnable unit. No process
workers, nested pools, parser replacement, compression retuning or LTO experiment
was retained.
