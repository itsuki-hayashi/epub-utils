param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ReferenceReport,
    [Parameter(Mandatory)][string]$AdaExecutable,
    [Parameter(Mandatory)][string]$OutputRoot,
    [ValidateSet('Converted','Preserved','Mixed')][string]$Workload = 'Converted',
    [ValidateRange(1,32)][int]$Pairs = 8,
    [ValidateRange(0,10000)][int]$Limit = 0,
    [ValidatePattern('^[a-zA-Z0-9-]+$')][string]$Label = 'measurement',
    [ValidateSet('Report','PerBook','Aggregate')][string]$CompressionGate = 'Aggregate'
)
$ErrorActionPreference = 'Stop'
if ($Pairs -ge 8 -and $Limit -eq 0 -and $CompressionGate -eq 'Report') {
    throw 'Acceptance runs require an explicit compression-quality gate.'
}
$project = Split-Path $PSScriptRoot -Parent
$repository = Split-Path $project -Parent
$perlProject = Join-Path $repository 'convert-vertical-to-horizontal-perl'
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (($OutputRoot + [IO.Path]::DirectorySeparatorChar).StartsWith($repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Benchmark artifacts must be outside the repository.'
}
$AdaExecutable = [IO.Path]::GetFullPath($AdaExecutable)
$InputPath = [IO.Path]::GetFullPath($InputPath)
$reference = @(Get-Content -LiteralPath $ReferenceReport -Raw | ConvertFrom-Json)
$selection = @($reference | Where-Object {
    $_.Status -ne 'Error' -and ($Workload -eq 'Mixed' -or $_.Status -eq $Workload)
} | Sort-Object InputBytes,Book)
if ($Limit -gt 0 -and $selection.Count -gt $Limit) {
    $all = $selection
    $selection = @(for ($i=0; $i -lt $Limit; $i++) {
        $all[[int][Math]::Floor($i * ($all.Count - 1) / [Math]::Max(1,$Limit - 1))]
    })
}
if (-not $selection.Count) { throw 'No eligible reference records.' }
$session = Join-Path $OutputRoot ($Label + '-' + [guid]::NewGuid().ToString('N'))
$staged = Join-Path $session 'input'
New-Item -ItemType Directory -Path $staged -Force | Out-Null
foreach ($record in $selection) {
    $source = Join-Path $InputPath $record.Book
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne $record.InputSHA256) { throw 'Input differs from reference.' }
    New-Item -ItemType HardLink -Path (Join-Path $staged $record.Book) -Value $source | Out-Null
}
$perl = (Get-Command perl).Source
$rows = [Collections.Generic.List[object]]::new()
$controller = [Diagnostics.Process]::GetCurrentProcess()
$originalAffinity = $controller.ProcessorAffinity
$mask = $originalAffinity.ToInt64() -band (-$originalAffinity.ToInt64())

function Run-Engine([string]$Engine, [string]$Tag) {
    $directory = Join-Path $session $Tag
    New-Item -ItemType Directory -Path $directory | Out-Null
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    if ($Engine -eq 'Perl') {
        $start.FileName = $perl
        $start.WorkingDirectory = $directory
        foreach ($argument in @(('-I' + (Join-Path $perlProject 'lib')),('-I' + (Join-Path $perlProject 'local/lib/perl5')),(Join-Path $perlProject 'bin/epub-v2h'))) { $start.ArgumentList.Add($argument) }
    } else {
        $start.FileName = $AdaExecutable
        $start.WorkingDirectory = $directory
    }
    foreach ($argument in @('--input-path',$staged,'--output-directory',(Join-Path $directory 'books'),'--json')) {
        $start.ArgumentList.Add($argument)
    }
    $start.Environment['EPUB_PROFILE_PATH'] = Join-Path $directory 'phases.csv'
    # Children inherit the controller's affinity before their first instruction.
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $peak = 0L
    try {
        while (-not $process.WaitForExit(50)) {
            try { $process.Refresh(); $peak = [Math]::Max($peak,$process.PeakWorkingSet64) } catch { if (-not $process.HasExited) { throw } }
        }
        $watch.Stop()
        $cpu = $process.TotalProcessorTime.TotalSeconds
        $code = $process.ExitCode
        $json = $stdout.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $directory 'report.json'),$json,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $directory 'stderr.log'),$stderr.GetAwaiter().GetResult())
        if ($code -ne 0) { throw 'Conversion failed; private diagnostics retained outside the repository.' }
        $records = @($json | ConvertFrom-Json)
        if ($records.Count -ne $selection.Count -or @($records | Where-Object Status -eq Error).Count) { throw 'Incomplete conversion.' }
        return [pscustomobject]@{Engine=$Engine;Tag=$Tag;Seconds=$watch.Elapsed.TotalSeconds;CPUSeconds=$cpu;
            PeakBytes=$peak;OutputBytes=($records|Measure-Object OutputBytes -Sum).Sum;Report=(Join-Path $directory 'report.json')}
    } finally { $process.Dispose() }
}

