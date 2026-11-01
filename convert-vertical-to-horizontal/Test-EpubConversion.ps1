#requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$converter = Join-Path $PSScriptRoot 'Convert-EpubToHorizontal.ps1'
$testRoot = Join-Path $PSScriptRoot ('test-results/fixtures-' + [Guid]::NewGuid().ToString('N'))
$inputRoot = Join-Path $testRoot 'input'
$outputRoot = Join-Path $testRoot 'output'
[void][IO.Directory]::CreateDirectory($inputRoot)
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$cases = [Collections.Generic.List[object]]::new()
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Bytes([string] $Text) { return ,$utf8.GetBytes($Text) }
function EntryBytes($Entry) {
    $s = $Entry.Open(); $m = [IO.MemoryStream]::new()
    try { $s.CopyTo($m); return ,$m.ToArray() } finally { $s.Dispose(); $m.Dispose() }
}
function Hash([byte[]] $Data) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Data)) }
function Add-Case([string] $Name, [string] $Css, [string] $Body = '<p>日本語と English text.</p>',
    [string] $Meta = '', [string] $Reason = 'VerticalText', [hashtable] $Extra = @{},
    [hashtable] $Expected = @{}, [string] $Head = '', [string] $HtmlClass = '', [switch] $Utf16,
    [int] $ImagePages = 0) {
    $cssBytes = Bytes $Css
    if ($Utf16) { $cssBytes = [byte[]]([Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes($Css)) }
    $package = '<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata>' +
        $Meta + '</metadata><manifest><item id="page" href="text/page.xhtml" media-type="application/xhtml+xml"/>' +
        '<item id="css" href="styles/main.css" media-type="text/css"/></manifest><spine page-progression-direction=''rtl''><itemref idref="page"/></spine></package>'
    $page = '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" class="' + $HtmlClass + '"><head>' +
        '<link rel="stylesheet" href="../styles/main.css"/>' + $Head + '</head><body>' + $Body + '</body></html>'
    for ($i = 0; $i -lt $ImagePages; $i++) {
        $package = $package.Replace('</manifest>', '<item id="image' + $i + '" href="text/image' + $i + '.xhtml" media-type="application/xhtml+xml"/></manifest>')
        $package = $package.Replace('</spine>', '<itemref idref="image' + $i + '"/></spine>')
        $Extra['OPS/text/image' + $i + '.xhtml'] = Bytes '<html xmlns="http://www.w3.org/1999/xhtml"><head/><body><img src="../image.bin"/></body></html>'
    }
    $contents = [ordered]@{
        mimetype = (Bytes 'application/epub+zip')
        'META-INF/container.xml' = (Bytes '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        'OPS/package.opf' = (Bytes $package)
        'OPS/styles/main.css' = $cssBytes
        'OPS/text/page.xhtml' = (Bytes $page)
        'OPS/image.bin' = [byte[]](0,1,2,3,128,254,255)
        'unlisted.txt' = (Bytes 'writing-mode: vertical-rl; not a stylesheet')
    }
    foreach ($key in $Extra.Keys) { $contents[$key] = $Extra[$key] }
    $expectedContents = @{}
    foreach ($key in $contents.Keys) { $expectedContents[$key] = $contents[$key] }
    foreach ($key in $Expected.Keys) {
        if ($Expected[$key] -is [byte[]]) { $expectedContents[$key] = $Expected[$key] }
        else { $expectedContents[$key] = Bytes $Expected[$key] }
    }
    if ($Reason -eq 'VerticalText') {
        $expectedContents['OPS/package.opf'] = Bytes ($package.Replace("page-progression-direction='rtl'", "page-progression-direction='ltr'").Replace('content="vertical-rl"','content="horizontal-tb"'))
    }
    $path = Join-Path $inputRoot ($Name + '.epub')
    $z = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($key in $contents.Keys) {
            $level = [IO.Compression.CompressionLevel]::Optimal
            if ($key -eq 'mimetype') { $level = [IO.Compression.CompressionLevel]::NoCompression }
            $e = $z.CreateEntry($key, $level); $e.LastWriteTime = [DateTimeOffset]::new(2020,1,2,3,4,6,[TimeSpan]::Zero)
            $e.ExternalAttributes = 32; $s = $e.Open()
            try { $s.Write($contents[$key], 0, $contents[$key].Length) } finally { $s.Dispose() }
        }
    } finally { $z.Dispose() }
    $cases.Add(@{ Path = $path; Reason = $Reason; Expected = $expectedContents })
}

Add-Case 'horizontal English [literal]' 'body {writing-mode: horizontal-tb}' -Reason Horizontal
Add-Case 'horizontal RTL Arabic' 'body {direction: rtl}' -Body '<p>مرحبا بالعالم</p>' -Reason Horizontal
Add-Case 'horizontal unused vertical toolkit' '.vrtl {writing-mode:vertical-rl} .hltr {writing-mode:horizontal-tb}' -HtmlClass hltr -Reason Horizontal
Add-Case 'horizontal commented and quoted examples' '/* body {writing-mode:vertical-rl} */ body {content:"writing-mode:vertical-rl"}' -Reason Horizontal
Add-Case 'horizontal CSS custom property example' 'body {--example: writing-mode:vertical-rl;}' -Reason Horizontal
Add-Case 'horizontal quoted HTML attribute example' '' -Body '<p title="example style=''writing-mode:vertical-rl''">English text</p>' -Reason Horizontal
Add-Case 'fixed layout comic' 'body {writing-mode:vertical-rl}' -Meta '<meta property="rendition:layout">pre-paginated</meta>' -Reason FixedLayout
Add-Case 'EPUB2 fixed layout comic' 'body {writing-mode:vertical-rl}' -Meta '<meta name="fixed-layout" content="true"/>' -Reason FixedLayout
Add-Case 'image only comic' 'body {writing-mode:vertical-rl}' -Body '<img src="../image.bin" alt="縦書き writing-mode:vertical-rl"/>' -Meta '<meta name="primary-writing-mode" content="vertical-rl"/>' -Reason ImageOnly
Add-Case 'SVG image comic' 'body {writing-mode:vertical-rl}' -Body '<svg xmlns="http://www.w3.org/2000/svg"><image href="../image.bin"/></svg>' -Reason ImageOnly
Add-Case 'SVG image comic accessible title' 'body {writing-mode:vertical-rl}' -Body '<svg xmlns="http://www.w3.org/2000/svg"><title>Accessible description</title><desc>A comic page</desc><image href="../image.bin"/></svg>' -Reason ImageOnly
Add-Case 'image comic with text credits' 'body {writing-mode:vertical-rl}' -Body '<p>Credits</p>' -ImagePages 10 -Reason ImageDominated
$css = "/* writing-mode:vertical-lr; */`r`nbody { -webkit-writing-mode: vertical-rl; -epub-writing-mode: vertical-lr; writing-mode /*keep*/ : sideways-rl !important; -ms-writing-mode:tb-rl; color:red; content:'writing-mode:vertical-rl'; }"
$expectedCss = $css.Replace('-webkit-writing-mode: vertical-rl','-webkit-writing-mode: horizontal-tb').Replace('-epub-writing-mode: vertical-lr','-epub-writing-mode: horizontal-tb').Replace('writing-mode /*keep*/ : sideways-rl','writing-mode /*keep*/ : horizontal-tb').Replace('-ms-writing-mode:tb-rl','-ms-writing-mode:lr-tb')
Add-Case 'vertical CSS variants' $css -Expected @{'OPS/styles/main.css'=$expectedCss}
$manyComments = ('/* publisher comment */' + "`n") * 200
Add-Case 'vertical many stylesheet comments' ($manyComments + 'body {writing-mode:vertical-rl}') -Expected @{'OPS/styles/main.css'=($manyComments + 'body {writing-mode:horizontal-tb}')}
Add-Case 'vertical primary metadata' '' -Meta '<meta content="vertical-rl" name="primary-writing-mode"/>'
Add-Case 'vertical imported class toolkit' '@import url(extra.css);' -HtmlClass vrtl -Extra @{'OPS/styles/extra.css'=(Bytes '.vrtl {writing-mode:vertical-rl}')} -Expected @{'OPS/styles/extra.css'='.vrtl {writing-mode:horizontal-tb}'}
$uCss = 'body {writing-mode:vertical-rl} /* 日本語 */'
$uExpected = [byte[]]([Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes($uCss.Replace('vertical-rl','horizontal-tb')))
Add-Case 'vertical UTF16 CSS' $uCss -Utf16 -Expected @{'OPS/styles/main.css'=$uExpected}
$bom = [byte[]]([byte[]](239,187,191) + (Bytes '.vrtl {writing-mode:vertical-rl}'))
$bomExpected = [byte[]]([byte[]](239,187,191) + (Bytes '.vrtl {writing-mode:horizontal-tb}'))
Add-Case 'vertical UTF8 BOM import' '@import "bom.css";' -HtmlClass vrtl -Extra @{'OPS/styles/bom.css'=$bom} -Expected @{'OPS/styles/bom.css'=$bomExpected}
# Establish inline support without deriving the expected output from converter code.
Add-Case 'inline vertical' '' -Body '<p style="writing-mode:vertical-rl">日本語</p>'
$case = $cases[$cases.Count-1]
$originalPage = $utf8.GetString($case.Expected['OPS/text/page.xhtml'])
$case.Expected['OPS/text/page.xhtml'] = Bytes ($originalPage.Replace('style="writing-mode:vertical-rl"','style="writing-mode:horizontal-tb"'))
Add-Case 'embedded style and literal text' '' -Head '<style>body {writing-mode: vertical-lr}</style><script>var example="writing-mode:vertical-rl";</script>' -Body '<p>Literal writing-mode:vertical-rl; stays.</p><!-- style="writing-mode:vertical-rl" -->'
$case = $cases[$cases.Count-1]
$case.Expected['OPS/text/page.xhtml'] = Bytes ($utf8.GetString($case.Expected['OPS/text/page.xhtml']).Replace('body {writing-mode: vertical-lr}','body {writing-mode: horizontal-tb}'))
Add-Case 'SVG live vertical text attribute' '' -Body '<svg xmlns="http://www.w3.org/2000/svg"><text writing-mode="vertical-rl">日本語</text></svg>'
$case = $cases[$cases.Count-1]
$case.Expected['OPS/text/page.xhtml'] = Bytes ($utf8.GetString($case.Expected['OPS/text/page.xhtml']).Replace('writing-mode="vertical-rl"','writing-mode="horizontal-tb"'))

$originalHashes = @{}
foreach ($case in $cases) { $originalHashes[$case.Path] = (Get-FileHash -LiteralPath $case.Path).Hash }
$results = @(& $converter -InputPath $inputRoot -OutputDirectory $outputRoot -ReportPath (Join-Path $testRoot 'report.json'))
Assert ($results.Count -eq $cases.Count) 'Missing fixture results.'
$verified = 0
foreach ($case in $cases) {
    $name = [IO.Path]::GetFileName($case.Path)
    $result = $results | Where-Object Book -CEQ $name
    Assert ($result.Reason -ceq $case.Reason) "Incorrect classification: $name ($($result.Reason))"
    $output = Join-Path $outputRoot $name
    Assert ((Get-FileHash -LiteralPath $case.Path).Hash -ceq $originalHashes[$case.Path]) "Original changed: $name"
    if ($case.Reason -ne 'VerticalText') { Assert ((Get-FileHash -LiteralPath $output).Hash -ceq $originalHashes[$case.Path]) "Preserved archive changed: $name" }
    $z = [IO.Compression.ZipFile]::OpenRead($output)
    try {
        Assert ($z.Entries.Count -eq $case.Expected.Count) "Entry count changed: $name"
        foreach ($e in $z.Entries) {
            Assert ((Hash (EntryBytes $e)) -ceq (Hash $case.Expected[$e.FullName])) "Unexpected payload change: $name / $($e.FullName)"
            $verified++
        }
    } finally { $z.Dispose() }
}
# A second conversion must be a byte-identical copy (idempotence), even when the
# stylesheet retains unused/commented vertical vocabulary and orientation names.
$secondRoot = Join-Path $testRoot 'second'
$second = @(& $converter -InputPath $outputRoot -OutputDirectory $secondRoot)
foreach ($result in $second) {
    Assert ($result.Status -eq 'Preserved') "Second pass attempted conversion: $($result.Book)"
    Assert ($result.InputSHA256 -ceq $result.OutputSHA256) "Second pass archive changed: $($result.Book)"
}
# WhatIf has no filesystem side effects; overwrite attempts must fail safely.
$preview = Join-Path $testRoot 'preview'
& $converter -InputPath $cases[0].Path -OutputDirectory $preview -WhatIf | Out-Null
Assert (-not (Test-Path -LiteralPath $preview)) 'WhatIf created an output directory.'
$caught = $false
try { & $converter -InputPath $cases[0].Path -OutputDirectory $outputRoot -WarningAction SilentlyContinue | Out-Null } catch { $caught = $true }
Assert $caught 'Existing output was overwritten.'
# An invalid EPUB must not prevent a later valid book from completing, and must
# leave no temporary or falsely successful output behind.
$mixedInput = Join-Path $testRoot 'mixed-input'; $mixedOutput = Join-Path $testRoot 'mixed-output'
[void][IO.Directory]::CreateDirectory($mixedInput)
[IO.File]::WriteAllText((Join-Path $mixedInput 'a-invalid.epub'), 'Not a ZIP archive')
[IO.File]::Copy($cases[0].Path, (Join-Path $mixedInput 'z-valid.epub'))
$caught = $false
try { & $converter -InputPath $mixedInput -OutputDirectory $mixedOutput -ReportPath (Join-Path $testRoot 'mixed-report.json') -WarningAction SilentlyContinue | Out-Null } catch { $caught = $true }
Assert $caught 'Invalid ZIP was silently accepted.'
Assert (Test-Path -LiteralPath (Join-Path $mixedOutput 'z-valid.epub')) 'A failed book prevented subsequent conversion.'
Assert (-not (Test-Path -LiteralPath (Join-Path $mixedOutput 'a-invalid.epub'))) 'Invalid ZIP produced an output.'
Assert (@(Get-ChildItem -LiteralPath $mixedOutput -Filter '*.tmp').Count -eq 0) 'Temporary output leaked.'
[pscustomobject]@{ FixturesPassed = $cases.Count; PayloadsCompared = $verified; IdempotencePassed = $second.Count; EvidenceDirectory = $testRoot }
