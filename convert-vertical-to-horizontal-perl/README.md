# Horizontal EPUB converter — Perl 5.44

`Convert-EpubToHorizontal.pl` preserves horizontal and image-based EPUBs as
exact copies and converts reflowable vertical text with minimal resource edits.
It uses **Perl 5.44**, with CPAN dependencies installed inside this workspace.
The original PowerShell implementation remains as a reference and independent
collection verifier. Originals and existing outputs are never replaced.

## Verified collection results

The current folder contains **276 source EPUBs**. The completed Perl run:

- Converted 273 vertical books and copied three English books byte-for-byte.
- Independently compared all 21,122 ZIP entries: 20,576 identical payloads and
  546 direction-only payload changes, one stylesheet and one package per book.
- Inspected all 276 outputs again, finding them horizontal with no further
  changes proposed.
- Compared all 21,122 payloads and entry metadata directly with the PowerShell
  outputs, finding zero differences. One reference was regenerated because its
  saved reading copy had acquired a Calibre bookmarks entry; that copy was
  left untouched. Results are in `test-results/perl-powershell-parity.json`.
- Reduced 2,899,514,565 input bytes to 2,895,717,864 output bytes, saving
  3,796,701 bytes. Images and other payloads remain byte-identical.

Perl outputs are in `horizontal-perl/`. Per-book hashes, sizes, classifications
and changed paths are in `perl-conversion-report.json`; independent comparison
totals are in `perl-verification-summary.json`. Second-pass results are in
`test-results/perl-second-pass.json`. PowerShell reference outputs remain in
`horizontal-verified/`, and the original ten outputs remain in `horizontal/`.

No fixed-layout or image-only books were detected in this collection. Comic
preservation is verified with synthetic fixtures; classification protects
layouts rather than attempting to identify a book's genre.

## Local installation

Dependencies are already installed. To install or verify them again:

```text
perl tools/install-dependencies.pl
```

The installer reads `cpanfile` using the vendored cpanminus bootstrap and
`--local-lib-contained local --installdeps . --with-develop`. Modules and
development tools go in `local/`, and caches stay in `.cpanm/`. No global
installation, force installs, or skipped CPAN test suites are used.

Direct runtime CPAN dependencies are `Archive::Zip`, `XML::LibXML`, and `URI`.
Windows additionally uses `Win32::LongPath` and `Win32::API`. Development and
configure-time dependencies, including Perl::Tidy and Perl::Critic, are also
declared in `cpanfile`. `English`, `Encode`, JSON, SHA-256, file utilities, the
test harness, and native Windows Perl's `Win32` module come with Perl.
`perl-dependency-versions.json` records the versions and local paths actually
loaded during verification.

A fresh native Windows install needs the matching MSVC developer environment,
CMake, nmake, and Windows `tar`. The installer builds libxml2 2.15.4 inside
`.cpanm/native/`, runs its native CTest suite, and installs the static library
under `local/native/libxml2/`. All eight native tests and the XML::LibXML CPAN
tests passed. Unix-like systems use XML::LibXML's normal system/Alien build
path instead of the Windows native-build helper.

Module::Pluggable is pinned to 6.3 to avoid 6.4's native-Windows install-hook
failure. The Windows PkgConfig bootstrap corrects an inaccurate symlink test;
its runtime code is unchanged. Installer-only color-environment overrides allow
YAML::PP's ANSI-color tests to run normally. See `vendor/README.md` for original
source URLs, checksums, and the scope of these accommodations.

## Usage

```text
# Inspect the EPUBs beside the script without creating output books.
perl Convert-EpubToHorizontal.pl --analyze-only

# Convert/copy the collection into a fresh directory and write a JSON report.
perl Convert-EpubToHorizontal.pl --output-directory horizontal-new --report-path new-report.json

# Process one literal filename, including brackets or Japanese characters.
perl Convert-EpubToHorizontal.pl --input-path "book.epub" --output-directory one-output

# Preview without creating books, directories, or a report.
perl Convert-EpubToHorizontal.pl --output-directory preview --what-if

# Machine-readable stdout; diagnostics go to stderr.
perl Convert-EpubToHorizontal.pl --analyze-only --json
```

