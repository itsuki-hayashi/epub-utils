# XML diagnostics

These helpers are never included by a production GPR project. From Windows:

```powershell
$probe = ./tools/prepare-xml-profile.ps1 -OutputRoot $privateArtifacts | ConvertFrom-Json
$env:EPUB_PROFILE_PATH = "$privateArtifacts/phases.csv"
$env:EPUB_ALLOC_PROFILE_PATH = "$privateArtifacts/allocations.csv"
$env:EPUB_LOCK_PROFILE_PATH = "$privateArtifacts/collections.csv"
$env:EPUB_CONCURRENCY_STATS = "$privateArtifacts/workers.csv"
& $probe.Executable --input-path $books --output-directory $newPrivateOutput --jobs 16 --json
```

Repeat in fresh output directories for 1, 2, 4, 8 and 16 workers. Release timing
uses `benchmark.ps1` and an uninstrumented executable, never this probe.

The tool copies and fingerprints source into an external directory, builds with
the same checks/assertions, and adds call accounting only to that diagnostic
copy. All wrapped malloc/free, finalization-collection and task-lock operations
call their original implementations. Runtime lock functions, soft links and
finalizers are never changed. Collection attachment counts are distinct from
lock wait timings. Match collection addresses against `symbols.txt` using the
process load base (ASLR) and PE preferred image base.

Phase CSV includes inclusive and exclusive summed task wall durations. Syntax
work is the XML parsing phase's exclusive part; summary callbacks and copied
summary values have separate phases. Heap rows count cumulative allocations and
allocator/free durations, including OS allocator synchronization. Those byte
counts are not peak resident memory. Queue rows record each worker's final job
start/finish: the latest start marks queue drain, and the latest finish minus
that start measures the terminal queue tail. No input paths enter the counters.

The only shared tables here are diagnostic counters, registered once per OS
thread. They are not XML storage and are never linked into the converter.
