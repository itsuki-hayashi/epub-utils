# Ada implementation feasibility and effort estimate

Research date: 2026-11-03. Implementation has started; the converter is not yet complete.

Linux x86-64 support is now available alongside Windows. See [LINUX.md](LINUX.md)
for the static build, platform behavior, WSL guidance, and validation commands.

An Ada implementation is feasible as one executable containing the application, XML parser, ZIP/compression libraries, and Ada runtime. For Windows x86-64, budget **30–50 engineer-days**, or **6–10 full-time weeks for one engineer experienced in Ada/SPARK**, including behavior parity, broader tests, strict owned-code warnings, static packaging, and selected SPARK proofs. The revised policy excludes third-party warning cleanup. These are engineering estimates, not measured implementation times.

The **2–4 day feasibility milestone** is included in that estimate. Archive metadata tests, CP932 round trips, static packaging checks and selected SPARK proofs now run. Full release acceptance gates remain unfinished; current evidence is recorded below and in IMPLEMENTATION.md.

Concurrent processing uses a fixed physical-core worker pool and a queue of
whole books. Workers take another book immediately after each completion;
results have no input-order guarantee. See [CONCURRENCY.md](CONCURRENCY.md)
for --jobs, scheduling, memory, publication, and validation.

## Current executable

The Windows executable now converts the 21 reference EPUBs with matching
classification, changed-entry lists, payloads and specified ZIP metadata.
The complete coverage, proof and release acceptance gates are still
in progress; see [implementation status](IMPLEMENTATION.md).
Build configurations, benchmarking commands, and profiling limitations are in
[PERFORMANCE.md](PERFORMANCE.md).

```powershell
./tools/build.ps1
./bin/epub-v2h.exe --input-path book.epub --output-directory horizontal
./bin/epub-v2h.exe --analyze-only --json
./tools/test.ps1
./tools/test-cli.ps1
./tools/prove.ps1
```

The executable requires normal Windows system libraries. Perl is used only by
the independent development verifier. The selected encodings are UTF-8,
UTF-16LE/BE and CP932. Conversion uses an owned DEFLATE encoder adapted from
Zip-Ada, with stored-entry fallback; preserved books remain exact copies.
Compression strategy may change during optimization, with Perl's zlib level 9
as the compression-quality floor. See [CODEC_ORIGINS.md](CODEC_ORIGINS.md).

## Existing Perl behavior and baseline

The implementation has six application modules totaling 1,187 lines before their POD documentation, plus a small CLI entry point. Four test files contain 687 lines. Its 21 reference EPUBs provide a useful shared acceptance corpus; they include 9 conversions and 12 preservation cases.

The reference is substantially more than a writing-mode substitution:

| Area | Behavior the Ada port must retain |
| --- | --- |
| Classification | Preserve fixed layouts, image-only books, books with at least 10 image pages comprising at least 80% of image/text pages, and horizontal text including RTL languages. |
| Resource discovery | Read container.xml, one package rootfile, manifest and spine; resolve relative and percent-encoded references; inspect linked CSS and transitive imports with cycle termination. |
| Detection | Use metadata, inline styles/SVG attributes, and a limited class/id selector heuristic. Unused vertical toolkits alone do not trigger conversion. |
| Editing | Modify supported declarations, existing primary-writing-mode metadata, and converted books' RTL spine progression. Keep comments, strings, prose, scripts, ruby, unrelated attributes, and formatting intact. |
| Encoding | Inspect decoded XML without serializing it back. Preserve BOMs, encodings and line endings. Return original bytes for unchanged resources; require an exact original round trip before editing. |
| Archive | Copy preserved books byte for byte. For conversions, retain entry order, names, DOS timestamps, external attributes and unedited payloads; recompress resources, with mimetype first and stored without extra data. |
| Publication | Create temporary output exclusively, verify every entry before publication, reject overwrites atomically, remove failed temporary files, and continue after a per-book failure. |
| CLI and filesystem | Retain aliases, JSON report fields, exit statuses, dry runs, analysis, recursion, per-source horizontal directories, excluded output directories, and skipped directory links/junctions. Support literal Unicode and long Windows paths. |

