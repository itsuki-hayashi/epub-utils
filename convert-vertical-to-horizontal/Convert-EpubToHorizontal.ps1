#requires -Version 7.2
<#
.SYNOPSIS
Converts reflowable EPUB text to horizontal writing with minimal payload edits.
.DESCRIPTION
Discovers resources through container.xml and the OPF manifest. Horizontal,
fixed-layout and image-only books are copied byte-for-byte. Converted books use
.NET SmallestSize compression; mimetype is stored. No external modules required.
Originals and existing outputs are never replaced.
.EXAMPLE
.\Convert-EpubToHorizontal.ps1 -AnalyzeOnly
.EXAMPLE
.\Convert-EpubToHorizontal.ps1 -OutputDirectory .\horizontal-new -ReportPath .\conversion-report.json
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $InputPath = $PSScriptRoot,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'horizontal'),
    [switch] $AnalyzeOnly,
    [string] $ReportPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-EntryBytes($Entry) {
    $stream = $Entry.Open(); $buffer = [IO.MemoryStream]::new()
    try { $stream.CopyTo($buffer); return ,$buffer.ToArray() }
    finally { $stream.Dispose(); $buffer.Dispose() }
}
function Get-ByteHash([byte[]] $Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}
function Read-TextPayload([byte[]] $Bytes) {
    $encoding = [Text.UTF8Encoding]::new($false, $true); $offset = 0
    if ($Bytes.Length -ge 4 -and
        (($Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 254 -and $Bytes[3] -eq 255) -or
         ($Bytes[0] -eq 255 -and $Bytes[1] -eq 254 -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0))) {
        throw 'UTF-32 resources require manual review.'
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true); $offset = 2
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true); $offset = 2
    } elseif ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        $offset = 3
    } else {
        $prefix = [Text.Encoding]::ASCII.GetString($Bytes, 0, [Math]::Min(256, $Bytes.Length))
        if ($prefix -match '^\s*(?:<\?xml[^>]*encoding\s*=\s*["''](?<enc>[^"'']+)|@charset\s+["''](?<enc>[^"'']+))') {
            $encoding = [Text.Encoding]::GetEncoding($Matches.enc,
                [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
        }
    }
    $text = $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset)
    if ($text.Contains([char]0)) { throw 'Unsupported text encoding (embedded NUL).' }
    $prefixBytes = [byte[]]::new($offset)
    if ($offset) { [Array]::Copy($Bytes, $prefixBytes, $offset) }
    return @{ Text = $text; Encoding = $encoding; Prefix = $prefixBytes; Original = $Bytes }
}
function Write-TextPayload($Payload, [string] $Text) {
    if ($Text -ceq $Payload.Text) { return ,$Payload.Original }
    $roundTrip = [byte[]]($Payload.Prefix + $Payload.Encoding.GetBytes($Payload.Text))
    if ((Get-ByteHash $roundTrip) -cne (Get-ByteHash $Payload.Original)) { throw 'Resource encoding does not round-trip exactly.' }
    return ,([byte[]]($Payload.Prefix + $Payload.Encoding.GetBytes($Text)))
}
function Read-SafeXml([string] $Text) {
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore; $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new($Text), $settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null; $document.PreserveWhitespace = $true
        $document.Load($reader); return ,$document
    } finally { $reader.Dispose() }
}
function Resolve-EntryPath([string] $BasePath, [string] $Href) {
    $uri = [Uri]::new([Uri]::new('https://epub.invalid/' + $BasePath), $Href)
    if ($uri.Host -ne 'epub.invalid' -or $uri.Scheme -ne 'https' -or $uri.Query) { throw "Unsupported external/query resource: $Href" }
    return [Uri]::UnescapeDataString($uri.AbsolutePath.TrimStart('/'))
}

