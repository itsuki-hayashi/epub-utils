param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ReferenceReport,
    [Parameter(Mandatory)][string]$AdaExecutable,
    [Parameter(Mandatory)][string]$OutputRoot,
    [ValidateSet('Aggregate','PerBook')][string]$CompressionGate = 'Aggregate'
)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$repository = Split-Path $project -Parent
$InputPath = [IO.Path]::GetFullPath($InputPath)
$ReferenceReport = [IO.Path]::GetFullPath($ReferenceReport)
$AdaExecutable = [IO.Path]::GetFullPath($AdaExecutable)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (($OutputRoot + [IO.Path]::DirectorySeparatorChar).StartsWith(
    $repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Corpus artifacts must be outside the repository.'
}
$expected = @(Get-Content -LiteralPath $ReferenceReport -Raw | ConvertFrom-Json)
if (-not $expected.Count -or @($expected | Where-Object Status -eq Error).Count) {
    throw 'A complete successful reference report is required.'
}
$directory = Join-Path $OutputRoot ('corpus-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$report = Join-Path $directory 'report.json'
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $AdaExecutable
$start.WorkingDirectory = $directory
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
foreach ($argument in @('--input-path',$InputPath,'--output-directory',(Join-Path $directory 'books'),'--json')) {
    $start.ArgumentList.Add($argument)
}
# Correctness only: no affinity control, timing, memory sampling, or speed claim.
$process = [Diagnostics.Process]::Start($start)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [IO.File]::WriteAllText($report,$stdout.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $directory 'stderr.log'),$stderr.GetAwaiter().GetResult())
    if ($process.ExitCode -ne 0) { throw 'Corpus conversion failed; private diagnostics retained.' }
} finally { $process.Dispose() }
$actual = @(Get-Content -LiteralPath $report -Raw | ConvertFrom-Json)
if ($actual.Count -ne $expected.Count -or @($actual | Where-Object Status -eq Error).Count) {
    throw 'Corpus conversion was incomplete; private diagnostics retained.'
}
Write-Output 'Corpus conversion complete; checking payloads, metadata, hashes and compression quality.'
$log = Join-Path $directory 'validation.log'
Push-Location -LiteralPath (Join-Path $repository 'convert-vertical-to-horizontal-perl')
try {
    & perl -Ilib -Ilocal/lib/perl5 (Join-Path $PSScriptRoot 'verify-performance.pl') `
        $ReferenceReport $report $InputPath $CompressionGate *> $log
    if ($LASTEXITCODE -ne 0) { throw 'Independent corpus validation failed; private diagnostics retained.' }
} finally { Pop-Location }
$metrics = @(Get-Content -LiteralPath $log | Where-Object {$_ -like 'METRICS *'})
if ($metrics.Count -ne 1) { throw 'Missing independent corpus metrics.' }
$summary = [pscustomobject]@{
    CorrectnessOnly=$true;Books=$actual.Count;
    Converted=@($actual|Where-Object Status -eq Converted).Count;
    Preserved=@($actual|Where-Object Status -eq Preserved).Count;
    Errors=0;CompressionGate=$CompressionGate;
    BinarySHA256=(Get-FileHash -LiteralPath $AdaExecutable).Hash;
    Quality=($metrics[0].Substring(8)|ConvertFrom-Json)
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $directory 'summary.json')
$summary | ConvertTo-Json -Depth 4