Important ordering details belong in tests: fixed-layout preservation happens before manifest/spine inspection; signatures/encryption metadata reject modification after vertical classification, rather than rejecting every preserved book. Once conversion is selected, the Perl code patches supported manifest CSS/markup resources as well as imported CSS, including resources outside the spine.

Relevant source: [Text.pm](../convert-vertical-to-horizontal-perl/lib/Epub/Convert/VerticalToHorizontal/Text.pm), [Book.pm](../convert-vertical-to-horizontal-perl/lib/Epub/Convert/VerticalToHorizontal/Book.pm), [Archive.pm](../convert-vertical-to-horizontal-perl/lib/Epub/Convert/VerticalToHorizontal/Archive.pm), [Files.pm](../convert-vertical-to-horizontal-perl/lib/Epub/Convert/VerticalToHorizontal/Files.pm), [CLI.pm](../convert-vertical-to-horizontal-perl/lib/Epub/Convert/VerticalToHorizontal/CLI.pm), and [the publication coordinator](../convert-vertical-to-horizontal-perl/lib/Epub/Convert/VerticalToHorizontal.pm).

The existing suite passed locally with Perl 5.42.3:

```text
prove -Ilib -Ilocal/lib/perl5 t
Files=4, Tests=91
Result: PASS
```

The 91 count is top-level TAP tests and includes nested subtests, not 91 independent assertions. Perl emitted locale warnings from the host's inherited C.UTF-8 settings. No Devel::Cover baseline is configured in cpanfile, and Devel::Cover is not installed in this environment. Consequently, a numerical claim about exceeding Perl's line or branch percentage would currently be unsupported.

## Current compiler and library choices