# Comments and strings are whole tokens: examples, content strings and commented
# declarations must not be mistaken for active CSS direction settings.
$cssSkip = '/\*[\s\S]*?\*/|"(?:\\[\s\S]|[^"\\])*"|''(?:\\[\s\S]|[^''\\])*'''
# Atomic trivia prevents a failed declaration match from reconsidering every
# combination of comment endings in large publisher stylesheets.
$cssGap = '(?>(?:\s+|/\*[\s\S]*?\*/)*)'
$cssDirection = [regex]::new('(?<prefix>(?<=\A|[;{])' + $cssGap + '(?<property>(?:-(?:webkit|epub|ms|moz)-)?writing-mode)' +
    $cssGap + ':' + $cssGap + ')(?<value>vertical-rl|vertical-lr|sideways-rl|sideways-lr|tb-rl|tb-lr)' +
    '(?=' + $cssGap + '(?:!' + $cssGap + 'important' + $cssGap + ')?(?:[;}]|$))|(?<skip>' + $cssSkip + ')',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase, [TimeSpan]::FromSeconds(10))
function Convert-CssDirection([string] $Text) {
    if ($Text.IndexOf('writing-mode', [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $Text }
    return $cssDirection.Replace($Text, [Text.RegularExpressions.MatchEvaluator]{ param($match)
        if ($match.Groups['skip'].Success) { return $match.Value }
        $value = 'horizontal-tb'
        if ($match.Groups['property'].Value -ieq '-ms-writing-mode' -or $match.Groups['value'].Value -imatch '^tb-') { $value = 'lr-tb' }
        return $match.Groups['prefix'].Value + $value
    })
}
function Convert-MarkupDirection([string] $Text) {
    if ($Text.IndexOf('writing-mode', [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $Text }
    $pattern = '(?<skip><!--[\s\S]*?-->|<(?:(?:\w+):)?script\b[^>]*>[\s\S]*?</(?:(?:\w+):)?script\s*>)|' +
        '(?<style><(?:(?:\w+):)?style\b[^>]*>)(?<css>[\s\S]*?)(?<end></(?:(?:\w+):)?style\s*>)|' +
        '(?<tag><[A-Za-z][^>"'']*(?:(?:"[^"]*"|''[^'']*'')[^>"'']*)*>)'
    return [regex]::Replace($Text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match)
        if ($match.Groups['skip'].Success) { return $match.Value }
        if ($match.Groups['style'].Success) {
            return $match.Groups['style'].Value + (Convert-CssDirection $match.Groups['css'].Value) + $match.Groups['end'].Value
        }
        return [regex]::Replace($match.Value,
            '(?<prefix>\s(?<name>style|writing-mode)\s*=\s*)(?<quote>["''])(?<value>[\s\S]*?)\k<quote>|(?<skip>"[^"]*"|''[^'']*'')',
            [Text.RegularExpressions.MatchEvaluator]{ param($attribute)
                if ($attribute.Groups['skip'].Success) { return $attribute.Value }
                $value = $attribute.Groups['value'].Value
                if ($attribute.Groups['name'].Value -ieq 'style') { $value = Convert-CssDirection $value }
                elseif ($value -imatch '^(vertical-rl|vertical-lr|sideways-rl|sideways-lr)$') { $value = 'horizontal-tb' }
                elseif ($value -imatch '^tb-(rl|lr)$') { $value = 'lr-tb' }
                return $attribute.Groups['prefix'].Value + $attribute.Groups['quote'].Value + $value + $attribute.Groups['quote'].Value
            }, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}
function Get-AttributeValue([string] $Tag, [string] $Name) {
    $match = [regex]::Match($Tag, '(?i)\s' + [regex]::Escape($Name) + '\s*=\s*(?<q>["''])(?<v>.*?)\k<q>')
    if ($match.Success) { return $match.Groups['v'].Value }; return ''
}
function Convert-PackageDirection([string] $Text) {
    return [regex]::Replace($Text, '<!--[\s\S]*?-->|<(?:(?:\w+):)?(?<kind>meta|spine)\b[^>]*>',
        [Text.RegularExpressions.MatchEvaluator]{ param($match)
            if (-not $match.Groups['kind'].Success) { return $match.Value }
            $tag = $match.Value
            if ($match.Groups['kind'].Value -ieq 'spine') {
                return [regex]::Replace($tag, '(?i)(\spage-progression-direction\s*=\s*["''])rtl(?=["''])', '${1}ltr')
            }
            if ((Get-AttributeValue $tag 'name') -ieq 'primary-writing-mode') {
                return [regex]::Replace($tag, '(?i)(\scontent\s*=\s*["''])(?:vertical-rl|vertical-lr|tb-rl|tb-lr)(?=["''])', '${1}horizontal-tb')
            }; return $tag
        }, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-EpubPlan($Archive) {
    $entries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Archive.Entries) {
        if (-not $entries.TryAdd($entry.FullName, $entry)) { throw "Duplicate ZIP entry: $($entry.FullName)" }
    }
    if (-not $entries.ContainsKey('META-INF/container.xml')) { throw 'Missing META-INF/container.xml.' }
    $container = Read-SafeXml (Read-TextPayload (Read-EntryBytes $entries['META-INF/container.xml'])).Text
    $roots = @($container.SelectNodes('//*[local-name()="rootfile"]'))
    if ($roots.Count -ne 1) { throw 'Multiple or missing package rootfiles require manual review.' }
    $packagePath = Resolve-EntryPath 'container.xml' $roots[0].GetAttribute('full-path')
    if (-not $entries.ContainsKey($packagePath)) { throw "Missing package: $packagePath" }
    $packagePayload = Read-TextPayload (Read-EntryBytes $entries[$packagePath])
    $package = Read-SafeXml $packagePayload.Text
    $patches = [Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
    $plan = @{ Kind = 'Preserved'; Reason = ''; Patches = $patches; PackagePath = $packagePath; HasText = $false }
    $fixed = @($package.SelectNodes('//*[local-name()="meta"]') | Where-Object {
        ($_.GetAttribute('property') -eq 'rendition:layout' -and $_.InnerText.Trim() -eq 'pre-paginated') -or
        ($_.GetAttribute('name') -eq 'fixed-layout' -and $_.GetAttribute('content') -eq 'true')
    })
    $fixedSpine = @($package.SelectNodes('//*[local-name()="itemref"]') | Where-Object {
        $_.GetAttribute('properties') -match '(^|\s)rendition:layout-pre-paginated(\s|$)'
    })
    if ($fixed.Count -or $fixedSpine.Count) { $plan.Reason = 'FixedLayout'; return $plan }
    $primaryVertical = @($package.SelectNodes('//*[local-name()="meta"]') | Where-Object {
        $_.GetAttribute('name') -eq 'primary-writing-mode' -and $_.GetAttribute('content') -match '^(vertical-(rl|lr)|tb-(rl|lr))$'
    }).Count -gt 0
    $manifest = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $resources = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($item in $package.SelectNodes('//*[local-name()="manifest"]/*[local-name()="item"]')) {
        $path = Resolve-EntryPath $packagePath $item.GetAttribute('href')
        if (-not $entries.ContainsKey($path)) { throw "Missing manifest resource: $path" }
        $id = $item.GetAttribute('id')
        if (-not $manifest.TryAdd($id, @{ Path = $path; Media = $item.GetAttribute('media-type') })) { throw "Duplicate manifest id: $id" }
        $resources[$path] = $item.GetAttribute('media-type')
    }
    $spine = @($package.SelectNodes('//*[local-name()="spine"]/*[local-name()="itemref"]'))
    if ($spine.Count -eq 0) { throw 'Empty or missing spine.' }
    $classes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $documents = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $linkedCss = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $inlineVertical = $false
    $imagePages = 0; $textPages = 0
    foreach ($ref in $spine) {
        $idref = $ref.GetAttribute('idref')
        if (-not $manifest.ContainsKey($idref)) { throw "Unknown spine idref: $idref" }
        $resource = $manifest[$idref]
        if ($resource.Media -notin @('application/xhtml+xml', 'image/svg+xml', 'text/html')) { continue }
        $path = $resource.Path
        if ($documents.ContainsKey($path)) { continue }
        $payload = Read-TextPayload (Read-EntryBytes $entries[$path])
        $document = Read-SafeXml $payload.Text
        $documents.Add($path, @{ Payload = $payload; Document = $document })
        if (-not $primaryVertical) {
            foreach ($node in $document.SelectNodes('//*[@class]')) {
                foreach ($class in ($node.GetAttribute('class') -split '\s+')) { if ($class) { [void]$classes.Add($class) } }
            }
            foreach ($node in $document.SelectNodes('//*[@id]')) { [void]$ids.Add($node.GetAttribute('id')) }
        }
        foreach ($node in $document.SelectNodes('//*[local-name()="link"][@href]')) {
            if ($node.GetAttribute('rel') -match '(^|\s)stylesheet(\s|$)') { [void]$linkedCss.Add((Resolve-EntryPath $path $node.GetAttribute('href'))) }
        }
        $hasVisibleText = $null -ne $document.SelectSingleNode('(//*[local-name()="body"]//text() | /*[local-name()="svg"]//text())[normalize-space(.) != "" and not(ancestor::*[local-name()="script" or local-name()="style" or local-name()="title" or local-name()="desc"])][1]')
        if ($hasVisibleText) { $plan.HasText = $true; $textPages++ }
        elseif ($null -ne $document.SelectSingleNode('//*[local-name()="img" or local-name()="image"]')) {
            $imagePages++
        }
        if ((Convert-MarkupDirection $payload.Text) -cne $payload.Text) { $inlineVertical = $true }
    }
    if (-not $plan.HasText) { $plan.Reason = 'ImageOnly'; return $plan }
    # A comic may have a few text credit pages without fixed-layout metadata.
    # Preserve image-dominated books rather than reversing their page turns.
    if ($imagePages -ge 10 -and $imagePages / ($imagePages + $textPages) -ge 0.8) {
        $plan.Reason = 'ImageDominated'; return $plan
    }
    $cssPayloads = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    # Follow linked CSS and @imports. Unlinked toolkits alone do not establish
    # vertical writing, nor does an unused .vrtl rule in a horizontal book.
    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($path in $linkedCss) { $queue.Enqueue($path) }
    $activeVertical = $false
    while ($queue.Count) {
        $path = $queue.Dequeue()
        if ($cssPayloads.ContainsKey($path)) { continue }
        if (-not $entries.ContainsKey($path)) { throw "Missing linked stylesheet: $path" }
        $payload = Read-TextPayload (Read-EntryBytes $entries[$path]); $cssPayloads.Add($path, $payload)
        $css = [regex]::Replace($payload.Text, '/\*[\s\S]*?\*/', '')
        $importPattern = '(?<skip>' + $cssSkip + ')|@import\s+(?:url\(\s*(?:["''](?<href>[^"'']+)["'']|(?<href>[^\s)"'']+))\s*\)|["''](?<href>[^"'']+)["''])'
        foreach ($import in [regex]::Matches($css, $importPattern, 'IgnoreCase')) {
            if ($import.Groups['href'].Success) { $queue.Enqueue((Resolve-EntryPath $path $import.Groups['href'].Value)) }
        }
        foreach ($rule in [regex]::Matches($css, '(?<selector>[^{}]+)\{(?<body>[^{}]*)\}')) {
            if ((Convert-CssDirection $rule.Groups['body'].Value) -ceq $rule.Groups['body'].Value) { continue }
            foreach ($selector in ($rule.Groups['selector'].Value -split ',')) {
                $used = $true
                foreach ($token in [regex]::Matches($selector, '(?<type>[.#])(?<name>[\w-]+)')) {
                    if ($token.Groups['type'].Value -eq '.' -and -not $classes.Contains($token.Groups['name'].Value)) { $used = $false }
                    if ($token.Groups['type'].Value -eq '#' -and -not $ids.Contains($token.Groups['name'].Value)) { $used = $false }
                }
                if ($used) { $activeVertical = $true }
            }
        }
    }
    if (-not ($primaryVertical -or $inlineVertical -or $activeVertical)) { $plan.Reason = 'Horizontal'; return $plan }
    if ($entries.ContainsKey('META-INF/signatures.xml') -or $entries.ContainsKey('META-INF/encryption.xml')) {
        throw 'Signed or encrypted EPUB requires manual review before modifying resources.'
    }
    # Keep orientation class names: publishers also use them for unrelated styles.
    foreach ($path in $resources.Keys) {
        $media = $resources[$path]
        if ($media -notin @('text/css', 'application/xhtml+xml', 'text/html', 'image/svg+xml')) { continue }
        if ($cssPayloads.ContainsKey($path)) { $payload = $cssPayloads[$path] }
        elseif ($documents.ContainsKey($path)) { $payload = $documents[$path].Payload }
        else { $payload = Read-TextPayload (Read-EntryBytes $entries[$path]) }
        if ($media -eq 'text/css') { $converted = Convert-CssDirection $payload.Text }
        else { $converted = Convert-MarkupDirection $payload.Text }
        if ($converted -cne $payload.Text) { $patches.Add($path, (Write-TextPayload $payload $converted)) }
    }
    # Imported CSS need not be in the manifest; retain and patch it as well.
    foreach ($path in $cssPayloads.Keys) {
        if ($resources.ContainsKey($path)) { continue }
        $payload = $cssPayloads[$path]; $converted = Convert-CssDirection $payload.Text
        if ($converted -cne $payload.Text) { $patches.Add($path, (Write-TextPayload $payload $converted)) }
    }
    $packageText = Convert-PackageDirection $packagePayload.Text
    if ($packageText -cne $packagePayload.Text) { $patches.Add($packagePath, (Write-TextPayload $packagePayload $packageText)) }
    if ($patches.Count -eq 0) { throw 'Vertical evidence found but no supported direction setting could be changed.' }
    $plan.Kind = 'Converted'; $plan.Reason = 'VerticalText'; return $plan
}

function Write-ConvertedEpub($Archive, $Plan, [string] $Temporary) {
    if ($Archive.Entries[0].FullName -cne 'mimetype' -or
        [Text.Encoding]::ASCII.GetString((Read-EntryBytes $Archive.GetEntry('mimetype'))) -cne 'application/epub+zip') {
        throw 'Invalid EPUB mimetype entry; no output published.'
    }
    $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $target = [IO.Compression.ZipFile]::Open($Temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $Archive.Entries) {
            if ($Plan.Patches.ContainsKey($entry.FullName)) { $bytes = $Plan.Patches[$entry.FullName] }
            else { $bytes = Read-EntryBytes $entry }
            $expected.Add($entry.FullName, (Get-ByteHash $bytes))
            $compression = [IO.Compression.CompressionLevel]::SmallestSize
            if ($entry.FullName -ceq 'mimetype') { $compression = [IO.Compression.CompressionLevel]::NoCompression }
            $newEntry = $target.CreateEntry($entry.FullName, $compression)
            $newEntry.LastWriteTime = $entry.LastWriteTime; $newEntry.ExternalAttributes = $entry.ExternalAttributes
            $stream = $newEntry.Open()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
    } finally { $target.Dispose() }
    $check = [IO.Compression.ZipFile]::OpenRead($Temporary)
    try {
        if ($check.Entries.Count -ne $Archive.Entries.Count) { throw 'Verification failed: entry count changed.' }
        for ($i = 0; $i -lt $check.Entries.Count; $i++) {
            $entry = $check.Entries[$i]; $original = $Archive.Entries[$i]
            if ($entry.FullName -cne $original.FullName -or $entry.LastWriteTime -ne $original.LastWriteTime -or
                $entry.ExternalAttributes -ne $original.ExternalAttributes -or
                (Get-ByteHash (Read-EntryBytes $entry)) -cne $expected[$entry.FullName]) { throw "Verification failed: $($entry.FullName)" }
        }
    } finally { $check.Dispose() }
    $stream = [IO.File]::OpenRead($Temporary)
    try {
        $header = [byte[]]::new(30)
        if ($stream.Read($header, 0, 30) -ne 30 -or [BitConverter]::ToUInt32($header, 0) -ne 0x04034b50 -or
            [BitConverter]::ToUInt16($header, 6) -ne 0 -or [BitConverter]::ToUInt16($header, 8) -ne 0 -or
            [BitConverter]::ToUInt16($header, 28) -ne 0) { throw 'Invalid EPUB mimetype ZIP header.' }
    } finally { $stream.Dispose() }
}

$inputItem = Get-Item -LiteralPath $InputPath
if ($inputItem.PSIsContainer) { $books = @(Get-ChildItem -LiteralPath $inputItem.FullName -File -Filter '*.epub' | Sort-Object Name) }
elseif ($inputItem.Extension -ieq '.epub') { $books = @($inputItem) }
else { throw 'InputPath must be an EPUB file or a directory containing EPUB files.' }
if ($books.Count -eq 0) { throw 'No EPUB files found.' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$results = [Collections.Generic.List[object]]::new(); $failures = 0
foreach ($book in $books) {
    $destination = Join-Path $outputRoot $book.Name; $source = $null; $temporary = $null
    $result = [ordered]@{ Book = $book.Name; Status = ''; Reason = ''; ChangedEntries = @(); EntriesVerified = 0;
        InputBytes = $book.Length; OutputBytes = $null; InputSHA256 = ''; OutputSHA256 = ''; Output = $destination; Error = '' }
    try {
        Write-Verbose "Inspecting $($book.Name)"
        $source = [IO.Compression.ZipFile]::OpenRead($book.FullName); $plan = Get-EpubPlan $source
        $result.Reason = $plan.Reason; $result.ChangedEntries = @($plan.Patches.Keys | Sort-Object)
        if ($AnalyzeOnly) { $result.Status = 'Analyzed' }
        else {
            if ([IO.File]::Exists($destination)) { throw "Refusing to overwrite: $destination" }
            if ($PSCmdlet.ShouldProcess($destination, "$($plan.Kind) EPUB ($($plan.Reason))")) {
                [void][IO.Directory]::CreateDirectory($outputRoot)
                $temporary = Join-Path $outputRoot ([Guid]::NewGuid().ToString('N') + '.tmp')
                $result.InputSHA256 = (Get-FileHash -LiteralPath $book.FullName -Algorithm SHA256).Hash
                if ($plan.Kind -eq 'Preserved') {
                    [IO.File]::Copy($book.FullName, $temporary)
                    if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -cne $result.InputSHA256) { throw 'Exact-copy verification failed.' }
                } else { Write-ConvertedEpub $source $plan $temporary }
                $result.OutputSHA256 = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
                $result.OutputBytes = ([IO.FileInfo]::new($temporary)).Length
                [IO.File]::Move($temporary, $destination)
                $result.Status = $plan.Kind; $result.EntriesVerified = $source.Entries.Count
            } else { $result.Status = 'WhatIf' }
        }
    } catch {
        $failures++; $result.Status = 'Error'; $result.Error = $_.Exception.Message
        Write-Warning "$($book.Name): $($result.Error)"
    } finally {
        if ($null -ne $source) { $source.Dispose() }
        if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    $record = [pscustomobject]$result; $results.Add($record); Write-Output $record
}
if ($ReportPath -and $PSCmdlet.ShouldProcess($ReportPath, 'Write JSON verification report')) {
    $reportFullPath = [IO.Path]::GetFullPath($ReportPath)
    if ([IO.File]::Exists($reportFullPath)) { throw "Refusing to overwrite report: $reportFullPath" }
    $results.ToArray() | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportFullPath -Encoding utf8NoBOM
}
if ($failures) { throw "$failures EPUB(s) failed; see per-book errors. Other books were processed independently." }