function Validate-Output($Expected, $Actual) {
    $arguments = @('-Ilib','-Ilocal/lib/perl5',(Join-Path $PSScriptRoot 'verify-performance.pl'),$Expected.Report,$Actual.Report,$staged,$CompressionGate)
    $log = Join-Path (Split-Path $Actual.Report -Parent) 'validation.log'
    Push-Location $perlProject
    try {
        & $perl @arguments *> $log
        if ($LASTEXITCODE -ne 0) { throw 'Independent validation failed; private diagnostics retained.' }
    } finally { Pop-Location }
    $metrics = @(Get-Content -LiteralPath $log | Where-Object {$_ -like 'METRICS *'})
    if ($metrics.Count -ne 1) { throw 'Missing independent compression metrics.' }
    return ($metrics[0].Substring(8) | ConvertFrom-Json)
}

function Median($Values) {
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count/2)
    if ($sorted.Count % 2) { return $sorted[$middle] }
    return ($sorted[$middle-1]+$sorted[$middle])/2
}

try {
    $controller.ProcessorAffinity = [IntPtr]$mask
    $expected = Run-Engine 'Perl' 'warmup-perl'
    $null = Validate-Output $expected $expected
    $warmup = Run-Engine 'Ada' 'warmup-ada'
    $null = Validate-Output $expected $warmup
    for ($pair=0; $pair -lt $Pairs; $pair++) {
        $order = if ($pair % 2) { @('Ada','Perl') } else { @('Perl','Ada') }
        foreach ($engine in $order) {
            $row = Run-Engine $engine ("pair-$pair-" + $engine.ToLowerInvariant())
            $quality = Validate-Output $expected $row
            $row | Add-Member -NotePropertyName Quality -NotePropertyValue $quality
            $rows.Add($row)
            $rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $session 'runs.json')
            Write-Output ("Validated {0} pair {1}: wall={2:N3}s CPU={3:N3}s" -f $engine,($pair+1),$row.Seconds,$row.CPUSeconds)
        }
    }
    $perlMedian = Median @($rows | Where-Object Engine -eq Perl | ForEach-Object Seconds)
    $adaMedian = Median @($rows | Where-Object Engine -eq Ada | ForEach-Object Seconds)
    $perlPeak = Median @($rows | Where-Object Engine -eq Perl | ForEach-Object PeakBytes)
    $adaPeak = Median @($rows | Where-Object Engine -eq Ada | ForEach-Object PeakBytes)
    $summary = [pscustomobject]@{Label=$Label;Workload=$Workload;Books=$selection.Count;Pairs=$Pairs;
        AcceptanceRun=($Pairs -ge 8 -and $Limit -eq 0);AffinityMask=$mask;
        InputBytes=($selection|Measure-Object InputBytes -Sum).Sum;
        PerlMedianSeconds=$perlMedian;AdaMedianSeconds=$adaMedian;Speedup=($perlMedian/$adaMedian);
        PerlMedianPeakBytes=$perlPeak;AdaMedianPeakBytes=$adaPeak;
        FasterThanPerl=($adaMedian -lt $perlMedian);LowerPeakRAMThanPerl=($adaPeak -lt $perlPeak);
        BinaryBytes=(Get-Item -LiteralPath $AdaExecutable).Length;CompressionGate=$CompressionGate;
        AdaBinarySHA256=(Get-FileHash -LiteralPath $AdaExecutable -Algorithm SHA256).Hash;
        FourfoldSpeedup=($perlMedian/$adaMedian -ge 4);
        TargetMet=($Pairs -ge 8 -and $Limit -eq 0 -and $adaMedian -lt $perlMedian -and
            $adaPeak -lt $perlPeak -and $CompressionGate -ne 'Report')}
    $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $session 'summary.json')
    $summary | ConvertTo-Json
} finally { $controller.ProcessorAffinity = $originalAffinity; $controller.Dispose() }