The default input directory is the script directory; the default output is
`horizontal/`, matching PowerShell. Directory input is nonrecursive. Existing
outputs and reports are never overwritten; choose a fresh destination for a
repeat run. An explicit report requires an existing parent directory.

Options also accept `--InputPath`, `--OutputDirectory`, `--AnalyzeOnly`,
`--WhatIf`, `--ReportPath`, and `--Verbose` aliases. `--help` lists all options.
A bad book produces an `Error` record and a diagnostic; later books still run.
The report is written and the process returns exit code 1 if any books failed.

On Windows, the entry script uses `English qw(-no_match_vars)`, conditionally
loads `Win32`, calls `Win32::SetConsoleCP(65001)` and
`Win32::SetConsoleOutputCP(65001)`, and configures UTF-8 stdout/stderr handles.
Unicode arguments are recovered with `GetCommandLineW`/`CommandLineToArgvW`;
file operations use wide APIs. Filenames are literal, with no shell expansion.
Windows modules and API calls remain conditional. Unix-like paths and command
arguments are treated as UTF-8.

## Preserving books and compressing conversions

| Detected layout | Action |
| --- | --- |
| Horizontal text, including horizontal RTL languages | Exact file copy, verified by SHA-256 |
| Fixed layout, including mixed fixed/reflowable spine items | Exact file copy |
| Image-only spine documents | Exact file copy |
| At least ten image-only pages forming 80% or more of image/text spine documents | Exact copy, reported as `ImageDominated` |
| Reflowable vertical text | Patch direction settings, repack, verify every entry |

An exact copy preserves the entire ZIP, including compression and archive
metadata. Such books are **not recompressed**, because recompression would
conflict with keeping them exactly unchanged.

Converted books use **zlib DEFLATE level 9** for every entry except `mimetype`,
which is first and uncompressed as required by EPUB. Payloads are actually
recompressed; the script does not merely set a preference that could reuse old
compression streams. The PowerShell reference uses `.NET SmallestSize`, so
compressed ZIP bytes and sizes may differ between the engines. Neither setting
guarantees the smallest archive achievable by every external ZIP optimizer.

## Minimal edits and layout handling

The package is discovered through `META-INF/container.xml`. Manifest resources
are resolved relative to the package, including nested paths and URL escapes.
Linked CSS and CSS imports are inspected. Both `OEBPS/content.opf` layouts and
the `item/standard.opf` publisher-toolkit layout in this collection are supported.

Vertical evidence comes from package writing-mode metadata, markup styles/SVG
attributes, or linked CSS rules whose class/id names occur in spine documents.
Unused class rules, commented rules, and unlinked vertical toolkits alone do
not trigger conversion.

For a converted book, the supported direction edits are:

- Standard, WebKit, EPUB, Mozilla and Microsoft writing-mode declarations:
  `vertical-rl`, `vertical-lr` and sideways modes become `horizontal-tb`.
- Legacy `tb-rl`/`tb-lr` values become `lr-tb`; Microsoft declarations use
  `lr-tb` for horizontal writing.
- Inline style elements/attributes and SVG writing-mode attributes receive
  corresponding changes.
- Existing `primary-writing-mode` metadata becomes `horizontal-tb`.
- Existing spine `page-progression-direction="rtl"` becomes `ltr` only for
  converted text books. Horizontal RTL books and comic page order stay intact.

Comments, CSS strings, prose, scripts, and unrelated attributes are not editing
targets. Orientation classes such as `vrtl` remain named as before because
publisher styles use them for unrelated typography too. Text, ruby, images,
fonts, navigation, physical margins, dimensions and other CSS are preserved.
XML is parsed for inspection, never reserialized. Encodings, BOMs, whitespace
and line endings are retained; changed text must round-trip through its source
encoding exactly.

Converted archives retain entry names, order, DOS timestamps, external
attributes, and every unedited payload. ZIP compression and archive-level
metadata may differ. Temporary archives are read back and SHA-256 checked entry
by entry before publication; failed temporary outputs are removed. Unicode
entry names and empty directory payloads are handled explicitly to avoid
Archive::Zip's name-reset and undefined-empty-payload behaviors.

