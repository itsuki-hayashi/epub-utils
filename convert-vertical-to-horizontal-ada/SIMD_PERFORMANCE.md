# CRC instruction acceleration

This change adds a bounded Ada PCLMUL implementation of ZIP's IEEE CRC-32.
It preserves the checksum state, compressed streams, archive ordering and book
queue. It adds no production C codec, dependency, DLL or worker pool.

## Measured release results

Eight alternating pairs compare uninstrumented native releases on the Ryzen 9
7950X3D, using one logical thread per physical core. The primary objective is
the original single-core optimization target; sixteen-worker results are
separate throughput and regression checks. Bootstrap intervals use 10,000 paired
resamples with the existing fixed seed. Private reports record every run.

| Workload | Workers | Books | Pairs | Frozen seconds | CRC seconds | Speedup | Paired 95% interval |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Converted | 1 | 68 | 8 | 17.902253 | 17.266109 | 1.0368x | 1.0325–1.0417x |
| Preserved | 1 | 3 | 8 | 0.458949 | 0.451849 | 1.0157x | 0.9970–1.0267x |
| Mixed | 1 | 71 | 8 | 18.316876 | 17.621010 | 1.0395x | 1.0281–1.0482x |
| Converted | 16 | 68 | 8 | 1.515257 | 1.459773 | 1.0380x | 1.0184–1.0589x |
| Preserved | 16 | 3 | 8 | 0.330355 | 0.332208 | 0.9944x | 0.9910–1.0129x |
| Mixed | 16 | 71 | 8 | 1.537548 | 1.497474 | 1.0268x | 1.0200–1.0336x |
| Preserved | 16 | 15 | 8 | 0.777584 | 0.766538 | 1.0144x | 1.0017–1.0246x |

The single-core and sixteen-worker Converted promotion gates pass, including
matching Mixed and Preserved checks. Sixteen-worker Mixed improves by 2.68%;
its interval excludes no improvement, but its point estimate is below the 3%
target for that workload. The Converted gate passes separately at both worker
counts. All measured workload latency and memory gates pass.

| Workload | Workers | Worst CRC peak MiB | Matching frozen median peak MiB | Limit MiB |
| --- | ---: | ---: | ---: | ---: |
| Converted | 1 | 21.43 | 22.16 | 44.32 |
| Preserved | 1 | 13.01 | 12.98 | 25.95 |
| Mixed | 1 | 21.77 | 21.31 | 42.62 |
| Converted | 16 | 104.94 | 99.20 | 396.80 |
| Preserved | 16 | 16.23 | 16.25 | 64.99 |
| Mixed | 16 | 101.95 | 98.87 | 395.48 |
| Preserved | 16 | 43.50 | 40.93 | 163.71 |

The worst qualifying single-worker peak is 21.77 MiB; a separate matching
71-book Perl memory probe records 73.61 MiB. That one-pair probe checks memory;
it is not an eight-pair claim about Perl throughput. Parallel limits use four
times the frozen median of per-run peaks; single-worker limits retain two times.
The existing short-invocation allowance and all coverage thresholds are unchanged.
See [machine-readable results](verification/simd-latest.json).

## Implementation

`Epub.Checksums.Hardware` folds four independent 128-bit lanes with GCC's
PCLMUL/SSE2 intrinsics and reduces the result using the reflected IEEE polynomial.
Its Ada implementation adapts Chromium's attributed folding algorithm; source
identity and the complete BSD notice are in [CODEC_ORIGINS.md](CODEC_ORIGINS.md).
Release packaging includes that document beside the executable.

CPUID leaf 1 ECX bit 1 selects the hardware path. Detection occurs once during
package elaboration; the resulting flag and fold constants are immutable.
Checksum state and vector lanes belong to each call. There is no allocation,
shared mutable CRC state or added synchronization. The targeted function uses
`pclmul,sse2`; the portable build's disassembly contains legacy XMM instructions,
with no AVX/YMM/ZMM requirement in that function. Native builds retain their
existing machine-specific compiler options.

Only spans of at least 64 bytes use hardware. It consumes complete 16-byte
blocks; the original slicing-by-eight implementation handles short inputs,
tails and unsupported CPUs. `Software_Only` exercises the fallback in tests.
Every vector load stays inside its input span. Checked arithmetic, bounds
checks, assertions, initial archive validation and persisted-file verification
remain enabled. SSE4.2's CRC instruction implements CRC-32C and cannot replace
the IEEE checksum required by ZIP.

