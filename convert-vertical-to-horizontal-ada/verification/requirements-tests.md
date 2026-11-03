# Requirements-to-test matrix

This maps implemented behavior to executable checks and records gaps. Passing
rows do not imply release completion. A numerical comparison with Perl coverage
is pending the Devel::Cover baseline. The current Ada totals are 71 AUnit cases
plus CLI integration; individual cases contain many assertions.

| Requirement | Ada evidence | Perl reference / additional coverage | State |
| --- | --- | --- | --- |
| Writing-mode values, vendor prefixes, casing, importance and idempotence | Text CSS_Matrix; Core Mode_Mapping, Generated_Scanners | 01-text.t; 30 prefix/value combinations and 1,000 deterministic generated inputs | Passing |
| Comments, strings, custom properties, scripts and quoted markup delimiters | Text Markup_Preservation, Scanner_Boundaries; fixture payload parity | 01-text.t, 02-book-parity.t | Passing tested cases; broaden adversarial matrix |
| Metadata and spine direction edits | Text Package_Metadata; Book_Payload_Parity | 01-text.t, 02-book-parity.t | Passing |
| UTF-8, UTF-16LE/BE, CP932, BOM, CRLF, malformed text | Text Encoding_Roundtrips, Encoding_Errors; Book Package_Encoding | 01-text.t, 04-edge-cases.t; explicit four-encoding policy | Passing tested cases; ambiguous CP932 mapping matrix incomplete |
| URI resolution and strict percent-decoded UTF-8 | Text Resource_References, Reference_Matrix, Rejected_References | 04-edge-cases.t; additional differential port, user-info, duplicate-slash and dot-segment checks | Passing tested cases; further generated URI comparisons pending |
| Transitive and cyclic imports, active class/id heuristic | Text CSS_Imports, Active_Selectors; Book Import_Cycles | 02-book-parity.t, 04-edge-cases.t | Passing |
| Classification precedence and image thresholds | Core Classification_Boundaries; Book Image_Thresholds, Fixed_Layout_Order; fixture manifest | 02-book-parity.t; 10,404 exhaustive core combinations and threshold boundary books | Passing; 100% core statement/decision/MC/DC |
| Missing, duplicate and malformed package resources | Book Missing_Resource, Duplicate_Manifest, Unknown_And_Empty_Spine, Rootfile_Counts | 04-edge-cases.t | Passing tested cases |
| Entity declarations and external resolution | Book XML_Entity_Policy | Additional malformed/internal/external/parameter entity tests | Passing tested cases |
| Signature/encryption rejection only when modification required | Book Signature_Guards, Fixed_Layout_Order | 04-edge-cases.t | Passing |
| Non-spine supported resources | Book Nonspine_Editing; fixture parity | 02-book-parity.t, 04-edge-cases.t | Passing |
| Ordered archive reconstruction, DOS time, arbitrary attributes, mimetype | Archive Metadata_Roundtrip, Fixture_Roundtrips; independent Perl verifier | 02-book-parity.t; 21 archives and 159 output entries | Passing |
| ZIP64, Unicode names, empty directories, CRC corruption | Archive Zip64_Roundtrip, Unicode_And_Empty, Corrupt_Payload | Additional Ada archive tests | Passing small ZIP64 cases; large streams and broader mutations pending |
| Local/central consistency and bounded structures | Archive Header_Consistency, ZIP64_Field_Bounds, Archive_Region_Bounds | CRC/size/flag/name mutations, truncated headers and out-of-region metadata | Passing |
| Signed/unsigned ZIP32 and ZIP64 descriptors | Archive Data_Descriptors | Four valid descriptor variants, corrupt CRC/sizes/placeholders and missing descriptor | Passing through owned lower-level adapter |
| Overlap and duplicate extra-field rejection | Archive Entry_Overlap, Duplicate_ZIP64_Fields | CRC-valid overlapping payload and duplicate ZIP64 tag mutations; exact owned error diagnostics | Passing |
| Case-sensitive archive lookup | Archive Case_Sensitive_Names | Distinct A.css/a.css resources and payloads | Passing |
| Preserved-book byte identity, source immutability, second pass | Archive Book_Payload_Parity; test-cli.ps1 | 02-book-parity.t | Passing |
| Long paths and supplementary Unicode filenames | Windows Long_Unicode_Paths; test-cli.ps1 | Additional native Windows tests | Passing |
| Recursive outputs, junction skipping, case-insensitive exclusions | Windows Recursive_Enumeration; test-cli.ps1 | 03-cli.t; duplicate basenames and mixed-case horizontal directories | Passing |
| Exclusive publication, collision rejection, failed-output cleanup | Windows Publication_Collision, Verification_Cleanup; Fault_Cases | 03-cli.t, 04-edge-cases.t; native I/O failure injection | Passing tested cases; concurrent race stress pending |
| Open/read/write/flush/close/move/delete/enumeration failures | Fault_Cases and Native_Faults | Additional one-shot failure injection, including zero-byte transfers and second-call failures | Passing |
| CLI aliases, defaults, analysis, dry run, stderr, exit status, batch isolation | test-cli.ps1 | 03-cli.t | Passing tested scenarios |
| Report schema, nullability, changed-entry sorting, escapes | Report Report_Schema, JSON_Escapes; test-cli.ps1 | 03-cli.t; test-only JSON parser and explicit control escapes | Passing |
| Shared manifest classifications and complete changed-entry sets | Report Fixture_Manifest | 02-book-parity.t; JSON 6.0.0 inspection | Passing |
| Container ownership and invalid indices | Core List_Ownership | Additional indefinite-element, deep-copy and growth checks | Passing |
| Patch preservation, writing-mode mapping, classification, publication proofs | proof/core.gpr | Additional SPARK contracts; 67 current checks discharged | Passing current boundary; ordered multi-edit proofs pending |
| Owned-code warnings as errors | tools/build.ps1; tools/test.ps1 | Strict application, owned containers, tests and proof settings; third-party projects use upstream settings | Passing under revised ownership policy |
| Unmodified dependencies | Alire pins and project imports; BUILD_POLICY.md | No vendor source forks or warning patches; JSON build configuration adapted without source edits | Passing |
| Application coverage gates | tools/coverage.ps1 | 95% statement, 90% decision; separately required core coverage; entry point and owned decompression adapter included | Statement passing at 95.02%; decision failing at 79.26% |
| Static imports and clean PATH | objdump audit; test-cli.ps1 | Four Windows DLLs only; test tools excluded | Passing current binary; automated release audit pending |
| Windows CI and Perl coverage baseline | Not yet implemented | Release acceptance requirements | Pending |

A complete assertion-by-assertion audit of all four Perl test files remains
part of release validation. Additional behavioral tests demonstrate expanded
tested scope; they do not substitute for the remaining coverage or proof gates.
