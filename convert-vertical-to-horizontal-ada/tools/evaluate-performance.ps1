param(
    [Parameter(Mandatory)][string]$ConvertedSummary,
    [Parameter(Mandatory)][string]$PreservedSummary,
    [Parameter(Mandatory)][string]$MixedSummary
)
$ErrorActionPreference = 'Stop'
$converted = Get-Content -LiteralPath $ConvertedSummary -Raw | ConvertFrom-Json
$preserved = Get-Content -LiteralPath $PreservedSummary -Raw | ConvertFrom-Json
$mixed = Get-Content -LiteralPath $MixedSummary -Raw | ConvertFrom-Json
$rows = @($converted,$preserved,$mixed)
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
$result = [pscustomobject]@{CompleteMeasurements=$complete;NoWorkloadRegressionAboveTwoPercent=$regressionFree;
    ConversionTimingMet=[bool]$converted.PromotionTimingMet;
    Promotable=($complete -and $regressionFree -and $converted.PromotionTimingMet);
    Workloads=@($rows | Select-Object Workload,Books,Pairs,RelativeSpeedup,PairedConfidence,
        ControlMedianPeakBytes,CandidateMedianPeakBytes,MemoryWithinBudget)}
$result | ConvertTo-Json -Depth 8
if (-not $result.Promotable) { throw 'Performance promotion gates were not all met.' }