The existing SHA instruction path and 64-bit match-prefix comparisons remain.
A separate SSE2 16-byte matcher experiment passed correctness but was rejected:
four alternating tuning pairs over 24 Converted books measured 8.5571233 s
versus 8.4838444 s, a 1.00864x speedup with paired 95% interval
0.99412–1.01947. Its implementation was removed before CRC qualification.

## Validation

The Windows suite passes all 141 cases. Linux passes all 91 unit cases and
the 19 native filesystem fault checks. Native and portable Windows CLI suites
and the Linux static CLI suite independently verify 21 archives/159 entries.
All 67 applicable proof checks pass. The XML fork dependency-closure audits
continue to pass with its original source identity and dependency pins.

CRC differential checks compare hardware, forced software and the unmodified
Zip-Ada reference. They cover empty input, known answers, 32 alignments, lengths
around 8/16/64-byte boundaries, 32 KiB boundaries, arbitrary prior CRC states,
fragmented updates and array bounds ending at `Integer'Last`. Test-only native
helpers place inaccessible pages immediately before and after input storage;
every length from 0 through 256 is checked against the protected end boundary.
These helpers are absent from the production source closure.

All 337 private books produce byte-identical archives against frozen Ada:
322 Converted and 15 Preserved, with no errors. Aggregate compressed payload
size remains 3,053,535,091 bytes, against Perl level 9's 3,054,746,896 bytes.
No book grows against Ada; the existing 51 individual books larger than Perl
remain unchanged. Detailed per-book growth reports stay outside the repository.

The new hardware unit reaches 48/48 statements and 5/5 decisions. Required core
coverage passes. Global statement/decision coverage is 93.97%/76.08%; the existing
95%/90% global gap remains. See [coverage results](verification/coverage-latest.json).

## Reproduction

Build both release configurations with the pinned toolchain:

```powershell
./tools/build.ps1 -BuildKind release -CpuTuning native -SectionGC
./tools/build.ps1 -BuildKind release -CpuTuning portable -SectionGC
```

Native output is `bin/release-native-sections/epub-v2h.exe`; portable output is
`bin/release-portable-sections/epub-v2h.exe`. Linux uses `EPUB_BUILD=release`,
`EPUB_TUNING=native` or `portable`, and `EPUB_SECTIONS=true` with `tools/build.sh`.

The benchmark compares immutable copies of the release executables with
profiling disabled. Use `tools/benchmark.ps1` with both `-BaselineAdaExecutable`
and `-QualityBaselineReport`, `-RequireIdenticalBaseline`, eight alternating
pairs and the existing tuning/holdout split. Select `SingleCore`/`WorkerScaled`
for one worker or `PhysicalCores`/`FrozenParallel` for sixteen workers. Keep
inputs, outputs, reference reports and profiles outside the repository.

The frozen control is the production native-sections executable from commit
`decadc0836d04948a086c3f6357ee1b94c03ad85`, SHA-256
`2E7662A990A15B0EBB81B39E75865CACBBF7CEF6E9D1F47A8F04211CA6236FE7`.
The CRC candidate is
`2EAC4054BB5F6D418AE8FD627F4835FC7CFDAE3F586B8C09E5E524A0144D78DC`.
The portable binary is
`F1A0CB53ACE981C20C1C7D42460138AFF9D137B64D7A3CED7C3D7E3645EF59ED`.
The Linux native validation binary is
`9D793CEE1183ED781851F4FACFC9ABF376F280434F4DCCAA7678C0F2E2FEAC85`.
The Linux portable validation binary is
`059DA95E1F3D2F4110FA02DA7E4E044AE25CA0A5E5A154185CCD40879ED1BD32`.

## Remaining costs

Fresh isolated profiles use the same 71-book holdout with one and sixteen
workers. They include phase timers, allocation wrappers and runtime collection
observation; they do not determine release speed or promotion. Timers sum task
wall durations and distinguish inclusive phases from exclusive work.

| Exclusive work | One worker | Sixteen workers |
| --- | ---: | ---: |
| Match finding | 39.76% | 38.15% |
| Decompression | 22.78% | 20.90% |
| Entropy encoding | 7.43% | 8.13% |

The percentages use 18.137 and 22.451 summed accounted task seconds respectively.
Hashing consumes another 5.06% in the serial diagnostic. CRC work remains inside
its calling phases, including decompression; its time is not independently
separated by these timers. The hardware routine itself has no allocation or
lock operations. The observed runtime task-lock call count remains one per
invocation, outside the XML data path.

Match finding remains dependent on chain traversal and the existing compression
decisions. A wider prefix comparison alone did not materially improve it.
Further changes need new measurements against the same quality and regression
gates. Unequal whole-book costs and the terminal queue tail also remain; the
pool continues to refill idle workers while any queued books remain. This
change preserves the current task granularity.