## Code organization

The script is a small CLI entry point. Stable native signatures, `try`/`catch`,
named regex fragments and focused modules keep the implementation readable.
It enables no experimental features. `use 5.044` selects the Perl 5.44 feature
bundle while satisfying Perl::Critic's default version-notation policy.

| File | Responsibility |
| --- | --- |
| `lib/Epub/Horizontal.pm` | Convert, verify and publish one book; report failures safely |
| `lib/Epub/Horizontal/CLI.pm` | Options, batches, diagnostics and JSON reports |
| `lib/Epub/Horizontal/Book.pm` | Package, manifest, spine and stylesheet inspection |
| `lib/Epub/Horizontal/Text.pm` | Encoding-preserving direction transformations |
| `lib/Epub/Horizontal/Archive.pm` | Compression and ZIP/payload verification |
| `lib/Epub/Horizontal/Files.pm` | Literal Unicode paths, portable file operations and Windows arguments |

## Quality and parity checks

```text
# Read-only formatting/lint check.
perl tools/check-perl.pl

# Format using the checked-in profile, then check Perl::Critic.
perl tools/check-perl.pl --format

# Portable tests using Perl's core test harness.
perl -Ilocal/lib/perl5 -MTest::Harness -e "runtests(@ARGV)" -- t/01-text.t t/02-book-parity.t t/03-cli.t t/04-edge-cases.t
```

All **13 owned Perl files** pass `.perltidyrc` and `.perlcriticrc`. All default
severity-3-or-higher Perl::Critic policies remain enabled: no disabled policies
or inline lint waivers. CPAN dependencies and the vendored `tools/cpanm` are
not part of the owned-source formatting inventory.

The four test files pass **90 top-level tests/subtests**, including exact
payload and metadata comparisons against the 21 synthetic PowerShell fixture
outputs and exact-copy second passes. Additional checks cover Unicode/emoji
filesystem paths beyond 260 characters, Unicode ZIP member names, UTF-8/UTF-16
and cp932, malformed XML/ZIP, missing/duplicate resources, encrypted/signed
books, mixed fixed layouts, external entity rejection, dry runs, report and
output overwrite protection, and per-book failure isolation. Evidence stays
under uniquely named `test-results/perl-*` directories.

The final read-only gate and harness logs are saved as
`test-results/perl-quality-final.txt` and `test-results/perl-tests-final.txt`.

The final publisher regression also converts the two original publisher-toolkit
books with empty directories, checks that stderr is empty, and independently
compares all 146 entries. Native Windows Perl 5.44.0 was used for execution;
Linux/macOS runtime execution has not been performed in this workspace.

The retained PowerShell verifier can independently check a Perl report:

```powershell
.\Test-EpubCollection.ps1 -ReportPath .\perl-conversion-report.json -SummaryPath .\verification-summary-new.json
```

It does not load converter functions. It checks source/output hashes, entry
names/order/timestamps/attributes, every payload, allowed direction-only byte
changes, report accuracy, changed XML syntax, and the physical `mimetype` ZIP
header. Its substitution check targets the collection's ASCII-compatible byte
encodings; the Perl tests verify UTF-16 separately.

## Limits

This is a declaration converter, not a full browser CSS cascade or rendering
engine. Complex selector/cascade interactions, media queries, escaped CSS
identifiers, scripts and publisher-specific logic may need reader inspection.
Unsupported encodings, multiple package rootfiles, missing resources, malformed
XML, entity declarations, noncanonical ZIP names that Archive::Zip would
normalize, and signed/encrypted resources produce explicit errors instead of
incomplete outputs.

Lettering drawn into comic images cannot be changed by editing CSS. Fixed and
image-based books are preserved. The image-dominated heuristic can also preserve
a heavily illustrated text book; inspect its report reason when deciding
whether a different workflow is needed.

Horizontal flow naturally changes wrapping and pagination. Preserved physical
margins, dimensions and orientation classes can produce different spacing.
Byte/ZIP checks establish preservation and supported direction changes, not
full EPUBCheck conformance or visual perfection in every reader. Reader
rendering has not been visually verified.
