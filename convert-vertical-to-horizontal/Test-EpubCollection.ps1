#requires -Version 7.2
<# Independent archive/payload comparison; does not load the converter functions. #>
[CmdletBinding()]
param(
    [string] $InputDirectory = $PSScriptRoot,
    [string] $ReportPath = (Join-Path $PSScriptRoot 'conversion-report.json'),
    [string] $SummaryPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (-not ('EpubAllowedEditVerifier' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
public static class EpubAllowedEditVerifier {
    static readonly string[,] Pairs = {
        {"vertical-rl", "horizontal-tb"}, {"vertical-lr", "horizontal-tb"},
        {"sideways-rl", "horizontal-tb"}, {"sideways-lr", "horizontal-tb"},
        {"tb-rl", "lr-tb"}, {"tb-lr", "lr-tb"}, {"rtl", "ltr"}
    };
    static bool At(byte[] data, int offset, string token) {
        if (offset + token.Length > data.Length) return false;
        for (int i = 0; i < token.Length; i++)
            if (char.ToLowerInvariant((char)data[offset+i]) != token[i]) return false;
        return true;
    }
    public static int Compare(byte[] before, byte[] after, bool package) {
        int a = 0, b = 0, edits = 0;
        while (a < before.Length && b < after.Length) {
            if (before[a] == after[b]) { a++; b++; continue; }
            bool matched = false;
            for (int k = 0; k < Pairs.GetLength(0); k++) {
                if (!package && Pairs[k,0] == "rtl") continue;
                if (At(before, a, Pairs[k,0]) && At(after, b, Pairs[k,1])) {
                    a += Pairs[k,0].Length; b += Pairs[k,1].Length;
                    edits++; matched = true; break;
                }
            }
            if (!matched) throw new Exception("Unexpected byte difference at source offset " + a);
        }
        if (a != before.Length || b != after.Length) throw new Exception("Unexpected trailing bytes");
        return edits;
    }
}
'@
}
function EntryBytes($Entry) {
    $s = $Entry.Open(); $m = [IO.MemoryStream]::new()
    try { $s.CopyTo($m); return ,$m.ToArray() } finally { $s.Dispose(); $m.Dispose() }
}
function Hash([byte[]] $Data) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Data)) }
$report = @(Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json)
$books = @(Get-ChildItem -LiteralPath $InputDirectory -File -Filter '*.epub')
if ($report.Count -ne $books.Count) { throw "Report covers $($report.Count) files; input contains $($books.Count)." }
$total = 0; $identical = 0; $changed = 0; $edits = 0; $preserved = 0; $converted = 0
[long]$inputBytes = 0; [long]$outputBytes = 0
foreach ($record in $report) {
    if ($record.Status -notin @('Preserved','Converted')) { throw "Unsuccessful result: $($record.Book)" }
    $originalPath = Join-Path $InputDirectory $record.Book
    if ((Get-FileHash -LiteralPath $originalPath).Hash -cne $record.InputSHA256) { throw "Source hash changed: $($record.Book)" }
    if ((Get-FileHash -LiteralPath $record.Output).Hash -cne $record.OutputSHA256) { throw "Output hash changed: $($record.Book)" }
    $inputBytes += (Get-Item -LiteralPath $originalPath).Length
    $outputBytes += (Get-Item -LiteralPath $record.Output).Length
    if ($record.Status -eq 'Preserved') {
        if ($record.InputSHA256 -cne $record.OutputSHA256) { throw "Preserved book changed: $($record.Book)" }
        $preserved++
    } else { $converted++ }
    $a = [IO.Compression.ZipFile]::OpenRead($originalPath)
    $b = [IO.Compression.ZipFile]::OpenRead($record.Output)
    try {
        if ($a.Entries.Count -ne $b.Entries.Count) { throw 'Entry count mismatch.' }
        $actualChanged = [Collections.Generic.List[string]]::new()
        for ($i=0; $i -lt $a.Entries.Count; $i++) {
            $x = $a.Entries[$i]; $y = $b.Entries[$i]
            if ($x.FullName -cne $y.FullName -or $x.LastWriteTime -ne $y.LastWriteTime -or
                $x.ExternalAttributes -ne $y.ExternalAttributes) { throw "Entry metadata changed: $($record.Book) / $($x.FullName)" }
            $before = EntryBytes $x; $after = EntryBytes $y; $total++
            if ((Hash $before) -ceq (Hash $after)) { $identical++; continue }
            if ($record.Status -ne 'Converted' -or $x.FullName -notmatch '\.(css|opf|xhtml|html|svg)$') { throw "Unexpected changed entry: $($x.FullName)" }
            $edits += [EpubAllowedEditVerifier]::Compare($before, $after, ($x.FullName -match '\.opf$'))
            $actualChanged.Add($x.FullName); $changed++
            if ($x.FullName -match '\.(opf|xhtml|svg)$') {
                $reader = [IO.StreamReader]::new($y.Open())
                try { [void]([xml]$reader.ReadToEnd()) } finally { $reader.Dispose() }
            }
        }
        if ((($actualChanged.ToArray() | Sort-Object) -join "`n") -cne (($record.ChangedEntries | Sort-Object) -join "`n")) {
            throw "Changed-entry report mismatch: $($record.Book)"
        }
    } finally { $a.Dispose(); $b.Dispose() }
    if ($record.Status -eq 'Converted') {
        $stream = [IO.File]::OpenRead($record.Output)
        try {
            $header = [byte[]]::new(30); [void]$stream.Read($header,0,30)
            if ([BitConverter]::ToUInt32($header,0) -ne 0x04034b50 -or
                [BitConverter]::ToUInt16($header,6) -ne 0 -or [BitConverter]::ToUInt16($header,8) -ne 0 -or
                [BitConverter]::ToUInt16($header,28) -ne 0) { throw 'Invalid mimetype ZIP header.' }
        } finally { $stream.Dispose() }
    }
}
$summary = [pscustomobject]@{ Books = $report.Count; Converted = $converted; PreservedExactly = $preserved;
    EntriesCompared = $total; IdenticalPayloads = $identical; DirectionOnlyPayloads = $changed; DirectionSubstitutions = $edits;
    InputBytes = $inputBytes; OutputBytes = $outputBytes; BytesSaved = $inputBytes - $outputBytes }
if ($SummaryPath) { $summary | ConvertTo-Json | Set-Content -LiteralPath $SummaryPath -Encoding utf8NoBOM }
$summary
