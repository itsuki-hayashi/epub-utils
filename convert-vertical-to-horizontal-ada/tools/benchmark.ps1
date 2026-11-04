param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ReferenceReport,
    [Parameter(Mandatory)][string]$AdaExecutable,
    [string]$BaselineAdaExecutable,
    [string]$QualityBaselineReport,
    [ValidatePattern('^(auto|[1-9][0-9]*)$')][string]$Jobs = '1',
    [ValidateSet('SingleCore','PhysicalCores')][string]$AffinityMode = 'SingleCore',
    [ValidateSet('SingleCore','PhysicalCores')][string]$ControlAffinityMode = 'SingleCore',
    [ValidateSet('Sequential','WorkerScaled')][string]$MemoryPolicy = 'Sequential',
    [string]$ControlJobs,
    [switch]$ReuseReferenceOutputs,
    [ValidateRange(0,[long]::MaxValue)][long]$MemoryBaselinePeakBytes = 0,
    [switch]$RequireIdenticalBaseline,
    [Parameter(Mandatory)][string]$OutputRoot,
    [ValidateSet('Converted','Preserved','Mixed')][string]$Workload = 'Converted',
    [ValidateRange(1,32)][int]$Pairs = 8,
    [ValidateRange(8,32)][int]$MaximumPairs = 32,
    [switch]$ExtendInconclusive,
    [ValidateRange(0,10000)][int]$Limit = 0,
    [ValidatePattern('^[a-zA-Z0-9-]+$')][string]$Label = 'measurement',
    [ValidateSet('Report','PerBook','Aggregate')][string]$CompressionGate = 'Aggregate'
)
$ErrorActionPreference = 'Stop'
$benchmarkMutex = [Threading.Mutex]::new($false, 'Local\epub-utils-performance')
$ownsBenchmarkMutex = $false
try {
    try { while (-not $benchmarkMutex.WaitOne(1000)) {} }
    catch [Threading.AbandonedMutexException] { }
    $ownsBenchmarkMutex = $true
if ($ReuseReferenceOutputs -and (-not $BaselineAdaExecutable -or $MemoryPolicy -ne 'WorkerScaled')) {
    throw 'Reusing frozen Perl outputs requires an Ada control and the worker-scaled memory policy.'
}
. (Join-Path $PSScriptRoot 'performance-statistics.ps1')
# Keep a process handle so even sub-50ms runs and the final sample retain the
# operating system's high-water mark after exit, before the handle is disposed.
if (-not ('EpubBenchmarkMemory' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class EpubBenchmarkMemory {
    [StructLayout(LayoutKind.Sequential)]
    struct Counters {
        public uint Size, Faults;
        public UIntPtr PeakWorkingSet, WorkingSet, PeakPaged, Paged,
            PeakNonPaged, NonPaged, PageFile, PeakPageFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool K32GetProcessMemoryInfo(IntPtr process, ref Counters data, uint size);
    public static long Peak(IntPtr process) {
        var data = new Counters();
        data.Size = (uint)Marshal.SizeOf<Counters>();
        if (!K32GetProcessMemoryInfo(process, ref data, data.Size))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return checked((long)data.PeakWorkingSet.ToUInt64());
    }
}
'@
}
if ($ExtendInconclusive -and (-not $BaselineAdaExecutable -or $Pairs -lt 8 -or $MaximumPairs -lt $Pairs)) {
    throw 'Adaptive measurement requires a baseline executable and 8..MaximumPairs initial pairs.'
}
if ($RequireIdenticalBaseline -and -not ($QualityBaselineReport -or $BaselineAdaExecutable)) {
    throw 'Byte-identity checks require a quality baseline report or executable.'
}
if ($Pairs -ge 8 -and $Limit -eq 0 -and $CompressionGate -eq 'Report') {
    throw 'Acceptance runs require an explicit compression-quality gate.'
}
if ($Pairs -ge 8 -and $Limit -eq 0 -and -not ($QualityBaselineReport -or $BaselineAdaExecutable)) {
    throw 'Full measurements require the frozen Ada quality report or baseline executable.'
}
$project = Split-Path $PSScriptRoot -Parent
$repository = Split-Path $project -Parent
$perlProject = Join-Path $repository 'convert-vertical-to-horizontal-perl'
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if ($OutputRoot -eq $repository -or ($OutputRoot + [IO.Path]::DirectorySeparatorChar).StartsWith($repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Benchmark artifacts must be outside the repository.'
}
$AdaExecutable = [IO.Path]::GetFullPath($AdaExecutable)
$candidateSHA256 = (Get-FileHash -LiteralPath $AdaExecutable -Algorithm SHA256).Hash
if ($BaselineAdaExecutable) { $BaselineAdaExecutable = [IO.Path]::GetFullPath($BaselineAdaExecutable) }
if ($BaselineAdaExecutable) { $controlSHA256 = (Get-FileHash -LiteralPath $BaselineAdaExecutable -Algorithm SHA256).Hash }
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
if ($QualityBaselineReport) {
    $QualityBaselineReport = [IO.Path]::GetFullPath($QualityBaselineReport)
    $qualitySHA256 = (Get-FileHash -LiteralPath $QualityBaselineReport).Hash
    $qualityBooks = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($record in @(Get-Content -LiteralPath $QualityBaselineReport -Raw | ConvertFrom-Json)) {
        $qualityBooks.Add($record.Book, $record)
    }
    $qualitySelection = @(foreach ($record in $selection) {
        if (-not $qualityBooks.ContainsKey($record.Book)) { throw 'Quality baseline is incomplete.' }
        $qualityBooks[$record.Book]
    })
}
$session = Join-Path $OutputRoot ($Label + '-' + [guid]::NewGuid().ToString('N'))
$staged = Join-Path $session 'input'
New-Item -ItemType Directory -Path $staged -Force | Out-Null
if ($QualityBaselineReport) {
    $qualityPath = Join-Path $session 'quality-reference.json'
    $qualitySelection | ConvertTo-Json -Depth 8 -AsArray | Set-Content -LiteralPath $qualityPath
    $qualityReference = [pscustomobject]@{Report=$qualityPath}
}
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
    } elseif ($Engine -eq 'ControlAda') {
        $start.FileName = $BaselineAdaExecutable
        $start.WorkingDirectory = $directory
    } else {
        $start.FileName = $AdaExecutable
        $start.WorkingDirectory = $directory
    }
    foreach ($argument in @('--input-path',$staged,'--output-directory',(Join-Path $directory 'books'),'--json')) {
        $start.ArgumentList.Add($argument)
    }
    if ($Engine -eq 'Ada') {
        $start.ArgumentList.Add('--jobs'); $start.ArgumentList.Add($Jobs)
    } elseif ($Engine -eq 'ControlAda' -and $ControlJobs) {
        $start.ArgumentList.Add('--jobs'); $start.ArgumentList.Add($ControlJobs)
    }
    $start.Environment['EPUB_CONCURRENCY_STATS'] = Join-Path $directory 'workers.csv'
    $start.Environment['EPUB_PROFILE_PATH'] = Join-Path $directory 'phases.csv'
    # Children inherit the controller's affinity before their first instruction.
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $parallelAffinity = ($Engine -eq 'Ada' -and $AffinityMode -eq 'PhysicalCores') -or
        ($Engine -eq 'ControlAda' -and $ControlAffinityMode -eq 'PhysicalCores')
    $controller.ProcessorAffinity = if ($parallelAffinity) { $originalAffinity } else { [IntPtr]$mask }
    try { $process = [Diagnostics.Process]::Start($start) }
    finally { $controller.ProcessorAffinity = $originalAffinity }
    $processHandle = $process.Handle
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $peak = [EpubBenchmarkMemory]::Peak($processHandle)
    try {
        while (-not $process.WaitForExit(50)) {
            $peak = [Math]::Max($peak,[EpubBenchmarkMemory]::Peak($processHandle))
        }
        $watch.Stop()
        $peak = [Math]::Max($peak,[EpubBenchmarkMemory]::Peak($processHandle))
        $cpu = $process.TotalProcessorTime.TotalSeconds
        $code = $process.ExitCode
        $json = $stdout.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $directory 'report.json'),$json,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $directory 'stderr.log'),$stderr.GetAwaiter().GetResult())
        if ($code -ne 0) { throw 'Conversion failed; private diagnostics retained outside the repository.' }
        $records = @($json | ConvertFrom-Json)
        if ($records.Count -ne $selection.Count -or @($records | Where-Object Status -eq Error).Count) { throw 'Incomplete conversion.' }
        $workers = 1
        $workerStats = Join-Path $directory 'workers.csv'
        if (Test-Path -LiteralPath $workerStats) {
            $stats = @(Import-Csv -LiteralPath $workerStats)
            $workers = [int]($stats | Where-Object Metric -eq workers).Value
        }
        return [pscustomobject]@{Workers=$workers;WorkerUtilization=($cpu/($watch.Elapsed.TotalSeconds*$workers));Engine=$Engine;Tag=$Tag;Seconds=$watch.Elapsed.TotalSeconds;CPUSeconds=$cpu;
            PeakBytes=$peak;OutputBytes=($records|Measure-Object OutputBytes -Sum).Sum;Report=(Join-Path $directory 'report.json')}
    } finally { $process.Dispose() }
}