Alire 2.1.1 is installed locally. The following releases were checked against the public community index, branch stable-1.4.0 at commit [fda959dde3114c242d7bd5844281cc6345dc3ab2](https://github.com/alire-project/alire-index/tree/fda959dde3114c242d7bd5844281cc6345dc3ab2). Availability is platform-specific.

| Component | Version | Intended use |
| --- | --- | --- |
| gnat_native | 16.1.0 on Windows x86-64 | Latest compatible Windows compiler in the checked index. |
| gprbuild | 26.0.1 | Project builds; its manifest identifies the distributed artifact as 26.0.0-1. |
| xmlada_epub | 26.0.0-epub.1 | Maintained, context-owned SAX/input/Unicode fork; relative source pin. |
| zipada | 62.0.0 | Archive reading, decompression, ZIP structures and stream support; a preservation adapter is necessary. |
| aunit | 26.0.0 | Modular unit and integration test suites. |
| gnatprove | 16.1.0 | Development-only analysis and proofs of selected core packages. |
| gnatcov | 26.2.1 | Development-only statement, decision and selected MC/DC coverage. |
| uri_ada | 2.0.0 | Candidate URI parsing helper; verify relative resolution and decoding against Perl before adopting. |
| json | 6.0.0 | Test-only inspection of fixture expectations and reports; production uses a fixed-schema serializer. |

The catalog's newest gnat_native is **16.2.0-pre0**, but [that release manifest](https://github.com/alire-project/alire-index/blob/fda959dde3114c242d7bd5844281cc6345dc3ab2/index/gn/gnat_native/gnat_native-16.2.0-pre0.toml) contains only macOS origins. The [16.1.0 manifest](https://github.com/alire-project/alire-index/blob/fda959dde3114c242d7bd5844281cc6345dc3ab2/index/gn/gnat_native/gnat_native-16.1.0.toml) includes Windows x86-64 and Linux. Thus 16.1.0 satisfies “latest provided by alr” for this Windows host; selecting the highest catalog version blindly would fail that platform requirement.

Use **Ada 2022**, explicitly selected with `-gnat2022`. It is the latest standardized language mode listed by the [GNAT language-version documentation](https://gcc.gnu.org/onlinedocs/gnat_ugn/Compiling-Different-Versions-of-Ada.html). Keep proven units within the features accepted by the selected GNATprove release. Freeze exact tool versions, dependency resolutions and source checksums for releases, then recheck newest platform-compatible versions when implementation starts.

Production imports the checked-in `xmlada_epub` static SAX/input/Unicode projects. Their configuration is portable and requires no configure action or machine-specific paths. Original XML/Ada is confined to the isolated test oracle. Build audits reject mixed original/fork closures. See [XML concurrency](XML_CONCURRENCY.md).

Use the documented runtime package [GNAT.SHA256](https://gcc.gnu.org/onlinedocs/gnat_rm/GNAT-SHA256-g-sha256-ads.html) for verification hashes, avoiding another cryptographic library. AUnit, GNATprove, provers, GNATcoverage and its instrumentation runtime remain outside the production executable.

## Static executable requirements

The practical Windows acceptance criterion is **one exe with no separately distributed application or compiler DLLs**. Windows system DLLs remain dependencies of a native process. This is the useful Go-like distribution model; a process with literally no OS dependency is not the target.

Configure static XML/Ada libraries, static GNAT runtime binding, and static GCC support libraries. Audit each dependency's own GPR settings: an executable project's settings do not automatically change imported library kinds. [GNAT's binder options](https://gcc.gnu.org/onlinedocs/gnat_ugn/Switches-for-gnatbind.html) include static runtime selection. Linker flags such as `-static` and `-static-libgcc` must be validated against the actual MinGW toolchain and generated link command, rather than treated as proof of a standalone executable.

Verify the result with PE import inspection using `objdump -p` or `dumpbin /DEPENDENTS`, a link map, and execution on a clean Windows machine without Alire, GNAT, Perl, MSYS2 or development PATH entries. Check that no libgnat, libgcc, libwinpthread, XML/Ada or compression DLL is required. Record the system DLL allowlist and run real conversion, Unicode path, and recursive traversal tests there.

Build a separate executable for each OS/architecture. A Linux release can aim for a fully static ELF, but must pass its own runtime/static-libc spike, `readelf` inspection, and clean-container tests. macOS normally retains system dynamic libraries. Linux or macOS support is additional scope beyond the Windows estimate below.

## Library gaps and implementation work

### XML inspection

XML/Ada is a suitable replacement for inspection, but it does not replace Perl's XPath calls directly in this design. Implement the finite queries as namespace-aware DOM traversal helpers or SAX collectors for package metadata, manifest, spine, visible text, classes/ids and stylesheet links. Keep the original bytes separate from the inspection tree.

Configure external general and parameter entities off, refuse external resolution, and reject declared internal/external entities through SAX callbacks. [XML/Ada's reader specification](https://github.com/AdaCore/xmlada/blob/v26.0.0/sax/sax-readers.ads) defaults both external-entity features to true. A resolver returning null is insufficient if it allows default resolution; test that file and network access never occur. Preserve compatibility with ordinary external DOCTYPE references when the DTD is not loaded.

### Encodings and minimal text edits

The [XML/Ada encoding registry](https://github.com/AdaCore/xmlada/blob/v26.0.0/unicode/unicode-encodings.adb) handles UTF and several single-byte sets but has no CP932/Shift-JIS branch. Perl explicitly tests CP932, so UTF-only handling would lose existing coverage.

For Windows, evaluate strict Win32 conversion APIs for CP932, reject substitutions/best-fit changes, and retain the original-byte round-trip gate. For portable support, use an audited embedded mapping implementation or a source-built static conversion library. CP932 differs from generic Shift-JIS and has non-bijective mappings, so aliases and ambiguous round trips need explicit tests. Perl's Encode can also accept more encodings than its current tests exercise; a complete parity promise needs a documented accepted-encoding inventory.

Replace the Perl regular-expression machinery with small deterministic scanners for CSS comments, strings, declarations, imports, markup tags, quoted attributes, scripts and style elements. Maintain source spans and apply only supported replacements. Decoding must precede token scanning: punctuation bytes inside multibyte encodings are not independently safe delimiters. Retain the original declaration-based CSS heuristic instead of expanding this port into a browser cascade engine.

### ZIP preservation and compression

[Zip-Ada](https://alire.ada.dev/crates/zipada) is standalone Ada and supports ZIP streams and Deflate. However, [the released writer](https://github.com/zertovitch/zip-ada/blob/v62/zip_lib/zip-create.adb) initializes new entries' external attributes to zero and optionally adds a read-only bit. Its public convenience interface is therefore insufficient for Perl's arbitrary external-attribute preservation guarantee. Also, its default directory traversal is sorted; original central-directory order must be retained separately.

Implement a narrow archive adapter using Zip-Ada's lower-level headers and streams, or maintain a small pinned upstream extension. Preserve raw DOS timestamps and attributes without lossy calendar conversions; check UTF-8 names, empty directories, ZIP64, duplicate names, CRC failures and local/central header consistency. Set case-sensitive name lookup explicitly, since Zip-Ada's Load default is case-insensitive.

[Zip-Ada compression modes](https://github.com/zertovitch/zip-ada/blob/v62/zip_lib/zip-compress.ads) are not zlib's numerical levels. Its Deflate variants cannot truthfully be described as “zlib level 9.” The original implementation selected Deflate_R with stored fallback. Performance work now maintains the required encoder subset in owned source, with no zlib dependency. Current acceptance requires aggregate compressed payload size no larger than both frozen Ada outputs and Perl's zlib level 9, reporting individual books that grow. Strategy may change, but output quality must be measured on tuning and holdout sets. See [PERFORMANCE.md](PERFORMANCE.md). [zlib_ada](https://alire.ada.dev/crates/zlib_ada) is a binding depending on zlib; installing it alone would not establish static linking or source-building of the native dependency.

The compression-policy change to the all-Ada compressor was explicitly approved. Compressed byte identity is unnecessary: the Perl fixture tests compare decompressed payloads and specified metadata. Preserved books still require exact whole-file copies.

### Filesystem and publication

Keep OS-specific filesystem bodies behind one interface. On Windows, use wide APIs for arguments, enumeration, exclusive creation, file handles, long paths, reparse-point detection and publication without replacement. Feed archive libraries streams rather than path strings that may pass through ANSI APIs. Test supplementary Unicode characters and redirected UTF-8 stdout, as well as console output.

Do not implement publication as an existence check followed by a potentially overwriting rename. On Windows use a move operation that atomically fails if the destination exists; on POSIX use an appropriate no-replace primitive or the reference's hard-link approach. Put temporary output beside its destination, retain exclusive handle ownership, and test cleanup after each injected I/O failure.

## Compiler policy and idiomatic Ada design

Use `-gnat2022 -gnatw.e -gnatwe` for Ada compilation. The [warning documentation](https://gcc.gnu.org/onlinedocs/gnat_ugn/Warning-Message-Control.html) distinguishes `-gnatw.e`, enabling every optional GNAT warning, from `-gnatwa`, which enables only most. `-gnatwe` makes warnings and enabled style diagnostics fatal. Add applicable GCC backend diagnostics such as `-Wall -Wextra -Werror`, and audit additional Ada-applicable backend warnings supported by the selected compiler. GCC has language-specific and mutually unsuitable warning switches; “every GCC -W switch” is not a usable cross-language build configuration.

The user's revised policy limits strict diagnostics to owned application code, containers, tests and proof units. Third-party projects keep their upstream compiler settings; dependency warnings are not release gates. The maintained XML/Ada fork is the approved exception; see [fork provenance](vendor/xmlada_epub/EPUB_FORK.md). Test-only JSON uses a compatible project configuration without source changes. See [BUILD_POLICY.md](BUILD_POLICY.md). Generated tooling code and compiler/runtime artifacts use their supplied configuration.

Retain runtime checks and enable assertions/contracts with `-gnata` in validation builds. Keep separate release, test, coverage and proof projects so instrumentation and proof-only dependencies cannot leak into the shipped executable.

Use child packages under an application namespace, for example:

```text
src/core/        Epub.Types, Epub.Spans, Epub.Patches, Epub.Classification
src/text/        Epub.Encoding, Epub.CSS, Epub.Markup, Epub.Package_Text
src/book/        Epub.XML_Inspection, Epub.Resources, Epub.Book_Plans
src/archive/     Epub.Archives, Epub.Archive_Verification
src/platform/    Epub.Files with separate Windows/POSIX bodies
src/cli/         Epub.Options, Epub.Reports, main
tests/unit/      One AUnit child suite per core/text package
tests/integration/  Archive, publication, fixture and CLI suites
proof/          Restricted project for the SPARK core
tools/          Build, coverage, proof and dependency-audit entry points
```

Prefer enums and discriminated result records over string status protocols internally; serialize the established report names at the boundary. Distinguish bytes, UTF-8 text, decoded scalar text, archive paths and filesystem paths through types. Use private types and limited controlled owners for handles, deterministic containers where ordering matters, explicit overriding indicators and narrow visibility. Translate expected errors into structured per-book results at the orchestration boundary. Avoid a generic exception handler that silently returns success or discards cleanup failures.

## Tests that exceed the Perl baseline

Port all existing behaviors, not merely the 21 fixture names. Reuse the shared manifest and expected payloads; preserve its second-pass exact-copy checks and archive metadata comparisons. Add an independent verifier so a writer and its own reader cannot validate the same defect undetected.

| Suite | Additional coverage |
| --- | --- |
| CSS and markup units | Prefix/value matrix, case, whitespace, important/comments, escaped quotes, empty/truncated tokens, attributes containing >, scripts, strings and custom properties; idempotence and non-target byte preservation. |
| Encoding units | Malformed UTF-8, truncated UTF-16 and surrogates, BOM/declaration conflicts, CP932 extension/ambiguous mappings, non-round-tripping source bytes, embedded NUL, unsupported encodings and exact LF/CRLF preservation. |
| URI/resource units | Fragments, percent-encoded Unicode and delimiters, query/external references, dot segments, case-distinct archive names, cyclic/duplicate imports and missing imported resources. |
| Classification units | Exact boundary cases around 9/10 image pages and 80%, no eligible spine text, mixed fixed layout, unused classes/ids, signature/encryption ordering and non-spine patch targets. |
| Archive integration | Nonzero POSIX/DOS attributes, unusual valid DOS timestamps, empty directories, Unicode names, data descriptors, ZIP64, duplicate/local-central conflicts, truncation and CRC corruption; mimetype flags/method/extra checks. |
| Filesystem and CLI | Publication races, concurrent temporary creation, write/close/verify/move failure injection, unwritable paths, cleanup, supplementary characters, long paths, junction cycles, mixed-case horizontal directories, aliases, invalid options, stdout/stderr and report schema. |
| Generated cases | Fixed-seed valid/invalid token generators and archive mutations; enforce termination, idempotence, bounded output growth and preservation properties; differential checks against Perl for shared supported behavior. |

Measure Ada application coverage with [GNATcoverage](https://alire.ada.dev/crates/gnatcov). Proposed release gates are at least **95% statement and 90% decision coverage** across owned executable code, **100% statement/decision coverage for the patch and classification core**, and **100% MC/DC for the small preservation/publication decision functions**. Exclude third-party libraries from application percentages and report platform-specific bodies separately. Any unreachable-code exclusions need a precise recorded reason; they must not hide failed error-path tests.

These percentages are proposed gates, not measured results. Establish Perl coverage with Devel::Cover in a supported development environment during implementation. Compare behavioral coverage through a requirements-to-test matrix; percentages from different languages and different source structures are not directly comparable. Success means every existing Perl behavior is covered, new categories above pass, and the Ada measurement gates pass.

## Practical SPARK proof scope

Keep I/O, DOM objects, decompression, encoding adapters and OS bindings outside the initial proof boundary. Prove small deterministic routines that are reused by the real converter:

| Candidate | Useful proof obligations |
| --- | --- |
| Source spans and patch application | Valid bounds; sorted non-overlapping edits; no index/length overflow; bytes outside edited spans retain their order and value; output matches the specified concatenation. |
| Writing-mode mapping | All supported vertical modes/prefix combinations map to the specified horizontal token; other inputs remain unchanged; mapping is idempotent. |
| Layout classification | Preservation precedence and image threshold are correct at boundaries. Use widened/checked integer arithmetic, e.g. 5*images >= 4*total, with overflow bounds. |
| Publication decision model | Only verified output is eligible for publication; a collision produces refusal. The model does not prove OS atomicity. |

Use `SPARK_Mode`, pre/postconditions, `Global`/`Depends` contracts, ghost models, loop invariants and variants. Begin with flow analysis and absence of runtime errors, then functional contracts. Record exactly which units and properties are discharged, all assumptions, the tool versions and any undischarged obligations. No blanket “formally verified converter” claim follows from these local proofs. XML/Ada, compression code and OS behavior remain trusted dependencies validated through tests.

The [SPARK language overview](https://docs.adacore.com/spark2014-docs/html/ug/en/spark_2014.html) documents Ada 2022 features in SPARK. The [Alire GNATprove release](https://alire.ada.dev/crates/gnatprove) cautions that its intermediate build need not implement everything described in current SPARK Pro documentation, so verify selected contracts with the pinned tool early.

## Effort and implementation sequence

The estimates below assume Windows x86-64 first, the existing declaration-based behavior, Zip-Ada Deflate_R compression with native stored fallback, UTF-8/UTF-16/CP932 support, and one experienced engineer. Tests are developed alongside each subsystem; the dedicated test row covers cross-component acceptance, coverage gaps and generated cases.

| Work package | Engineer-days |
| --- | ---: |
| Toolchain/static-link/encoding/ZIP feasibility spike | 2–4 |
| Encoding, CSS and markup scanners, source-span edits | 5–8 |
| XML inspection, resource graph and book planning | 3–5 |
| ZIP preservation adapter, static zlib and read-back verification | 4–6 |
| Windows Unicode filesystem and safe publication | 3–5 |
| CLI, batching and JSON reports | 1–2 |
| Shared fixtures, extra tests, coverage and independent verification | 4–6 |
| Selected SPARK contracts and proof completion | 3–5 |
| Owned-code warning checks and release validation | 5–9 |
| **Total** | **30–50** |

The spike must produce a tiny executable that links XML/Ada and archive support statically, rewrites a test entry without changing arbitrary attributes/order/timestamps, performs a CP932 edit with the exact round-trip guard, and demonstrates one real SPARK proof under the selected compiler. It must compile owned code under the strict warning policy, build dependencies with upstream settings and inspect executable imports.

After that, implement and prove the core scanners/patches, add XML/book analysis, integrate ZIP/filesystem publication, then finish CLI parity and acceptance tests. End with measured coverage, stored proof reports, release import audits and clean-machine execution. Keep the Perl implementation as the executable behavioral reference throughout.

A Linux x86-64 release would add an estimated **3–6 engineer-days** for its platform body, static-runtime/libc validation and CI if the dependency spike succeeds. A portable CP932 implementation beyond Windows APIs may add **2–5 days** depending on the selected library and encoding inventory. Broader encoding parity, macOS, new CSS cascade behavior, whole-program formal verification and visual reader conformance are separate work items.

The best first investment is the 2–4 day spike. Static linkage itself is likely manageable; preserving the existing bytes and metadata while satisfying the strict diagnostic and verification requirements determines the overall effort.
