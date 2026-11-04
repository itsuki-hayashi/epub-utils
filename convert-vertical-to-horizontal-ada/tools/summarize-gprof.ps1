param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$Gmon,
    [Parameter(Mandatory)][string]$Addr2Line
)
$ErrorActionPreference = 'Stop'
# MinGW x86-64 libgmon uses the BSD header, not GNU's tagged "gmon" header.
# Resolve histogram PCs through DWARF: gprof's PE nearest-symbol attribution
# can misleadingly charge inlined compressor code to deallocate_buffers.
$data = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Gmon))
if ($data.Length -lt 40) { throw 'Truncated gmon header' }
$low = [BitConverter]::ToUInt64($data,0)
$high = [BitConverter]::ToUInt64($data,8)
$size = [BitConverter]::ToUInt32($data,16)
if ($high -le $low -or $size -lt 40 -or $size -gt $data.Length -or ($size-40)%2) {
    throw 'Expected MinGW x86-64 BSD gmon format'
}
$bins = ($size-40)/2
$hits = @(for($i=0; $i -lt $bins; $i++) {
    $count = [BitConverter]::ToUInt16($data,40+2*$i)
    if ($count) {
        [pscustomobject]@{Count=$count;Address=('0x{0:x}' -f ($low+[uint64]($i*($high-$low)/$bins)))}
    }
})
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = [IO.Path]::GetFullPath($Addr2Line)
$start.UseShellExecute = $false
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
foreach($argument in @('-a','-f','-i','-C','-e',[IO.Path]::GetFullPath($Executable))) {$start.ArgumentList.Add($argument)}
$process = [Diagnostics.Process]::Start($start)
try {
    $output = $process.StandardOutput.ReadToEndAsync()
    foreach($hit in $hits){$process.StandardInput.WriteLine($hit.Address)}
    $process.StandardInput.Close()
    $process.WaitForExit()
    if($process.ExitCode -ne 0){throw 'DWARF address resolution failed'}
    $lines = $output.GetAwaiter().GetResult() -split '\r?\n'
} finally {$process.Dispose()}
$groups = [Collections.Generic.List[object]]::new()
$position = -1
foreach($line in $lines) {
    if($line -match '^0x[0-9a-fA-F]+$') {
        $position++
        $groups.Add([pscustomobject]@{Count=$hits[$position].Count;Frames=[Collections.Generic.List[string]]::new()})
    } elseif($position -ge 0 -and $line.Length) {$groups[$position].Frames.Add($line)}
}
$totals = @{}
foreach($group in $groups) {
    $text = $group.Frames -join "`n"
    $category = if($text -match 'mcount|fentry') {'Profiler overhead'}
        elseif($text -match 'epub__compression|epub__huffman|epub__lz77|epub__word_operations|zip__compress__deflate|huffman-encoding|lz77\.adb') {'DEFLATE engine'}
        elseif($text -match 'epub__checksums') {'CRC-32'}
        elseif($text -match 'epub__digests|secure_hash|sha256') {'SHA-256'}
        elseif($text -match 'unzip__decompress|unzip-decompress') {'Decompression'}
        elseif($text -match 'epub__file_streams') {'Owned file streams'}
        else {'Other'}
    if(-not $totals.ContainsKey($category)){$totals[$category]=0L}
    $totals[$category]+=$group.Count
}
$total = ($hits | Measure-Object Count -Sum).Sum
[pscustomobject]@{
    Samples=$total
    Categories=@($totals.GetEnumerator()|Sort-Object Value -Descending|ForEach-Object {
        [pscustomobject]@{Category=$_.Key;Samples=$_.Value;Percent=100*$_.Value/$total}
    })
    Hotspots=@($groups | Sort-Object Count -Descending | Select-Object -First 12 | ForEach-Object {
        [pscustomobject]@{Samples=$_.Count;Frames=@($_.Frames)}
    })
    Note='Samples within the executable image; includes profiler overhead. Not acceptance timing.'
} | ConvertTo-Json -Depth 5
