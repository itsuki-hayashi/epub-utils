param(
    [Parameter(Mandatory)][string]$AdaExecutable,
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ReferenceReport,
    [Parameter(Mandatory)][string]$OutputRoot
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if ($OutputRoot -eq $repository -or $OutputRoot.StartsWith($repository + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Keep private performance artifacts outside the repository.'
}
$directory = Join-Path $OutputRoot ('frozen-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
$AdaExecutable = [IO.Path]::GetFullPath($AdaExecutable)
$identity = (Get-FileHash -LiteralPath $AdaExecutable).Hash
Copy-Item -LiteralPath $AdaExecutable -Destination (Join-Path $directory 'baseline.exe')
if (Test-Path -LiteralPath ($AdaExecutable + '.debug')) {
    Copy-Item -LiteralPath ($AdaExecutable + '.debug') -Destination (Join-Path $directory 'baseline.exe.debug')
}
if ((Get-FileHash -LiteralPath (Join-Path $directory 'baseline.exe')).Hash -cne $identity) { throw 'Snapshot changed.' }
$records = @(Get-Content -LiteralPath $ReferenceReport -Raw | ConvertFrom-Json | Where-Object Status -ne Error)
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$inventory = @(foreach ($record in $records) {
    if (-not $names.Add($record.Book)) { throw 'Reference basenames must be unique.' }
    $path = Join-Path $InputPath $record.Book
    if ((Get-FileHash -LiteralPath $path).Hash -cne $record.InputSHA256) { throw 'Input differs from reference.' }
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $entries = $archive.Entries.Count
        $compressed = ($archive.Entries | Measure-Object CompressedLength -Sum).Sum
        $expanded = ($archive.Entries | Measure-Object Length -Sum).Sum
        $encodings = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -notmatch '\.(css|xhtml|html|xml|opf|svg|ncx)$') { continue }
            $stream = $entry.Open()
            try {
                $prefix = [byte[]]::new(512)
                $count = $stream.Read($prefix, 0, $prefix.Length)
                $text = [Text.Encoding]::ASCII.GetString($prefix, 0, $count)
                $encoding = if ($count -ge 2 -and $prefix[0] -eq 255 -and $prefix[1] -eq 254) { 'UTF16LE' }
                    elseif ($count -ge 2 -and $prefix[0] -eq 254 -and $prefix[1] -eq 255) { 'UTF16BE' }
                    elseif ($text -match '(?i)cp932|windows-31j|shift[_-]jis') { 'CP932' } else { 'UTF8' }
                $null = $encodings.Add($encoding)
            } finally { $stream.Dispose() }
        }
        $sizeClass = if ($record.InputBytes -lt 1MB) { 'small' } elseif ($record.InputBytes -lt 10MB) { 'medium' } else { 'large' }
        $entryClass = if ($entries -lt 50) { 'few' } elseif ($entries -lt 200) { 'many' } else { 'dense' }
        $entropyClass = if ($expanded -gt 0 -and $compressed / $expanded -gt 0.9) { 'incompressible' } else { 'compressible' }
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($record.Book)))
        [pscustomobject]@{Record=$record;Hash=$hash;Stratum=($record.Status,$sizeClass,$entryClass,$entropyClass,
            (@($encodings | Sort-Object) -join '+') -join '/');Entries=$entries}
    } finally { $archive.Dispose() }
})
$tuning = [Collections.Generic.List[object]]::new()
$holdout = [Collections.Generic.List[object]]::new()
foreach ($group in @($inventory | Group-Object Stratum)) {
    $ordered = @($group.Group | Sort-Object Hash)
    for ($index = 0; $index -lt $ordered.Count; $index++) {
        if ($ordered.Count -gt 1 -and $index % 5 -eq 0) { $holdout.Add($ordered[$index].Record) }
        else { $tuning.Add($ordered[$index].Record) }
    }
}
if (-not $tuning.Count -or -not $holdout.Count) { throw 'The corpus is too small for stratified tuning/holdout sets.' }
$tuning | ConvertTo-Json -Depth 8 -AsArray | Set-Content -LiteralPath (Join-Path $directory 'tuning.json')
$holdout | ConvertTo-Json -Depth 8 -AsArray | Set-Content -LiteralPath (Join-Path $directory 'holdout.json')
$inventory | Select-Object Hash,Stratum,Entries | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $directory 'inventory.json')
$manifest = [pscustomobject]@{BinarySHA256=$identity;ReferenceSHA256=(Get-FileHash -LiteralPath $ReferenceReport).Hash;
    Commit=(& git -C $repository rev-parse HEAD);Books=$records.Count;Tuning=$tuning.Count;Holdout=$holdout.Count;
    Method='SHA256 ordering within status/size/entry-count/compressibility/encoding strata; every fifth held out'}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'identity.json')
$manifest | ConvertTo-Json
Write-Output $directory
