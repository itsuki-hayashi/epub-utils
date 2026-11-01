# Horizontal EPUB conversion

`Convert-EpubToHorizontal.ps1` inspects EPUB writing direction and converts
reflowable vertical text using PowerShell 7.2 or later and built-in .NET ZIP
support. No Perl or external modules are required. Originals are never edited.

The expanded collection contains **276 EPUBs**. The latest outputs are in
`horizontal-verified/`; the earlier ten outputs remain in `horizontal/`.
See `conversion-report.json` for per-book results, changed entry names, file
hashes, sizes, and verification counts. `verification-summary.json` contains
the independent collection comparison totals.

The completed run converted 273 vertical books and preserved three horizontal
English books as exact file copies. All 21,122 archive entries were compared:
20,576 payloads were identical and 546 contained only direction substitutions
(one stylesheet and one package file per converted book). A second inspection
classified all 276 outputs as horizontal, with no further patches. The 21
generated fixture cases also passed, including exact-copy second conversions.
No fixed-layout or image-only books were detected in this collection.

## Usage

```powershell
# Inspect all EPUBs beside the script without creating output books.
.\Convert-EpubToHorizontal.ps1 -AnalyzeOnly

# Convert/copy every book into a fresh directory, recording a JSON report.
.\Convert-EpubToHorizontal.ps1 -OutputDirectory .\horizontal-new -ReportPath .\new-report.json

# Process one book (literal paths support brackets and Japanese filenames).
.\Convert-EpubToHorizontal.ps1 -InputPath '.\book.epub' -OutputDirectory .\one-output

# Preview without creating directories, books, or reports.
.\Convert-EpubToHorizontal.ps1 -OutputDirectory .\preview -WhatIf
```

Directory input is nonrecursive. Existing output files and reports are never
overwritten. Use a fresh directory for another run. A bad book produces a
warning and an `Error` result; the remaining books are processed, the report is
written, and the script fails at the end if any books failed.

## Preservation and compression

| Detected layout | Action |
| --- | --- |
| Horizontal text, including right-to-left horizontal languages | Exact file copy, verified by SHA-256 |
| Fixed layout, including fixed-layout comics | Exact file copy |
| Image-only spine documents | Exact file copy |
| At least ten image-only pages forming 80% or more of image/text spine documents | Exact file copy; reported as `ImageDominated` |
| Reflowable vertical text | Patch direction settings, repack, verify every entry |

An exact copy preserves the entire original ZIP file, including its compression
and archive metadata. Such books are **not recompressed**: recompression would
conflict with keeping them exactly unchanged. Converted books use
`CompressionLevel.SmallestSize`, the strongest compression setting exposed by
the built-in .NET API, for every entry except `mimetype`, which EPUB requires
to be stored uncompressed. This is not a guarantee of the smallest archive
achievable by every external ZIP optimizer.

## Layout handling and minimal edits

Package paths are discovered through `META-INF/container.xml`; manifest paths
are resolved relative to the package, including nested directories and URL
escapes. Linked CSS and CSS imports are inspected. The collection includes
both `OEBPS/content.opf` layouts and `item/standard.opf` layouts with a linked
publisher CSS toolkit.

Vertical direction evidence comes from package writing-mode metadata, inline
styles/SVG writing-mode attributes, and linked CSS rules whose class/id names
occur in spine documents. Unused class rules, commented rules, and unlinked
vertical toolkits alone do not trigger conversion.

For a converted book, the supported changes are:

- Standard, WebKit, EPUB, Mozilla, and Microsoft CSS writing-mode declarations:
  `vertical-rl`, `vertical-lr`, and sideways modes become `horizontal-tb`.
- Legacy `tb-rl`/`tb-lr` modes become `lr-tb`; Microsoft declarations use
  `lr-tb` for horizontal writing.
- Inline style elements/attributes and SVG writing-mode attributes receive
  corresponding direction changes.
- Existing `primary-writing-mode` metadata becomes `horizontal-tb`.
- Existing spine `page-progression-direction="rtl"` becomes `ltr` only when
  the book is being converted. Horizontal RTL books and comic page order stay
  unchanged.

Comments, CSS string literals, ordinary prose, scripts, and unrelated attributes
are not replacement targets. Orientation class names such as `vrtl` remain
unchanged because publisher styles also use them for unrelated formatting.
Text, ruby, fonts, images, navigation, physical margins, dimensions, and other
CSS remain unchanged. XML is parsed for inspection but never reserialized.
Encoding, BOMs, whitespace, and line endings are preserved; changed text must
round-trip through its original encoding exactly.

Converted ZIPs retain entry names, order, timestamps, external attributes, and
all unedited entry payloads. Compression and archive-level ZIP metadata are
regenerated. Temporary outputs are read back and checked entry by entry before
the final EPUB filename is published. Failed temporary outputs are removed.

## Tests

```powershell
# Self-contained fixtures, exact expected bytes, repeat-conversion checks,
# WhatIf/overwrite protection, and per-book failure isolation.
.\Test-EpubConversion.ps1

# Independent comparison of the actual collection using a conversion report.
.\Test-EpubCollection.ps1 -ReportPath .\conversion-report.json -SummaryPath .\verification-summary-new.json

# Verify that converted outputs no longer request supported vertical writing.
.\Convert-EpubToHorizontal.ps1 -InputPath .\horizontal-verified -AnalyzeOnly
```

The actual second-pass results are saved in
`test-results/second-pass-analysis.json`. The collection totals were
2,899,514,565 input bytes and 2,897,682,163 output bytes (1,832,402 bytes saved);
already-compressed images remain byte-identical and dominate these archives.

Fixture evidence is retained in a unique directory under `test-results/`.
The fixture verifier compares exact expected payload bytes, including UTF-8 BOM
and UTF-16 resources, and verifies that a second conversion is an exact copy.
Comic preservation is tested with generated fixed-layout, image-only, and
image-dominated examples; classification is a layout safeguard, not a semantic
determination of a book's genre.

The independent collection verifier does not load converter functions. It
compares file hashes, every ZIP entry's name/order/timestamp/attributes, every
payload, the allowed direction-only byte substitutions, changed-entry report
accuracy, changed XML syntax, and the physical `mimetype` ZIP header. Its
direction-substitution checker targets the ASCII-compatible encodings used by
this collection; the fixture suite checks UTF-16 separately.

## Limits

There is no universal guarantee of perfect visual conversion for arbitrary
EPUBs. This is a declaration converter, not a complete browser CSS cascade or
rendering engine. Complex selector/cascade interactions, media queries,
escaped CSS identifiers, scripts, and publisher-specific layout logic may need
manual inspection. Unsupported encodings, multiple package rootfiles,
missing resources, malformed XML, and signed/encrypted resources produce
explicit errors rather than incomplete output.

Lettering drawn into comic images cannot be changed by editing CSS. Fixed or
image-based layouts are deliberately preserved. Mixed fixed/reflowable books
are also preserved when a spine item declares a fixed layout. The
image-dominated heuristic may preserve a heavily illustrated text book; inspect
its report reason before deciding whether it needs a different workflow.

Horizontal flow naturally changes wrapping and pagination. Preserving physical
margins, dimensions, and publisher orientation classes can produce different
spacing. Automated byte/ZIP checks establish preservation and supported
direction changes, not full EPUBCheck conformance or visual perfection in every
reader. Reader rendering has not been visually verified.
