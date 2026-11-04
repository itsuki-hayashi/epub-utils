param([Parameter(Mandatory)][string]$PhasePath, [double]$ElapsedSeconds = 0,
      [ValidateRange(1,65536)][int]$Workers = 1)
$ErrorActionPreference = 'Stop'
$phases = @(Import-Csv -LiteralPath $PhasePath)
if (-not $phases.Count -or -not $phases[0].PSObject.Properties['exclusive_seconds']) {
    throw 'This report requires exclusive phase timings from the current profiler.'
}
$accounted = ($phases | ForEach-Object {[double]$_.exclusive_seconds} | Measure-Object -Sum).Sum
$denominator = if ($Workers -eq 1 -and $ElapsedSeconds -gt 0) { $ElapsedSeconds } else { $accounted }
if ($denominator -le 0) { throw 'No elapsed time was measured.' }
$ranking = @($phases | ForEach-Object {
    $fraction = [double]$_.exclusive_seconds / $denominator
    [pscustomobject]@{Phase=$_.phase;InclusiveSeconds=[double]$_.inclusive_seconds;
        ExclusiveSeconds=[double]$_.exclusive_seconds;Calls=[long]$_.calls;Fraction=$fraction;
        IdealSpeedupCeiling=$(if ($Workers -eq 1 -and $fraction -lt 1) {1 / (1 - $fraction)} else {$null})}
} | Sort-Object ExclusiveSeconds -Descending)
[pscustomobject]@{DiagnosticOnly=$true;Workers=$Workers;TimerUnits='sum of task-local wall seconds';
    Denominator=$(if ($Workers -eq 1 -and $ElapsedSeconds -gt 0) {'supplied elapsed'} else {'accounted timers'});
    AccountedSeconds=$accounted;Ranking=$ranking;Counters=$(if(Test-Path -LiteralPath ($PhasePath+'.counters.csv')) {
        @(Import-Csv -LiteralPath ($PhasePath+'.counters.csv'))
    } else {@()})} | ConvertTo-Json -Depth 6
