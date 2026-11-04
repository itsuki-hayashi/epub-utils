param(
    [Parameter(Mandatory)][string]$ConvertedSummary,
    [Parameter(Mandatory)][string]$PreservedSummary,
    [Parameter(Mandatory)][string]$MixedSummary,
    [string]$SequentialSummary,
    [string[]]$SingleFileSummary = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'performance-statistics.ps1')
$converted = Get-Content -LiteralPath $ConvertedSummary -Raw | ConvertFrom-Json
$preserved = Get-Content -LiteralPath $PreservedSummary -Raw | ConvertFrom-Json
$mixed = Get-Content -LiteralPath $MixedSummary -Raw | ConvertFrom-Json
$rows = @($converted,$preserved,$mixed)
$latencyRows = @($rows)
foreach ($path in @($SequentialSummary) + $SingleFileSummary) {
    if (-not $path) { continue }
    $extra = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if (-not $extra.ComparisonOnly -or $extra.Pairs -lt 8 -or $extra.Limit -ne 0 -or
        -not $extra.DualCompressionGate -or -not $extra.MemoryWithinBudget -or
        $extra.CandidateBinarySHA256 -cne $converted.CandidateBinarySHA256 -or
        $extra.ControlBinarySHA256 -cne $converted.ControlBinarySHA256) {
        throw 'Additional latency summaries must be complete comparisons of the same binaries.'
    }
    $latencyRows += $extra
}
$complete = $true
foreach ($row in $rows) {
    if (-not $row.ComparisonOnly -or $row.Pairs -lt 8 -or $row.Limit -ne 0 -or
        -not $row.DualCompressionGate -or -not $row.MemoryWithinBudget -or
        $row.CandidateBinarySHA256 -cne $converted.CandidateBinarySHA256 -or
        $row.ControlBinarySHA256 -cne $converted.ControlBinarySHA256 -or
        $row.InputSHA256s.Count -ne $row.Books) { $complete = $false }
}
$complete = $complete -and $converted.Workload -eq 'Converted' -and $preserved.Workload -eq 'Preserved' -and
    $mixed.Workload -eq 'Mixed' -and $mixed.Books -eq $converted.Books + $preserved.Books -and
    (@(@($converted.InputSHA256s) + @($preserved.InputSHA256s) | Sort-Object) -join ',') -ceq
    (@($mixed.InputSHA256s | Sort-Object) -join ',')
$regressionFree = @($rows | Where-Object {$_.RelativeSpeedup -lt 1 / 1.02}).Count -eq 0
$latencyChecks = @($latencyRows | ForEach-Object {
    $gate = Get-PerformanceLatencyGate $_.ControlMedianSeconds $_.CandidateMedianSeconds
    $gate | Add-Member -NotePropertyName Label -NotePropertyValue $_.Label
    $gate
})
$latencyMet = @($latencyChecks | Where-Object {-not $_.Pass}).Count -eq 0
$result = [pscustomobject]@{CompleteMeasurements=$complete;NoWorkloadRegressionAboveTwoPercent=$regressionFree;
    LatencyGateMet=$latencyMet;
    LatencyPolicy=[pscustomobject]@{ShortControlMedianCutoffSeconds=0.250;FixedOverheadSeconds=0.020;
        RelativeRegressionLimit=0.02;CutoffIsStrict=$true};
    LatencyChecks=$latencyChecks;
    ConversionTimingMet=[bool]$converted.PromotionTimingMet;
    Promotable=($complete -and $latencyMet -and $converted.PromotionTimingMet);
    Workloads=@($rows | Select-Object Workload,Books,Pairs,RelativeSpeedup,PairedConfidence,
        ControlMedianPeakBytes,CandidateMedianPeakBytes,MemoryWithinBudget)}
$result | ConvertTo-Json -Depth 8
if (-not $result.Promotable) { throw 'Performance promotion gates were not all met.' }
