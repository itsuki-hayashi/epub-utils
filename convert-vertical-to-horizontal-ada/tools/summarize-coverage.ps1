param([Parameter(Mandatory)][string]$CoverageDirectory, [switch]$MeasureOnly)
$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path $PSScriptRoot -Parent
$units = [Collections.Generic.List[object]]::new()
$statementCovered = 0
$statementTotal = 0
$decisionCovered = 0
$decisionTotal = 0
foreach ($file in Get-ChildItem -LiteralPath $CoverageDirectory -Filter '*.xcov') {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    $statement = [regex]::Match($text, '(?m)^\d+% statement coverage \((\d+) out of (\d+)\)')
    $decision = [regex]::Match($text, '(?m)^\d+% decision coverage \((\d+) out of (\d+)\)')
    $mcdc = [regex]::Match($text, '(?m)^\d+% MC/DC coverage \((\d+) out of (\d+)\)')
    if (-not $statement.Success) { continue }
    $covered = [int]$statement.Groups[1].Value
    $total = [int]$statement.Groups[2].Value
    $decCovered = if ($decision.Success) { [int]$decision.Groups[1].Value } else { 0 }
    $decTotal = if ($decision.Success) { [int]$decision.Groups[2].Value } else { 0 }
    $mcdcCovered = if ($mcdc.Success) { [int]$mcdc.Groups[1].Value } else { 0 }
    $mcdcTotal = if ($mcdc.Success) { [int]$mcdc.Groups[2].Value } else { 0 }
    $statementCovered += $covered
    $statementTotal += $total
    $decisionCovered += $decCovered
    $decisionTotal += $decTotal
    $units.Add([ordered]@{
        Unit = $file.Name.Replace('.xcov', '')
        Statements = @($covered, $total)
        Decisions = @($decCovered, $decTotal)
        MCDC = @($mcdcCovered, $mcdcTotal)
    })
}
if ($statementTotal -eq 0 -or $decisionTotal -eq 0) { throw 'Coverage report contains no measured application code' }
foreach ($name in @('epub_v2h_main.adb', 'unzip-epub_decompression.adb')) {
    if (@($units | Where-Object { $_.Unit -ceq $name }).Count -ne 1) {
        throw ('Missing owned production unit coverage: ' + $name)
    }
}
$statementPercent = 100.0 * $statementCovered / $statementTotal
$decisionPercent = 100.0 * $decisionCovered / $decisionTotal
$corePass = $true
foreach ($name in @('epub-classification.adb', 'epub-patches.adb', 'epub-publication.adb')) {
    $found = @($units | Where-Object { $_.Unit -ceq $name })
    if ($found.Count -ne 1) { throw ('Missing required core coverage: ' + $name) }
    $unit = $found[0]
    $corePass = $corePass -and $unit.Statements[0] -eq $unit.Statements[1] -and $unit.Decisions[0] -eq $unit.Decisions[1]
    if ($name -ne 'epub-patches.adb') { $corePass = $corePass -and $unit.MCDC[0] -eq $unit.MCDC[1] }
}
$summary = [ordered]@{
    StatementPercent = [math]::Round($statementPercent, 2)
    DecisionPercent = [math]::Round($decisionPercent, 2)
    StatementCounts = @($statementCovered, $statementTotal)
    DecisionCounts = @($decisionCovered, $decisionTotal)
    RequiredCorePass = $corePass
    ApplicationCoveragePass = $statementPercent -ge 95 -and $decisionPercent -ge 90 -and $corePass
    Units = $units.ToArray()
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $projectDirectory 'verification/coverage-latest.json') -Encoding utf8
Write-Output ('Statement coverage: {0:N2}%; decision coverage: {1:N2}%; required core: {2}' -f $statementPercent, $decisionPercent, $corePass)
if (-not $MeasureOnly -and -not $summary.ApplicationCoveragePass) { throw 'Application coverage gates are not satisfied' }