function Validate-Output($Expected, $Actual, [string]$Name = 'validation') {
    $arguments = @('-Ilib','-Ilocal/lib/perl5',(Join-Path $PSScriptRoot 'verify-performance.pl'),$Expected.Report,$Actual.Report,$staged,$CompressionGate)
    $log = Join-Path (Split-Path $Actual.Report -Parent) ($Name + '.log')
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
    Get-PerformanceMedian $Values
}

try {
    $controller.ProcessorAffinity = [IntPtr]$mask
    if ($ReuseReferenceOutputs) {
        $perlReport = Join-Path $session 'perl-reference.json'
        $selection | ConvertTo-Json -Depth 8 -AsArray | Set-Content -LiteralPath $perlReport
        $expected = [pscustomobject]@{Report=$perlReport;PeakBytes=0}
    } else {
        $expected = Run-Engine 'Perl' 'warmup-perl'
    }
    $null = Validate-Output $expected $expected
    $controlEngine = if ($BaselineAdaExecutable) { 'ControlAda' } else { 'Perl' }
    if ($BaselineAdaExecutable) {
        $controlWarmup = Run-Engine $controlEngine 'warmup-control'
        $null = Validate-Output $expected $controlWarmup
        if ($qualityReference) {
            $controlQuality = Validate-Output $qualityReference $controlWarmup 'quality-baseline'
            if ($RequireIdenticalBaseline -and $controlQuality.identical_books -ne $selection.Count) {
                throw 'The control executable differs from the frozen structural baseline.'
            }
        }
        if (-not $QualityBaselineReport) { $qualityReference = $controlWarmup }
    }
    $warmup = Run-Engine 'Ada' 'warmup-ada'
    $null = Validate-Output $expected $warmup
    if ($qualityReference) {
        $warmupQuality = Validate-Output $qualityReference $warmup 'quality-baseline'
        if ($RequireIdenticalBaseline -and $warmupQuality.identical_books -ne $selection.Count) {
            throw 'The structural optimization changed archive bytes.'
        }
    }
    $pairTarget = $Pairs
    for ($pair=0; $pair -lt $pairTarget; $pair++) {
        $order = if ($pair % 2) { @('Ada',$controlEngine) } else { @($controlEngine,'Ada') }
        foreach ($engine in $order) {
            $row = Run-Engine $engine ("pair-$pair-" + $engine.ToLowerInvariant())
            $quality = Validate-Output $expected $row
            $row | Add-Member -NotePropertyName Quality -NotePropertyValue $quality
            if ($engine -eq 'Ada' -and $qualityReference) {
                $baselineQuality = Validate-Output $qualityReference $row 'quality-baseline'
                $row | Add-Member -NotePropertyName BaselineQuality -NotePropertyValue $baselineQuality
                if ($RequireIdenticalBaseline -and $baselineQuality.identical_books -ne $selection.Count) {
                    throw 'The structural optimization changed archive bytes.'
                }
            }
            $rows.Add($row)
            $rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $session 'runs.json')
            Write-Output ("Validated {0} pair {1}: wall={2:N3}s CPU={3:N3}s" -f $engine,($pair+1),$row.Seconds,$row.CPUSeconds)
        }
        if ($ExtendInconclusive -and $pair + 1 -eq $pairTarget -and $pairTarget -lt $MaximumPairs) {
            $interval = Get-PairedSpeedup @($rows | Where-Object Engine -eq ControlAda | ForEach-Object Seconds) `
                @($rows | Where-Object Engine -eq Ada | ForEach-Object Seconds)
            if ($interval.Lower95 -le 1 -and $interval.Upper95 -gt 1) {
                $pairTarget = [Math]::Min($MaximumPairs, 2 * $pairTarget)
            }
        }
    }
    $Pairs = $pairTarget
    if ((Get-FileHash -LiteralPath $AdaExecutable -Algorithm SHA256).Hash -cne $candidateSHA256 -or
        ($BaselineAdaExecutable -and (Get-FileHash -LiteralPath $BaselineAdaExecutable -Algorithm SHA256).Hash -cne $controlSHA256) -or
        ($QualityBaselineReport -and (Get-FileHash -LiteralPath $QualityBaselineReport).Hash -cne $qualitySHA256)) {
        throw 'An executable changed during measurement; results are not eligible.'
    }
    if ($BaselineAdaExecutable) {
        $controlMedian = Median @($rows | Where-Object Engine -eq ControlAda | ForEach-Object Seconds)
        $candidateMedian = Median @($rows | Where-Object Engine -eq Ada | ForEach-Object Seconds)
        $interval = if ($Pairs -ge 2) {
            Get-PairedSpeedup @($rows | Where-Object Engine -eq ControlAda | ForEach-Object Seconds) `
                @($rows | Where-Object Engine -eq Ada | ForEach-Object Seconds)
        } else { $null }
        $controlPeak = Median @($rows | Where-Object Engine -eq ControlAda | ForEach-Object PeakBytes)
        $candidatePeak = Median @($rows | Where-Object Engine -eq Ada | ForEach-Object PeakBytes)
        $candidateMaxPeak = ($rows | Where-Object Engine -eq Ada | Measure-Object PeakBytes -Maximum).Maximum
        $controlMaxPeak = ($rows | Where-Object Engine -eq ControlAda | Measure-Object PeakBytes -Maximum).Maximum
        $candidateWorkers = [int](Median @($rows | Where-Object Engine -eq Ada | ForEach-Object Workers))
        $memoryLimit = if ($MemoryPolicy -eq 'WorkerScaled') { 2 * $candidateWorkers * $controlPeak } else { 2 * $controlPeak }
        $summary = [pscustomobject]@{CandidateWorkers=$candidateWorkers;
            CandidateWorkerUtilization=(Median @($rows | Where-Object Engine -eq Ada | ForEach-Object WorkerUtilization));
            MemoryLimitBytes=$memoryLimit;ArtifactDirectory=$session;Label=$Label;Workload=$Workload;Books=$selection.Count;Pairs=$Pairs;Limit=$Limit;
            CandidateMaxPeakBytes=$candidateMaxPeak;ControlMaxPeakBytes=$controlMaxPeak;
            InputSHA256s=@($selection.InputSHA256 | Sort-Object);
            AcceptanceRun=$false;ComparisonOnly=$true;AffinityMask=$mask;AffinityMode=$AffinityMode;ControlAffinityMode=$ControlAffinityMode;
            Jobs=$Jobs;MemoryPolicy=$MemoryPolicy;CompressionGate=$CompressionGate;
            InputBytes=($selection|Measure-Object InputBytes -Sum).Sum;
            ControlMedianSeconds=$controlMedian;CandidateMedianSeconds=$candidateMedian;
            RelativeSpeedup=($controlMedian/$candidateMedian);
            PairedConfidence=$interval;DualCompressionGate=($CompressionGate -ne 'Report');
            MemoryWithinBudget=($controlPeak -gt 0 -and $candidateMaxPeak -gt 0 -and
                $candidateMaxPeak -le $memoryLimit -and ($MemoryPolicy -eq 'WorkerScaled' -or $candidateMaxPeak -lt $expected.PeakBytes));
            PromotionTimingMet=($Pairs -ge 8 -and $Limit -eq 0 -and $interval.Lower95 -gt 1 -and
                $controlMedian/$candidateMedian -ge 1.03);
            ControlMedianCPUSeconds=(Median @($rows|Where-Object Engine -eq ControlAda|ForEach-Object CPUSeconds));
            CandidateMedianCPUSeconds=(Median @($rows|Where-Object Engine -eq Ada|ForEach-Object CPUSeconds));
            ControlMedianPeakBytes=(Median @($rows|Where-Object Engine -eq ControlAda|ForEach-Object PeakBytes));
            CandidateMedianPeakBytes=(Median @($rows|Where-Object Engine -eq Ada|ForEach-Object PeakBytes));
            ControlBinaryBytes=(Get-Item -LiteralPath $BaselineAdaExecutable).Length;
            CandidateBinaryBytes=(Get-Item -LiteralPath $AdaExecutable).Length;
            ControlBinarySHA256=(Get-FileHash -LiteralPath $BaselineAdaExecutable).Hash;
            CandidateBinarySHA256=(Get-FileHash -LiteralPath $AdaExecutable).Hash}
        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $session 'summary.json')
        $summary | ConvertTo-Json -Depth 6
        return
    }
    $perlMedian = Median @($rows | Where-Object Engine -eq Perl | ForEach-Object Seconds)
    $adaMedian = Median @($rows | Where-Object Engine -eq Ada | ForEach-Object Seconds)
    $perlPeak = Median @($rows | Where-Object Engine -eq Perl | ForEach-Object PeakBytes)
    $adaPeak = Median @($rows | Where-Object Engine -eq Ada | ForEach-Object PeakBytes)
    $interval = if ($Pairs -ge 2) {
        Get-PairedSpeedup @($rows | Where-Object Engine -eq Perl | ForEach-Object Seconds) `
            @($rows | Where-Object Engine -eq Ada | ForEach-Object Seconds)
    } else { $null }
    $summary = [pscustomobject]@{ArtifactDirectory=$session;Label=$Label;Workload=$Workload;Books=$selection.Count;Pairs=$Pairs;Limit=$Limit;
        InputSHA256s=@($selection.InputSHA256 | Sort-Object);
        AcceptanceRun=($Pairs -ge 8 -and $Limit -eq 0);AffinityMask=$mask;
        InputBytes=($selection|Measure-Object InputBytes -Sum).Sum;
        PerlMedianSeconds=$perlMedian;AdaMedianSeconds=$adaMedian;Speedup=($perlMedian/$adaMedian);
        PairedConfidence=$interval;
        PerlMedianCPUSeconds=(Median @($rows|Where-Object Engine -eq Perl|ForEach-Object CPUSeconds));
        AdaMedianCPUSeconds=(Median @($rows|Where-Object Engine -eq Ada|ForEach-Object CPUSeconds));
        PerlMedianPeakBytes=$perlPeak;AdaMedianPeakBytes=$adaPeak;
        PerlOutputBytes=(Median @($rows|Where-Object Engine -eq Perl|ForEach-Object OutputBytes));
        AdaOutputBytes=(Median @($rows|Where-Object Engine -eq Ada|ForEach-Object OutputBytes));
        FasterThanPerl=($adaMedian -lt $perlMedian);LowerPeakRAMThanPerl=($adaPeak -lt $perlPeak);
        BinaryBytes=(Get-Item -LiteralPath $AdaExecutable).Length;CompressionGate=$CompressionGate;
        DualCompressionGate=([bool]$qualityReference -and $CompressionGate -ne 'Report');
        MemoryBaselinePeakBytes=$MemoryBaselinePeakBytes;
        MemoryWithinBudget=($MemoryBaselinePeakBytes -gt 0 -and $adaPeak -gt 0 -and
            $adaPeak -le 2 * $MemoryBaselinePeakBytes -and $adaPeak -lt $perlPeak);
        AdaBinarySHA256=(Get-FileHash -LiteralPath $AdaExecutable -Algorithm SHA256).Hash;
        FourfoldSpeedup=($perlMedian/$adaMedian -ge 4);
        TargetMet=($Pairs -ge 8 -and $Limit -eq 0 -and $adaMedian -lt $perlMedian -and
            $adaPeak -gt 0 -and $adaPeak -lt $perlPeak -and $CompressionGate -ne 'Report' -and
            [bool]$qualityReference -and $MemoryBaselinePeakBytes -gt 0 -and $adaPeak -le 2 * $MemoryBaselinePeakBytes)}
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $session 'summary.json')
    $summary | ConvertTo-Json -Depth 6
} finally { $controller.ProcessorAffinity = $originalAffinity; $controller.Dispose() }

} finally {
    if ($ownsBenchmarkMutex) { $benchmarkMutex.ReleaseMutex() }
    $benchmarkMutex.Dispose()
}